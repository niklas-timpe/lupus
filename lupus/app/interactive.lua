-- Interactive TUI frontend: renders the transcript as it streams, with a
-- fixed editor at the bottom. Assistant text renders as markdown, tool
-- calls as compact cards, thinking as dim collapsed text.
--
-- Keys: enter send · alt+enter newline · esc abort a run · ctrl+c twice quit.

local loop = require("lupus.loop")
local tui_mod = require("lupus.tui")
local text = require("lupus.tui.text")
local Text = require("lupus.tui.components.text")
local Markdown = require("lupus.tui.components.markdown")
local Editor = require("lupus.tui.components.editor")
local Loader = require("lupus.tui.components.loader")
local Spacer = require("lupus.tui.components.spacer")
local Select = require("lupus.tui.components.select")
local commands_mod = require("lupus.commands")
local models = require("lupus.ai.models")

local S = text.style

local Interactive = {}
Interactive.__index = Interactive

local interactive_mod = { Interactive = Interactive }

--- opts: initial_prompt — submitted once the UI is live.
function interactive_mod.new(runtime, opts)
  return setmetatable({
    runtime = runtime,
    initial_prompt = opts and opts.initial_prompt,
    tui = tui_mod.TUI.new(),
    transcript = {},   -- ordered display components (in the transcript area)
    stream_view = nil, -- component for the in-flight assistant message
    tool_views = {},   -- tool_call_id -> component
    quitting = false,
    last_ctrl_c = 0,
  }, Interactive)
end

-- ---------------------------------------------------------------------------
-- Transcript helpers. The tree is: [transcript components] status loader
-- spacer editor. We rebuild the child list whenever structure changes; the
-- differential renderer makes that cheap.

function Interactive:rebuild()
  self.tui:clear_children()
  for _, comp in ipairs(self.transcript) do
    self.tui:add(comp)
  end
  self.tui:add(self.status)
  self.tui:add(self.loader)
  self.tui:add(Spacer.new(1))
  self.tui:add(self.editor)
  self.tui:set_focus(self.editor)
  self.tui:request_render()
end

