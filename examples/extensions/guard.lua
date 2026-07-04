-- Example extension: veto dangerous bash commands before they run, and ask
-- for confirmation on sudo. Drop into ~/.config/lupus/extensions/ or load
-- with `lupus -e examples/extensions/guard.lua`.

local BLOCKED = {
  "rm %-rf /",
  "mkfs",
  ":%(%)%s*{%s*:|:&%s*};",  -- fork bomb
}

return function(api)
  api.on("tool_call", function(ev)
    if ev.tool_name ~= "bash" then return end
    local command = ev.arguments.command or ""

    for _, pattern in ipairs(BLOCKED) do
      if command:match(pattern) then
        return { block = true, reason = "guard.lua: command matches blocked pattern " .. pattern }
      end
    end

    if command:match("^%s*sudo ") then
      local ok = api.confirm{ title = "Allow sudo command?\n  " .. command }
      if not ok then
        return { block = true, reason = "guard.lua: sudo denied by user" }
      end
    end
  end)
end
