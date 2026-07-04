-- Session persistence: one JSONL file per conversation, one JSON object per
-- line, append-only. Location:
--   <data>/sessions/<cwd with / as ->/<timestamp>_<id>.jsonl
--
-- Entry types:
--   { type = "header", version = 1, id, cwd, created_at }
--   { type = "message", message = <agent message> }
--   { type = "model", model_id = "..." }
--   { type = "info", name = "..." }              (display name)

local fs = require("lupus.util.fs")
local json = require("lupus.util.json")

local VERSION = 1

local Session = {}
Session.__index = Session

local session_mod = { Session = Session, VERSION = VERSION }

local function gen_id()
  return ("%08x%04x"):format(os.time(), math.random(0, 0xFFFF))
end

local function encode_cwd(cwd)
  return (cwd:gsub("/", "-"))
end

function session_mod.dir_for(cwd, data_dir)
  return fs.join(data_dir, "sessions", encode_cwd(cwd))
end

-- ---------------------------------------------------------------------------

--- Create a new persisted session.
function session_mod.create(cwd, data_dir)
  local dir = session_mod.dir_for(cwd, data_dir)
  assert(fs.mkdirp(dir))
  local id = gen_id()
  local path = fs.join(dir, os.date("%Y%m%d-%H%M%S") .. "_" .. id .. ".jsonl")
  local self = setmetatable({
    id = id,
    path = path,
    cwd = cwd,
    entries = {},
    name = nil,
  }, Session)
  self:append({ type = "header", version = VERSION, id = id, cwd = cwd, created_at = os.time() })
  return self
end

--- An unpersisted session (--no-session).
function session_mod.in_memory(cwd)
  return setmetatable({
    id = gen_id(),
    path = nil,
    cwd = cwd,
    entries = { { type = "header", version = VERSION, cwd = cwd, created_at = os.time() } },
  }, Session)
end

--- Open an existing session file.
function session_mod.open(path)
  local data, err = fs.read_file(path)
  if not data then return nil, "cannot read session: " .. tostring(err) end
  local entries = {}
  local id, cwd, name
  for line in data:gmatch("[^\n]+") do
    local entry = json.decode(line)
    if type(entry) == "table" and entry.type then
      entries[#entries + 1] = entry
      if entry.type == "header" then
        id = entry.id
        cwd = entry.cwd
      elseif entry.type == "info" then
        name = entry.name
      end
    end
  end
  if #entries == 0 or entries[1].type ~= "header" then
    return nil, "not a lupus session file"
  end
  return setmetatable({
    id = id or gen_id(),
    path = path,
    cwd = cwd,
    entries = entries,
    name = name,
  }, Session)
end

--- List session files for a cwd, newest first: { { path, mtime, name?, preview } }.
function session_mod.list(cwd, data_dir)
  local dir = session_mod.dir_for(cwd, data_dir)
  local out = {}
  for _, fname in ipairs(fs.list_dir(dir)) do
    if fname:match("%.jsonl$") then
      out[#out + 1] = { path = fs.join(dir, fname), file = fname }
    end
  end
  table.sort(out, function(a, b) return a.file > b.file end) -- timestamp prefix
  for _, item in ipairs(out) do
    local sess = session_mod.open(item.path)
    if sess then
      item.name = sess.name
      local first = sess:first_user_text()
      item.preview = first and first:sub(1, 80):gsub("%s+", " ") or "(empty)"
      item.messages = #sess:messages()
    end
  end
  return out
end

--- Most recent session for cwd, or nil.
function session_mod.continue_recent(cwd, data_dir)
  local sessions = session_mod.list(cwd, data_dir)
  if #sessions == 0 then return nil end
  return session_mod.open(sessions[1].path)
end

-- ---------------------------------------------------------------------------

function Session:append(entry)
  self.entries[#self.entries + 1] = entry
  if self.path then
    local ok, encoded = pcall(json.encode, entry)
    if ok then
      fs.append_file(self.path, encoded .. "\n")
    end
  end
end

function Session:append_message(message)
  self:append({ type = "message", message = message })
end

function Session:append_model(model_id)
  self:append({ type = "model", model_id = model_id })
end

function Session:set_name(name)
  self.name = name
  self:append({ type = "info", name = name })
end

--- Reconstruct the message transcript.
function Session:messages()
  local out = {}
  for _, entry in ipairs(self.entries) do
    if entry.type == "message" and type(entry.message) == "table" then
      out[#out + 1] = entry.message
    end
  end
  return out
end

--- The model id last selected in this session, or nil.
function Session:model_id()
  local id
  for _, entry in ipairs(self.entries) do
    if entry.type == "model" then id = entry.model_id end
  end
  return id
end

function Session:first_user_text()
  for _, entry in ipairs(self.entries) do
    if entry.type == "message" and entry.message.role == "user" then
      local c = entry.message.content
      if type(c) == "string" then return c end
    end
  end
  return nil
end

return session_mod
