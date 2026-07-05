-- Markdown block for assistant messages: a light line-based renderer that
-- turns common Markdown into styled, wrapped terminal lines. It re-renders
-- the full text on each streaming update, with a cache keyed on
-- (text, width) so settled frames are free.
--
-- Supported: headings, fenced code blocks, bullet/ordered lists,
-- blockquotes, horizontal rules, inline bold/italic/code/strikethrough
-- and [label](url) links. Tables render as-is (monospace already aligns
-- pipe tables well enough).

local text = require("lupus.tui.text")

local S = text.style

local Markdown = {}
Markdown.__index = Markdown

function Markdown.new(content, opts)
	opts = opts or {}
	return setmetatable({
		content = content or "",
		padding_y = opts.padding_y or 0,
		cache_key = nil,
		cache = nil,
	}, Markdown)
end

function Markdown:set_text(content)
	if content == self.content then
		return
	end
	self.content = content
	self.cache_key = nil
end

function Markdown:append(delta)
	self.content = self.content .. delta
	self.cache_key = nil
end

-- ---------------------------------------------------------------------------
-- Inline styling. `prefix` is the surrounding style (e.g. bold for a
-- heading); every inner reset re-opens it so nesting works.

local function protect_code_spans(s, stash)
	return (s:gsub("`([^`\n]+)`", function(code)
		stash[#stash + 1] = code
		return "\1" .. #stash .. "\1"
	end))
end

local function restore_code_spans(s, stash, prefix)
	return (s:gsub("\1(%d+)\1", function(n)
		local code = stash[tonumber(n)]
		return S.cyan(code) .. prefix
	end))
end

local function style_inline(s, prefix)
	prefix = prefix or ""
	local stash = {}
	s = protect_code_spans(s, stash)
	s = s:gsub("%*%*%*([^%*]+)%*%*%*", function(t)
		return "\27[1;3m" .. t .. text.RESET .. prefix
	end)
	s = s:gsub("%*%*([^%*]+)%*%*", function(t)
		return "\27[1m" .. t .. text.RESET .. prefix
	end)
	s = s:gsub("%*([^%*%s][^%*]-)%*", function(t)
		return "\27[3m" .. t .. text.RESET .. prefix
	end)
	s = s:gsub("~~([^~]+)~~", function(t)
		return "\27[9m" .. t .. text.RESET .. prefix
	end)
	s = s:gsub("%[([^%]]+)%]%(([^%)]+)%)", function(label, url)
		return "\27[4m" .. label .. text.RESET .. prefix .. S.gray(" (" .. url .. ")") .. prefix
	end)
	s = restore_code_spans(s, stash, prefix)
	return prefix .. s .. (prefix ~= "" and text.RESET or "")
end

-- ---------------------------------------------------------------------------

local function heading_style(level, body)
	if level == 1 then
		return style_inline(body, "\27[1;4m")
	elseif level == 2 then
		return style_inline(body, "\27[1m")
	end
	return S.dim(("#"):rep(level)) .. " " .. style_inline(body, "\27[1m")
end

function Markdown:render(width)
	local key = width .. "\0" .. self.content
	if self.cache_key == key then
		return self.cache
	end

	local out = {}
	local function emit(s)
		for _, l in ipairs(text.wrap(s, width)) do
			out[#out + 1] = l
		end
	end

	for _ = 1, self.padding_y do
		out[#out + 1] = ""
	end

	local in_code = false
	local code_lines = {}

	local function flush_code()
		for _, cl in ipairs(code_lines) do
			-- Code is not wrapped (that would mangle it); truncate to width.
			out[#out + 1] = S.gray("│ ") .. text.truncate(S.cyan(cl:gsub("\t", "  ")), width - 2, "…")
		end
		code_lines = {}
	end

	for _, line in ipairs(text.split_lines(self.content)) do
		local fence = line:match("^%s*```")
		if fence then
			if in_code then
				flush_code()
				in_code = false
			else
				in_code = true
				local lang = line:match("^%s*```%s*(%S+)")
				if lang then
					out[#out + 1] = S.gray("│ " .. lang)
				end
			end
		elseif in_code then
			code_lines[#code_lines + 1] = line
		else
			local h_marks, h_body = line:match("^(#+)%s+(.*)$")
			local quote = line:match("^%s*>%s?(.*)$")
			local bullet_indent, bullet_body = line:match("^(%s*)[-%*%+]%s+(.*)$")
			local num_indent, num, num_body = line:match("^(%s*)(%d+)%.%s+(.*)$")
			if h_marks and #h_marks <= 6 then
				out[#out + 1] = ""
				emit(heading_style(#h_marks, h_body))
			elseif line:match("^%s*%-%-%-+%s*$") or line:match("^%s*%*%*%*+%s*$") then
				out[#out + 1] = S.dim(("─"):rep(math.min(width, 40)))
			elseif quote ~= nil then
				for _, l in ipairs(text.wrap(style_inline(quote, "\27[3;90m"), width - 2)) do
					out[#out + 1] = S.gray("┃ ") .. l
				end
			elseif bullet_body then
				local indent = "  " .. bullet_indent
				local wrapped = text.wrap(style_inline(bullet_body), width - #indent - 2)
				for i, l in ipairs(wrapped) do
					out[#out + 1] = indent .. (i == 1 and S.dim("• ") or "  ") .. l
				end
			elseif num_body then
				local marker = num .. ". "
				local indent = "  " .. num_indent
				local wrapped = text.wrap(style_inline(num_body), width - #indent - #marker)
				for i, l in ipairs(wrapped) do
					out[#out + 1] = indent .. (i == 1 and S.dim(marker) or (" "):rep(#marker)) .. l
				end
			elseif line == "" then
				if out[#out] ~= "" then
					out[#out + 1] = ""
				end
			else
				emit(style_inline(line))
			end
		end
	end
	if in_code then
		flush_code()
	end

	for _ = 1, self.padding_y do
		out[#out + 1] = ""
	end

	self.cache_key = key
	self.cache = out
	return out
end

return Markdown
