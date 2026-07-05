-- App entry: resolves list/session options, builds the runtime, and
-- dispatches to the interactive or print frontend.

local runtime_mod = require("lupus.app.session_runtime")
local models = require("lupus.ai.models")
local config = require("lupus.config")
local session_mod = require("lupus.session")
local fs = require("lupus.util.fs")

local app = {}

local function list_models()
	local cfg = config.load(fs.cwd())
	models.load(cfg.settings)
	io.write("Available models:\n")
	for _, m in ipairs(models.list()) do
		local mark = models.available(m, cfg.settings) and "✓" or " "
		io.write(("  %s %s/%s\n"):format(mark, m.provider, m.id))
	end
	io.write("\n✓ = API key available\n")
	return 0
end

--- Resolve --resume by letting the user pick a session file up front (before
--- raw mode). Returns a session_path or nil.
local function resolve_resume(cwd)
	local cfg = config.load(cwd)
	local sessions = session_mod.list(cwd, cfg.dirs.data)
	if #sessions == 0 then
		io.stderr:write("lupus: no sessions to resume in this directory\n")
		os.exit(1)
	end
	io.write("Resume a session:\n")
	for i, s in ipairs(sessions) do
		if i > 20 then
			break
		end
		io.write(("  %2d) %s  %s (%d msgs)\n"):format(i, s.file:sub(1, 15), s.preview, s.messages or 0))
	end
	io.write("Number (default 1): ")
	local line = io.read("*l")
	local idx = tonumber(line) or 1
	local chosen = sessions[idx]
	if not chosen then
		io.stderr:write("lupus: invalid selection\n")
		os.exit(1)
	end
	return chosen.path
end

function app.run(opts)
	if opts.list_models then
		return list_models()
	end

	local cwd = fs.cwd()
	if opts.session == "resume" then
		opts.session_path = resolve_resume(cwd)
	end

	local ok, runtime = pcall(runtime_mod.new, opts)
	if not ok then
		io.stderr:write("lupus: " .. tostring(runtime) .. "\n")
		return 1
	end

	if opts.mode == "print" then
		return require("lupus.app.print_mode").run(runtime, opts)
	end

	-- Interactive: guard the terminal.
	local uv = require("luv")
	if uv.guess_handle(0) ~= "tty" then
		io.stderr:write("lupus: interactive mode needs a terminal (use -p for non-interactive)\n")
		return 2
	end

	local interactive = require("lupus.app.interactive").new(runtime, {
		initial_prompt = opts.prompt,
	})

	-- Whatever kills us — a crash or a signal — the terminal leaves the
	-- alternate screen and gets its modes back before we exit.
	local loop = require("lupus.loop")
	local screen_mod = require("lupus.tui.screen")
	for _, sig in ipairs({ "SIGTERM", "SIGHUP" }) do
		loop.on_signal(sig, function()
			screen_mod.restore()
			os.exit(1)
		end)
	end
	local results = table.pack(xpcall(function()
		local run_ok, err = loop.run(function()
			interactive:run()
		end)
		if not run_ok then
			error(err, 0)
		end
		return 0
	end, function(err)
		return debug.traceback(tostring(err), 2)
	end))
	if not results[1] then
		screen_mod.restore()
		io.stderr:write("\nlupus crashed:\n" .. tostring(results[2]) .. "\n")
		os.exit(1)
	end
	return table.unpack(results, 2, results.n)
end

return app
