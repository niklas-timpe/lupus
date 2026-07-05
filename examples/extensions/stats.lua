-- Example extension: a /stats command and a custom tool. Shows commands,
-- tools, events, and flags working together.

local schema = require("lupus.schema")

return function(api)
	local tool_calls = 0

	api.on("tool_end", function()
		tool_calls = tool_calls + 1
	end)

	api.register_command({
		name = "stats",
		description = "Show tool-call count for this session",
		run = function()
			api.notify(("tools executed this session: %d"):format(tool_calls))
		end,
	})

	api.register_tool({
		name = "word_count",
		label = "Word count",
		description = "Count words and lines in a file",
		parameters = schema.object({
			path = schema.string({ desc = "File to count", required = true }),
		}),
		execute = function(args, ctx)
			local res = api.exec({ "wc", "-lw", args.path }, { cwd = ctx.cwd })
			if res.code ~= 0 then
				error(res.stderr)
			end
			return res.stdout:gsub("^%s+", "")
		end,
	})
end
