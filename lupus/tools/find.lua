-- find: locate files by name glob (system find, .git skipped).

local s = require("lupus.schema")
local loop = require("lupus.loop")
local tools = require("lupus.tools")

return {
	name = "find",
	label = "Find",
	description = "Find files by name glob (e.g. '*.lua'). Searches "
		.. "recursively from the given directory, skipping .git and node_modules.",
	parameters = s.object({
		pattern = s.string({ desc = "Filename glob, e.g. '*.lua' or 'config.*'", required = true }),
		path = s.string({ desc = "Directory to search (default: working directory)" }),
	}),

	execute = function(args, ctx)
		local target = tools.resolve(args.path or ".", ctx)
		local argv = {
			"find",
			target,
			"(",
			"-name",
			".git",
			"-o",
			"-name",
			"node_modules",
			")",
			"-prune",
			"-o",
			"-name",
			args.pattern,
			"-print",
		}
		local proc = loop.process.spawn({ argv = argv, cwd = ctx.cwd })
		local chunks = {}
		while true do
			local chunk = loop.read(proc.stdout)
			if not chunk then
				break
			end
			chunks[#chunks + 1] = chunk
			if ctx.aborted() then
				proc:terminate()
			end
		end
		proc:wait()
		proc:close()

		local out = table.concat(chunks):gsub("%s+$", "")
		if out == "" then
			return "No files found"
		end
		return (tools.truncate(out, "head"))
	end,

	render_call = function(args)
		return args.pattern .. (args.path and (" in " .. args.path) or "")
	end,
}
