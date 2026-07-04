-- Slash commands: a registry shared by the frontends. Builtins live here;
-- extensions register more via the extension API; markdown prompt templates
-- are loaded from the commands/ config directories.
--
-- A command:
--   { name, description, run = function(ctx, args) end }
-- ctx is provided by the frontend: { runtime, ui?, quit(), clear() } — ui is
-- nil in print mode.

local fs = require("lupus.util.fs")
local models = require("lupus.ai.models")

local Registry = {}
Registry.__index = Registry

local commands_mod = { Registry = Registry }

function commands_mod.new()
  local self = setmetatable({ commands = {}, order = {} }, Registry)
  return self
end

function Registry:register(cmd)
  assert(cmd.name and cmd.run, "command needs name and run")
  if not self.commands[cmd.name] then
    self.order[#self.order + 1] = cmd.name
  end
  self.commands[cmd.name] = cmd
end

function Registry:get(name)
  return self.commands[name]
end

function Registry:list()
  local out = {}
  for _, name in ipairs(self.order) do
    out[#out + 1] = self.commands[name]
  end
  return out
end

--- Parse "/cmd rest of line". Returns name, args or nil.
function commands_mod.parse(text)
  local name, args = text:match("^/([%w_:%-%.]+)%s*(.*)$")
  return name, args
end

-- ---------------------------------------------------------------------------
-- Prompt templates: <dir>/commands/*.md files become /name commands whose
-- body is the prompt; $ARGUMENTS is replaced with the typed arguments.

function commands_mod.load_templates(registry, dirs, send)
  for _, dir in ipairs(dirs) do
    local cmd_dir = fs.join(dir, "commands")
    for _, fname in ipairs(fs.list_dir(cmd_dir)) do
      local name = fname:match("^(.+)%.md$")
      if name then
        local path = fs.join(cmd_dir, fname)
        registry:register({
          name = name,
          description = "prompt template (" .. path .. ")",
          run = function(ctx, args)
            local body = fs.read_file(path) or ""
            body = body:gsub("%$ARGUMENTS", args or "")
            send(ctx, body)
          end,
        })
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Builtins. UI-dependent commands check ctx.ui and degrade with a notice.

function commands_mod.register_builtins(registry)
  registry:register({
    name = "help",
    description = "List available commands",
    run = function(ctx)
      local lines = { "Commands:" }
      for _, cmd in ipairs(registry:list()) do
        lines[#lines + 1] = ("  /%-12s %s"):format(cmd.name, cmd.description or "")
      end
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Keys: enter send · alt+enter newline · esc abort · ctrl+c twice quit"
      ctx.notify(table.concat(lines, "\n"))
    end,
  })

  registry:register({
    name = "model",
    description = "Switch the model",
    run = function(ctx, args)
      if args and args ~= "" then
        local m = models.get(args)
        if m then
          ctx.runtime:set_model(m, { persist = true })
          ctx.notify("model: " .. m.provider .. "/" .. m.id)
        else
          ctx.notify("unknown model: " .. args)
        end
        return
      end
      if not ctx.pick_model then
        ctx.notify("usage: /model <id>")
        return
      end
      ctx.pick_model()
    end,
  })

  registry:register({
    name = "login",
    description = "Add an API key for a provider",
    run = function(ctx, args)
      if not ctx.ui then
        ctx.notify("login needs an interactive session — set the provider's env var instead")
        return
      end
      local providers = models.providers()
      local settings = ctx.runtime.config.settings

      local provider = args ~= "" and args or nil
      if provider then
        local known = false
        for _, p in ipairs(providers) do
          if p.name == provider then known = true break end
        end
        if not known then
          ctx.notify("unknown provider: " .. provider .. " (try /login without arguments)")
          return
        end
      else
        local options = {}
        for _, p in ipairs(providers) do
          local has_key = models.api_key({ provider = p.name }, settings) ~= nil
          local desc = has_key and "key configured"
            or (p.env and ("env " .. p.env) or "no key needed")
          options[#options + 1] = { label = p.name, desc = desc, value = p.name }
        end
        provider = ctx.ui.select{
          title = "Add an API key for which provider? (esc to cancel)",
          options = options,
        }
        if not provider then return end
      end

      local key = ctx.ui.input{
        title = ("API key for %s (enter to save, esc to cancel)"):format(provider),
        placeholder = "paste or type the key",
      }
      key = key and key:gsub("^%s+", ""):gsub("%s+$", "") or ""
      if key == "" then
        ctx.notify("login cancelled")
        return
      end

      local path, err = ctx.runtime:set_api_key(provider, key)
      if not path then
        ctx.notify("could not save the key: " .. tostring(err))
        return
      end
      local hint = ctx.runtime.model.provider == provider and "ready to go"
        or "/model to switch models"
      ctx.notify(("%s key saved to %s — %s"):format(provider, path, hint))
    end,
  })

  registry:register({
    name = "thinking",
    description = "Set thinking level (off/minimal/low/medium/high)",
    run = function(ctx, args)
      local levels = { off = true, minimal = true, low = true, medium = true, high = true }
      if not levels[args] then
        ctx.notify("usage: /thinking off|minimal|low|medium|high")
        return
      end
      ctx.runtime:set_thinking(args)
      ctx.notify("thinking: " .. args)
    end,
  })

  registry:register({
    name = "name",
    description = "Name this session",
    run = function(ctx, args)
      if args == "" then
        ctx.notify("usage: /name <session name>")
        return
      end
      ctx.runtime:name_session(args)
      ctx.notify("session named: " .. args)
    end,
  })

  registry:register({
    name = "new",
    description = "Start a fresh session",
    run = function(ctx)
      ctx.runtime:new_session()
      if ctx.clear then ctx.clear() end
      ctx.notify("started a new session")
    end,
  })

  registry:register({
    name = "clear",
    description = "Clear the screen (transcript stays in the session)",
    run = function(ctx)
      if ctx.clear then ctx.clear() end
    end,
  })

  registry:register({
    name = "cost",
    description = "Show context usage and cost",
    run = function(ctx)
      local usage = ctx.runtime:context_usage()
      ctx.notify(("context: ~%d tokens (%d%% of %d) · total cost: $%.4f"):format(
        usage.tokens, usage.percent, usage.window, ctx.runtime:total_cost()))
    end,
  })

  registry:register({
    name = "quit",
    description = "Exit lupus",
    run = function(ctx)
      ctx.quit()
    end,
  })
end

return commands_mod