function Interactive:push(component)
  self.transcript[#self.transcript + 1] = component
  self:rebuild()
end

local function label_line(role_style, label, detail)
  local line = role_style(label)
  if detail and detail ~= "" then line = line .. " " .. S.gray(detail) end
  return line
end

function Interactive:add_user(msgtext)
  self:push(Text.new(label_line(S.blue, "you", ""), {}))
  self:push(Text.new(msgtext, { style = function(s) return s end }))
  self:push(Spacer.new(1))
end

-- ---------------------------------------------------------------------------
-- Tool cards

local function tool_summary(runtime, name, args)
  local tool = runtime.agent.tools_by_name[name]
  local detail = ""
  if tool and tool.render_call then
    local ok, rendered = pcall(tool.render_call, args or {})
    if ok and rendered then detail = rendered end
  end
  local label = tool and tool.label or name
  return label, detail
end

function Interactive:tool_card(id, name, args, state)
  local label, detail = tool_summary(self.runtime, name, args)
  local icon = state == "running" and S.yellow("⏵") or (state == "error" and S.red("✗") or S.green("✓"))
  return icon .. " " .. S.bold(label) .. (detail ~= "" and (" " .. S.gray(text.truncate(detail, 60))) or "")
end

-- ---------------------------------------------------------------------------
-- Runtime event handling

function Interactive:on_event(ev)
  if ev.type == "message_start" then
    local msg = ev.message
    if msg.role == "assistant" then
      self.stream_view = Markdown.new("")
      self.thinking_view = nil
      self:push(Text.new(label_line(S.magenta, self.runtime.model.id, ""), {}))
      self:push(self.stream_view)
    end
    -- user + tool_result messages are handled explicitly elsewhere

  elseif ev.type == "message_update" then
    local msg = ev.message
    -- Rebuild the markdown from the accumulated text blocks.
    local buf = {}
    local thinking = {}
    for _, block in ipairs(msg.content) do
      if block.type == "text" then
        buf[#buf + 1] = block.text
      elseif block.type == "thinking" then
        thinking[#thinking + 1] = block.thinking
      end
    end
    if #thinking > 0 and not self.thinking_view then
      self.thinking_view = Text.new("", { style = S.dim })
      -- Insert the thinking view just before the stream view.
      for i, c in ipairs(self.transcript) do
        if c == self.stream_view then
          table.insert(self.transcript, i, self.thinking_view)
          self:rebuild()
          break
        end
      end
    end
    if self.thinking_view then
      self.thinking_view:set_text("thinking: " .. table.concat(thinking))
    end
    if self.stream_view then
      self.stream_view:set_text(table.concat(buf))
    end
    self.tui:request_render()

  elseif ev.type == "message_end" then
    self.stream_view = nil
    self.thinking_view = nil
    if ev.message.role == "assistant" then
      if ev.message.stop_reason == "error" or ev.message.stop_reason == "aborted" then
        self:push(Text.new(S.red("● " .. (ev.message.error_message or ev.message.stop_reason))))
      end
      self:push(Spacer.new(1))
    end

  elseif ev.type == "tool_start" then
    self.loader:set_message("Running " .. ev.name .. "…")
    local card = Text.new(self:tool_card(ev.id, ev.name, ev.args, "running"))
    self.tool_views[ev.id] = card
    self:push(card)

  elseif ev.type == "tool_end" then
    local card = self.tool_views[ev.id]
    local msg = ev.result_message
    local state = msg.is_error and "error" or "done"
    if card then
      card:set_text(self:tool_card(ev.id, ev.name, nil, state))
    end
    -- Show a short result preview.
    local preview = ""
    for _, block in ipairs(msg.content) do
      if block.type == "text" then preview = block.text break end
    end
    local first_line = (preview:match("^[^\n]*") or ""):sub(1, 200)
    local extra_lines = select(2, preview:gsub("\n", "\n"))
    if first_line ~= "" then
      local suffix = extra_lines > 0 and S.gray((" +%d lines"):format(extra_lines)) or ""
      self:push(Text.new("  " .. S.gray(text.truncate(first_line, 70)) .. suffix))
    end
    self.tool_views[ev.id] = nil

  elseif ev.type == "agent_end" then
    self.loader:stop()
    self:set_status("")
    self.tui:request_render()

  elseif ev.type == "agent_start" then
    self.loader:start()
    self:set_status("")

  elseif ev.type == "turn_start" then
    self.loader:set_message("Thinking…")

  elseif ev.type == "model_changed" then
    self:set_status("")
  end
end

function Interactive:set_status(msgtext)
  self.status:set_text(msgtext)
end

function Interactive:header_line()
  return S.bold("lupus") .. S.gray(("  %s/%s  ·  %s"):format(
    self.runtime.model.provider, self.runtime.model.id, self.runtime.cwd))
end

-- ---------------------------------------------------------------------------
-- Commands and input

function Interactive:notify(msgtext)
  self:push(Text.new(S.gray("● ") .. msgtext))
  self:push(Spacer.new(1))
end

function Interactive:command_ctx()
  return {
    runtime = self.runtime,
    ui = self.ui,
    notify = function(m) self:notify(m) end,
    quit = function() self.quitting = true end,
    clear = function()
      self.transcript = {}
      self:rebuild()
      self.tui:request_render(true)
    end,
    pick_model = function() self:show_model_picker() end,
  }
end

--- Run a command in its own task: commands may open dialogs (which park
--- until answered), and the input task that delivered the keystroke must
--- stay free to feed those dialogs.
function Interactive:run_command(cmd, args)
  loop.spawn(function()
    local ok, err = pcall(cmd.run, self:command_ctx(), args)
    if not ok then self:notify(S.red("command failed: " .. tostring(err))) end
  end)
end

function Interactive:handle_submit(input)
  local name, args = commands_mod.parse(input)
  if name then
    local cmd = self.commands:get(name)
    if cmd then
      self:run_command(cmd, args)
      return
    end
    self:notify("unknown command: /" .. name .. " (try /help)")
    return
  end

  self:add_user(input)
  self.runtime:send(input)
end

function Interactive:show_model_picker()
  local items = {}
  for _, m in ipairs(models.list()) do
    local available = models.available(m, self.runtime.config.settings)
    items[#items + 1] = {
      label = m.provider .. "/" .. m.id,
      desc = available and "" or "no API key",
      value = m,
      available = available,
    }
  end
  local picker
  picker = Select.new{
    title = "Select a model (esc to cancel)",
    items = items,
    filterable = true,
    on_select = function(item)
      if item.available then
        self.runtime:set_model(item.value, { persist = true })
        self:notify("model: " .. item.value.provider .. "/" .. item.value.id)
      else
        self:notify("no API key for " .. item.value.provider)
      end
      self:close_overlay()
    end,
    on_cancel = function() self:close_overlay() end,
  }
  self:open_overlay(picker)
end

--- Swap the editor slot for a modal component.
function Interactive:open_overlay(component)
  self.overlay = component
  self.tui:clear_children()
  for _, comp in ipairs(self.transcript) do self.tui:add(comp) end
  self.tui:add(Spacer.new(1))
  self.tui:add(component)
  self.tui:set_focus(component)
  self.tui:request_render()
end

function Interactive:close_overlay()
  self.overlay = nil
  self:rebuild()
end

-- ---------------------------------------------------------------------------
-- Extension UI: dialogs park the calling task on a channel until answered.

function Interactive:build_ui()
  local channel = require("lupus.loop.channel")
  local ui = {}

  ui.notify = function(msgtext, level)
    if level == "error" then
      msgtext = S.red(msgtext)
    elseif level == "warning" then
      msgtext = S.yellow(msgtext)
    end
    self:notify(msgtext)
    self.tui:request_render()
  end

  ui.set_status = function(msgtext)
    self:set_status(msgtext or "")
    self.tui:request_render()
  end

  -- yields
  ui.select = function(opts)
    local ch = channel.new(1)
    local items = {}
    for _, o in ipairs(opts.options or {}) do
      if type(o) == "table" then
        items[#items + 1] = {
          label = o.label or tostring(o.value),
          desc = o.desc,
          value = o.value == nil and o or o.value,
        }
      else
        items[#items + 1] = { label = tostring(o), value = o }
      end
    end
    self:open_overlay(Select.new{
      title = opts.title,
      items = items,
      filterable = true,
      on_select = function(item)
        self:close_overlay()
        ch:send({ item.value })
      end,
      on_cancel = function()
        self:close_overlay()
        ch:send({})
      end,
    })
    local res = ch:recv()
    return res[1]
  end

  -- yields
  ui.confirm = function(opts)
    local v = ui.select{
      title = opts.title,
      options = {
        { label = "Yes", value = true },
        { label = "No", value = false },
      },
    }
    return v == true
  end

  -- yields
  ui.input = function(opts)
    local ch = channel.new(1)
    local editor = Editor.new{
      placeholder = opts.placeholder or "",
      on_submit = function(s)
        self:close_overlay()
        ch:send({ s })
      end,
    }
    local wrapper = {
      render = function(_, width)
        local lines = { S.bold(text.truncate(opts.title or "Input (esc to cancel)", width)) }
        for _, l in ipairs(editor:render(width)) do lines[#lines + 1] = l end
        return lines
      end,
      handle_input = function(_, ev)
        if ev.type == "key" and ev.name == "escape" then
          self:close_overlay()
          ch:send({})
          return
        end
        editor:handle_input(ev)
      end,
    }
    self:open_overlay(wrapper)
    editor.focused = true
    local res = ch:recv()
    return res[1]
  end

  return ui
end

-- ---------------------------------------------------------------------------

function Interactive:run()
  self.editor = Editor.new{
    placeholder = "ask lupus anything  ·  /help for commands",
    on_submit = function(s) self:handle_submit(s) end,
  }
  self.status = Text.new("")
  self.loader = Loader.new(self.tui, { message = "Thinking…", hint = "esc to interrupt" })

  self.commands = commands_mod.new()
  commands_mod.register_builtins(self.commands)
  commands_mod.load_templates(self.commands, {
    self.runtime.config.dirs.config,
    self.runtime.config.project_dir,
  }, function(_, body) self:handle_submit(body) end)
  -- Shared with extensions: their register_command lands in this registry.
  self.runtime.commands = self.commands

  self.runtime:subscribe(function(ev) self:on_event(ev) end)

  -- Header + rebuild.
  self.header = Text.new(self:header_line())
  self:push(self.header)
  self:push(Spacer.new(1))

  -- Replay any restored transcript.
  for _, msg in ipairs(self.runtime.agent.messages) do
    self:replay_message(msg)
  end

  -- Global keys: esc aborts, ctrl+c twice quits.
  self.tui:add_key_listener(function(ev)
    if ev.type ~= "key" then return false end
    if ev.name == "escape" and self.runtime:is_running() then
      self.runtime:abort()
      return true
    end
    if ev.name == "ctrl+c" then
      local now = loop.now_ms()
      if now - self.last_ctrl_c < 1500 then
        self.quitting = true
      else
        self.last_ctrl_c = now
        self:set_status(S.gray("press ctrl+c again to quit"))
        self.tui:request_render()
      end
      return true
    end
    return false
  end)

  self.tui:start()

  -- Extensions load once the UI is live (trust prompts need dialogs), and
  -- their shortcuts join the key listener chain.
  self.ui = self:build_ui()
  self.runtime:load_extensions(self.ui)
  self.tui:add_key_listener(function(ev)
    if ev.type ~= "key" then return false end
    for _, sc in ipairs(self.runtime.host.shortcuts) do
      if sc.key == ev.name then
        loop.spawn(function()
          local ok, err = pcall(sc.run)
          if not ok then self:notify(S.red("shortcut failed: " .. tostring(err))) end
        end)
        return true
      end
    end
    return false
  end)

  -- Extensions may have registered providers/models; a persisted choice
  -- like "edenai/…" only resolves against the registry now.
  self.runtime:reresolve_model()
  self.header:set_text(self:header_line())

  -- Missing API key: notify, and open the login dialog right away when the
  -- user has no key for any provider (first run).
  if not self.runtime:model_available() then
    local have_any_key = false
    for _, p in ipairs(models.providers()) do
      if models.api_key({ provider = p.name }, self.runtime.config.settings) then
        have_any_key = true
        break
      end
    end
    self:notify(S.yellow("no API key for " .. self.runtime.model.provider)
      .. S.gray((" — the selected model %s/%s needs one. "
        .. "/login adds a key, /model switches models."):format(
        self.runtime.model.provider, self.runtime.model.id)))
    if not have_any_key then
      self:run_command(self.commands:get("login"), "")
    end
  end

  if self.initial_prompt and self.initial_prompt ~= "" then
    self:handle_submit(self.initial_prompt)
  end

  while not self.quitting do
    loop.sleep(50)
  end

  if self.runtime:is_running() then
    self.runtime:abort()
    self.runtime.agent:wait_idle()
  end
  self.runtime:shutdown()
  self.loader:stop()
  self.tui:stop()
end

function Interactive:replay_message(msg)
  if msg.role == "user" then
    self:add_user(type(msg.content) == "string" and msg.content or "")
  elseif msg.role == "assistant" then
    self:push(Text.new(label_line(S.magenta, msg.model or "assistant", "")))
    local buf = {}
    for _, block in ipairs(msg.content) do
      if block.type == "text" then buf[#buf + 1] = block.text end
    end
    if #buf > 0 then self:push(Markdown.new(table.concat(buf))) end
    for _, block in ipairs(msg.content) do
      if block.type == "tool_call" then
        self:push(Text.new(self:tool_card(block.id, block.name, block.arguments, "done")))
      end
    end
    self:push(Spacer.new(1))
  end
end

return interactive_mod
