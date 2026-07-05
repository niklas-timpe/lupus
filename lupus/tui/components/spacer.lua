-- N blank lines.

local Spacer = {}
Spacer.__index = Spacer

function Spacer.new(n)
	return setmetatable({ n = n or 1 }, Spacer)
end

function Spacer:render(_)
	local lines = {}
	for _ = 1, self.n do
		lines[#lines + 1] = ""
	end
	return lines
end

return Spacer
