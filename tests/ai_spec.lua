local loop = require("lupus.loop")
local ai = require("lupus.ai")
local http = require("lupus.ai.http")
local sse = require("lupus.ai.sse")
local partial_json = require("lupus.ai.partial_json")
local models = require("lupus.ai.models")
local anthropic = require("lupus.ai.providers.anthropic")
local openai = require("lupus.ai.providers.openai")
local json = require("lupus.util.json")

-- ---------------------------------------------------------------------------

describe("ai.sse", function()
	it("parses complete events", function()
		local p = sse.new()
		local events = p:feed('event: ping\ndata: {"a":1}\n\ndata: two\n\n')
		assert.equals(2, #events)
		assert.equals("ping", events[1].event)
		assert.equals('{"a":1}', events[1].data)
		assert.equals("message", events[2].event)
		assert.equals("two", events[2].data)
	end)

	it("joins multi-line data and tolerates CRLF and comments", function()
		local p = sse.new()
		local events = p:feed(": keepalive\r\ndata: line1\r\ndata: line2\r\n\r\n")
		assert.equals(1, #events)
		assert.equals("line1\nline2", events[1].data)
	end)

	it("handles events split at arbitrary byte boundaries", function()
		local raw = "event: a\ndata: hello\n\nevent: b\ndata: world\n\n"
		for chunk_size = 1, 7 do
			local p = sse.new()
			local all = {}
			for i = 1, #raw, chunk_size do
				for _, ev in ipairs(p:feed(raw:sub(i, i + chunk_size - 1))) do
					all[#all + 1] = ev
				end
			end
			assert.equals(2, #all, "chunk size " .. chunk_size)
			assert.equals("hello", all[1].data)
			assert.equals("world", all[2].data)
		end
	end)
end)

-- ---------------------------------------------------------------------------

describe("ai.partial_json", function()
	local cases = {
		{ '{"a": "hel', { a = "hel" } },
		{ '{"a": 12', { a = 12 } },
		{ '{"a": tru', { a = true } },
		{ '{"a": [1, 2', { a = { 1, 2 } } },
		{ '{"a": {"b":', { a = { b = json.null } } },
		{ '{"a": 1, "b', { a = 1 } },
		{ '{"a":', { a = json.null } },
		{ '{"a": "x", ', { a = "x" } },
		{ '{"path": "/tmp/x.txt"}', { path = "/tmp/x.txt" } },
		{ '{"s": "a\\', { s = "a" } },
		{ '[1, {"x": "y', { 1, { x = "y" } } },
	}
	for _, case in ipairs(cases) do
		it("completes " .. case[1]:gsub("%%", "%%%%"), function()
			assert.same(case[2], partial_json.parse(case[1]))
		end)
	end

	it("returns nil for hopeless input", function()
		assert.is_nil(partial_json.parse(""))
		assert.is_nil(partial_json.parse("not json at all!"))
	end)
end)

-- ---------------------------------------------------------------------------

describe("ai.models", function()
	it("finds models by id, provider/id, and substring", function()
		models.load({})
		assert.equals("claude-sonnet-4-5", models.get("claude-sonnet-4-5").id)
		assert.equals("claude-sonnet-4-5", models.get("anthropic/claude-sonnet-4-5").id)
		assert.is_not_nil(models.get("sonnet"))
		assert.is_nil(models.get("no-such-model-xyz"))
	end)

	it("merges custom providers and models", function()
		models.load({
			providers = { myserver = { base_url = "http://localhost:8080/v1" } },
			models = { { id = "local-model", provider = "myserver", max_tokens = 1000 } },
		})
		local m = models.get("local-model")
		assert.equals("openai-completions", m.api)
		assert.equals("http://localhost:8080/v1", m.base_url)
		models.load({}) -- reset for other tests
	end)
end)

-- ---------------------------------------------------------------------------
-- Adapter tests: stub http.request to replay fixtures in ragged chunks.

local function fixture(name)
	local f = assert(io.open("tests/fixtures/" .. name, "rb"))
	local data = f:read("*a")
	f:close()
	return data
end

local function stub_http(body, status)
	local real = http.request
	http.request = function(_)
		local pos = 1
		local sizes = { 7, 13, 31, 3, 64, 128 }
		local n = 0
		return {
			status = status or 200,
			headers = {},
			read = function(self)
				if pos > #body then
					return nil
				end
				n = n + 1
				local size = sizes[(n % #sizes) + 1]
				local chunk = body:sub(pos, pos + size - 1)
				pos = pos + size
				return chunk
			end,
			read_all = function(self)
				local rest = body:sub(pos)
				pos = #body + 1
				return rest
			end,
			close = function(self)
				pos = #body + 1
			end,
		}
	end
	return function()
		http.request = real
	end
end

local function collect_stream(model, context, opts)
	local events = {}
	local final
	loop.run(function()
		local stream = ai.stream(model, context, opts or {})
		for ev in stream:events() do
			events[#events + 1] = ev
		end
		final = stream:result()
	end)
	return events, final
end

local function event_types(events)
	local out = {}
	for _, ev in ipairs(events) do
		out[#out + 1] = ev.type
	end
	return out
end

describe("anthropic adapter", function()
	local model = models.get("claude-sonnet-4-5")

	it("streams text and a tool call from a recorded response", function()
		local restore = stub_http(fixture("anthropic_tool.sse"))
		local events, final = collect_stream(model, { messages = { ai.types.user("hi") } })
		restore()

		assert.same({
			"start",
			"text_start",
			"text_delta",
			"text_delta",
			"text_end",
			"toolcall_start",
			"toolcall_delta",
			"toolcall_delta",
			"toolcall_end",
			"done",
		}, event_types(events))
		assert.equals("tool_use", final.stop_reason)
		assert.equals("I'll read the file.", final.content[1].text)
		local tc = final.content[2]
		assert.equals("tool_call", tc.type)
		assert.equals("toolu_1", tc.id)
		assert.equals("read", tc.name)
		assert.same({ path = "/tmp/x.txt" }, tc.arguments)
		-- usage and cost
		assert.equals(100, final.usage.input)
		assert.equals(25, final.usage.output)
		assert.equals(50, final.usage.cache_read)
		assert.equals(10, final.usage.cache_write)
		assert.is_true(final.usage.cost.total > 0)
	end)

	it("streams thinking blocks with signatures", function()
		local restore = stub_http(fixture("anthropic_thinking.sse"))
		local _, final = collect_stream(model, { messages = { ai.types.user("hi") } })
		restore()
		assert.equals("thinking", final.content[1].type)
		assert.equals("Let me think.", final.content[1].thinking)
		assert.equals("c2ln", final.content[1].signature)
		assert.equals("Answer.", final.content[2].text)
		assert.equals("stop", final.stop_reason)
	end)

	it("turns non-2xx responses into error results", function()
		local restore = stub_http('{"error":{"message":"invalid api key"}}', 401)
		local events, final = collect_stream(model, { messages = { ai.types.user("hi") } })
		restore()
		assert.equals("error", events[#events].type)
		assert.equals("error", final.stop_reason)
		assert.matches("invalid api key", final.error_message)
	end)

	it("merges consecutive tool results into one user turn", function()
		local msgs = anthropic._convert_messages({
			{
				role = "assistant",
				content = {
					{ type = "tool_call", id = "t1", name = "read", arguments = { path = "a" } },
					{ type = "tool_call", id = "t2", name = "read", arguments = { path = "b" } },
				},
			},
			{
				role = "tool_result",
				tool_call_id = "t1",
				tool_name = "read",
				content = { { type = "text", text = "A" } },
			},
			{
				role = "tool_result",
				tool_call_id = "t2",
				tool_name = "read",
				content = { { type = "text", text = "B" } },
			},
		})
		assert.equals(2, #msgs)
		assert.equals("assistant", msgs[1].role)
		assert.equals("user", msgs[2].role)
		assert.equals(2, #msgs[2].content)
		assert.equals("tool_result", msgs[2].content[1].type)
	end)
end)

describe("openai adapter", function()
	local model = models.get("gpt-5.1")

	it("streams text with usage from a recorded response", function()
		local restore = stub_http(fixture("openai_text.sse"))
		local events, final = collect_stream(model, { messages = { ai.types.user("hi") } })
		restore()
		assert.equals("done", events[#events].type)
		assert.equals("Hello!", final.content[1].text)
		assert.equals("stop", final.stop_reason)
		assert.equals(30, final.usage.input) -- 50 prompt - 20 cached
		assert.equals(20, final.usage.cache_read)
		assert.equals(5, final.usage.output)
	end)

	it("streams tool calls with JSON-string arguments", function()
		local restore = stub_http(fixture("openai_tool.sse"))
		local _, final = collect_stream(model, { messages = { ai.types.user("hi") } })
		restore()
		assert.equals("tool_use", final.stop_reason)
		local tc = final.content[1]
		assert.equals("call_abc", tc.id)
		assert.equals("bash", tc.name)
		assert.same({ command = "ls" }, tc.arguments)
	end)

	it("round-trips assistant tool calls as JSON strings", function()
		local msgs = openai._convert_messages({
			system_prompt = "sys",
			messages = {
				{
					role = "assistant",
					content = {
						{ type = "tool_call", id = "c1", name = "bash", arguments = { command = "ls" } },
					},
				},
				{
					role = "tool_result",
					tool_call_id = "c1",
					tool_name = "bash",
					content = { { type = "text", text = "out" } },
				},
			},
		})
		assert.equals("system", msgs[1].role)
		assert.equals("assistant", msgs[2].role)
		local args = msgs[2].tool_calls[1]["function"].arguments
		assert.is_string(args)
		assert.same({ command = "ls" }, json.decode(args))
		assert.equals("tool", msgs[3].role)
		assert.equals("out", msgs[3].content)
	end)
end)
