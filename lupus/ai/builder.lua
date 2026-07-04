-- Stream builder: shared machinery for provider adapters. Adapters push
-- text/thinking/tool-call fragments; the builder maintains the accumulating
-- assistant message (`partial`), keeps tool arguments parsed best-effort,
-- and emits the unified event protocol:
--
--   start
--   text_start / text_delta / text_end          { index, delta?, partial }
--   thinking_start / thinking_delta / thinking_end
--   toolcall_start / toolcall_delta / toolcall_end
--   done  { message }        (exactly one of done|error terminates)
--   error { message }
--
-- Every event carries `partial`, the full message accumulated so far, so
-- consumers can render snapshots instead of tracking deltas.

local types = require("lupus.ai.types")
local partial_json = require("lupus.ai.partial_json")

local Builder = {}
Builder.__index = Builder

local builder = {}

function builder.new(model, emit)
  return setmetatable({
    model = model,
    emit_fn = emit,
    message = types.assistant_new(model),
    open = nil, -- "text" | "thinking" | "toolcall"
    finished = false,
  }, Builder)
end

function Builder:emit(type_, extra)
  local ev = extra or {}
  ev.type = type_
  ev.partial = self.message
  self.emit_fn(ev)
end

function Builder:start()
  self:emit("start")
end

function Builder:current()
  return self.message.content[#self.message.content]
end

--- Close whichever block is open (emits *_end).
function Builder:close_block()
  local open = self.open
  if not open then return end
  self.open = nil
  local index = #self.message.content
  local block = self.message.content[index]
  if open == "toolcall" then
    local args = partial_json.parse(block.arguments_json or "")
    block.arguments = type(args) == "table" and args or {}
    block.arguments_json = nil
    self:emit("toolcall_end", { index = index, tool_call = block })
  else
    self:emit(open .. "_end", { index = index })
  end
end

local function ensure_block(self, kind, opener)
  if self.open ~= kind then
    self:close_block()
    self.message.content[#self.message.content + 1] = opener()
    self.open = kind
    self:emit(kind .. "_start", { index = #self.message.content })
  end
  return self:current()
end

function Builder:text_delta(s)
  if s == "" then return end
  local block = ensure_block(self, "text", function() return types.text_block("") end)
  block.text = block.text .. s
  self:emit("text_delta", { index = #self.message.content, delta = s })
end

function Builder:thinking_delta(s)
  if s == "" then return end
  local block = ensure_block(self, "thinking", function() return types.thinking_block("") end)
  block.thinking = block.thinking .. s
  self:emit("thinking_delta", { index = #self.message.content, delta = s })
end

function Builder:thinking_signature(s)
  local block = self:current()
  if block and block.type == "thinking" then
    block.signature = (block.signature or "") .. s
  end
end

function Builder:tool_start(id, name)
  self:close_block()
  self.message.content[#self.message.content + 1] = types.tool_call_block(id, name)
  self:current().arguments_json = ""
  self.open = "toolcall"
  self:emit("toolcall_start", { index = #self.message.content, id = id, name = name })
end

function Builder:tool_delta(fragment)
  local block = self:current()
  if not block or block.type ~= "tool_call" then return end
  if fragment == "" then return end
  block.arguments_json = (block.arguments_json or "") .. fragment
  local args = partial_json.parse(block.arguments_json)
  if type(args) == "table" then block.arguments = args end
  self:emit("toolcall_delta", { index = #self.message.content, delta = fragment })
end

--- Merge provider usage numbers and recompute cost. Fields are absolute
--- (not deltas); pass only what the provider reported.
function Builder:set_usage(u)
  local usage = self.message.usage
  for _, k in ipairs({ "input", "output", "cache_read", "cache_write" }) do
    if u[k] then usage[k] = u[k] end
  end
  usage.total_tokens = usage.input + usage.output + usage.cache_read + usage.cache_write
  types.calculate_cost(self.model, usage)
end

--- Terminate successfully. stop_reason: "stop" | "length" | "tool_use".
function Builder:finish(stop_reason)
  if self.finished then return end
  self:close_block()
  self.finished = true
  self.message.stop_reason = stop_reason or "stop"
  self:emit("done", { message = self.message })
end

--- Terminate with a failure encoded in the message (never thrown).
function Builder:fail(error_message, stop_reason)
  if self.finished then return end
  self:close_block()
  self.finished = true
  self.message.stop_reason = stop_reason or "error"
  self.message.error_message = error_message
  self:emit("error", { message = self.message })
end

return builder
