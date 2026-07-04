-- Extension event hub: handler registration plus the three dispatch
-- semantics extensions rely on.
--
--   notify    all handlers run; errors are caught and logged
--   veto      first handler returning { block = true } short-circuits
--   transform handlers chain over a value; nil = unchanged,
--             { handled = true } swallows the value entirely
--   collect   gather handler return tables (before_agent_start)

require("lupus.util.compat")
local log = require("lupus.util.log")

local EVENTS = {
  -- notify
  session_start = true, session_shutdown = true,
  agent_start = true, agent_end = true,
  turn_start = true, turn_end = true,
  message_start = true, message_update = true, message_end = true,
  tool_start = true, tool_update = true, tool_end = true,
  model_changed = true,
  -- veto
  tool_call = true,
  -- transform
  user_input = true, tool_result = true,
  -- collect
  before_agent_start = true,
}

local Hub = {}
Hub.__index = Hub

local events_mod = { Hub = Hub, EVENTS = EVENTS }

function events_mod.new()
  return setmetatable({ handlers = {} }, Hub)
end

function Hub:on(name, fn)
  if not EVENTS[name] then
    error(("unknown extension event: %q"):format(tostring(name)), 3)
  end
  local list = self.handlers[name]
  if not list then
    list = {}
    self.handlers[name] = list
  end
  list[#list + 1] = fn
end

local function safe_call(name, fn, ...)
  local results = table.pack(pcall(fn, ...))
  if not results[1] then
    log.error("extension handler for %s failed: %s", name, tostring(results[2]))
    return nil
  end
  return table.unpack(results, 2, results.n)
end

--- Run all handlers. Handlers may yield (dialogs).
function Hub:notify(name, ev)
  for _, fn in ipairs(self.handlers[name] or {}) do
    safe_call(name, fn, ev)
  end
end

--- First { block = true } wins. Returns that verdict or nil.
function Hub:veto(name, ev)
  for _, fn in ipairs(self.handlers[name] or {}) do
    local verdict = safe_call(name, fn, ev)
    if type(verdict) == "table" and verdict.block then
      return verdict
    end
  end
  return nil
end

--- Chain handlers over `value`. Returns final value, handled(bool).
function Hub:transform(name, value, ev)
  for _, fn in ipairs(self.handlers[name] or {}) do
    local replacement = safe_call(name, fn, value, ev)
    if type(replacement) == "table" and replacement.handled then
      return value, true
    elseif replacement ~= nil then
      value = replacement
    end
  end
  return value, false
end

--- Gather table results from all handlers.
function Hub:collect(name, ev)
  local out = {}
  for _, fn in ipairs(self.handlers[name] or {}) do
    local result = safe_call(name, fn, ev)
    if type(result) == "table" then
      out[#out + 1] = result
    end
  end
  return out
end

return events_mod
