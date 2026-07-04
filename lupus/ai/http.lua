-- Streaming HTTP client on top of a curl subprocess. curl owns TLS, HTTP/2,
-- proxies, and system CA certs; its stdout pipe plugs into the same event
-- loop as everything else, and aborting a request is just killing a pid.
--
--   local resp, err = http.request{ url=..., method="POST",
--     headers={ ["content-type"]="application/json" }, body=..., timeout_connect=15 }
--   resp.status, resp.headers (lowercase keys)
--   resp:read() -> chunk | nil at EOF     -- yields
--   resp:close()                          -- kill early (abort)

local loop = require("lupus.loop")
local log = require("lupus.util.log")

local http = {}

local Response = {}
Response.__index = Response

local checked_curl = false

function http.check_curl()
  if checked_curl then return true end
  local proc = loop.process.spawn{ argv = { "curl", "--version" } }
  local out = loop.read(proc.stdout) or ""
  proc:wait()
  proc:close()
  if out:match("^curl %d") then
    checked_curl = true
    return true
  end
  return nil, "curl not found in PATH — lupus needs curl for API requests"
end

--- Read from the response stream until `pattern` (plain) is found or EOF.
--- Returns consumed, rest.
local function read_until(proc, buf, pattern)
  while true do
    local at = buf:find(pattern, 1, true)
    if at then
      return buf:sub(1, at - 1), buf:sub(at + #pattern)
    end
    local chunk = loop.read(proc.stdout)
    if not chunk then
      return nil, buf
    end
    buf = buf .. chunk
  end
end

local function parse_head(head)
  local lines = {}
  for line in head:gmatch("[^\r\n]+") do lines[#lines + 1] = line end
  local status = tonumber(lines[1] and lines[1]:match("^HTTP/[%d%.]+%s+(%d+)"))
  local headers = {}
  for i = 2, #lines do
    local k, v = lines[i]:match("^([^:]+):%s*(.*)$")
    if k then headers[k:lower()] = v end
  end
  return status, headers
end

--- Issue a request. yields. Returns a Response (any status) or nil, err
--- for transport-level failures.
function http.request(opts)
  local ok, err = http.check_curl()
  if not ok then return nil, err end

  local argv = {
    "curl", "-sS", "--no-buffer", "-i",
    "--connect-timeout", tostring(opts.timeout_connect or 15),
    "-X", opts.method or "GET",
  }
  for k, v in pairs(opts.headers or {}) do
    argv[#argv + 1] = "-H"
    argv[#argv + 1] = k .. ": " .. v
  end
  if opts.body then
    argv[#argv + 1] = "--data-binary"
    argv[#argv + 1] = "@-"
  end
  argv[#argv + 1] = opts.url

  local proc = loop.process.spawn{ argv = argv, stdin = opts.body and "pipe" or nil }

  -- Drain stderr concurrently so curl can't block on a full pipe; keep the
  -- tail for error reporting.
  local stderr_buf = {}
  loop.spawn(function()
    while true do
      local chunk = loop.read(proc.stderr)
      if not chunk then return end
      stderr_buf[#stderr_buf + 1] = chunk
      if #stderr_buf > 64 then table.remove(stderr_buf, 1) end
    end
  end)

  if opts.body then
    local wok, werr = loop.write(proc.stdin, opts.body)
    proc:close_stdin()
    if not wok then
      proc:terminate()
      return nil, "failed to send request body: " .. tostring(werr)
    end
  end

  -- Parse response head; skip interim 1xx blocks.
  local buf = ""
  local status, headers
  while true do
    local head, rest = read_until(proc, buf, "\r\n\r\n")
    if not head then
      -- EOF before headers: transport failure. Wait for curl's verdict.
      local code = proc:wait()
      proc:close()
      local msg = table.concat(stderr_buf):gsub("%s+$", "")
      if msg == "" then msg = "connection failed (curl exit " .. code .. ")" end
      return nil, msg
    end
    buf = rest
    status, headers = parse_head(head)
    if not status then
      proc:terminate()
      proc:close()
      return nil, "malformed HTTP response"
    end
    if status < 100 or status >= 200 then break end
  end

  log.debug("http %s %s -> %d", opts.method or "GET", opts.url, status)
  return setmetatable({
    status = status,
    headers = headers,
    proc = proc,
    buf = buf,
    done = false,
  }, Response)
end

--- Next body chunk, or nil at EOF. yields
function Response:read()
  if self.buf ~= "" then
    local chunk = self.buf
    self.buf = ""
    return chunk
  end
  if self.done then return nil end
  local chunk = loop.read(self.proc.stdout)
  if not chunk then
    self.done = true
    self.proc:wait()
    self.proc:close()
  end
  return chunk
end

--- Read the entire remaining body. yields
function Response:read_all()
  local parts = {}
  while true do
    local chunk = self:read()
    if not chunk then break end
    parts[#parts + 1] = chunk
  end
  return table.concat(parts)
end

--- Abort: kill curl and close pipes.
function Response:close()
  if not self.done then
    self.done = true
    self.proc:terminate()
    self.proc:close()
  end
end

return http
