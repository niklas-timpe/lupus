-- Eden AI custom provider for lupus — dynamic model discovery.
--
-- Eden AI is an OpenAI-compatible gateway that routes one API key to 600+ models
-- from Anthropic, OpenAI, Google, Mistral, Qwen, etc. This extension fetches
-- Eden's *public* model catalog at startup and registers every model in lupus.
--
-- Why dynamic instead of a hand-written list:
--   - The catalog has 600+ entries and changes often.
--   - Eden's listing endpoint is public (no key needed) and authoritative for
--     context window, pricing, input modalities, and reasoning support.
--
-- The ONE thing Eden does not expose is each model's max *output* tokens. No
-- gateway does. We cross-reference models.dev's `limit.output` by the underlying
-- model id (~92% of Eden's catalog resolves), falling back to DEFAULT_MAX_TOKENS.
--
-- Setup: create a key at https://app.edenai.run (API Keys), then either
-- export it or store it from inside lupus with /login:
--   export EDENAI_API_KEY="..."      # or: /login → edenai → paste the key
--
-- Drop this in ~/.config/lupus/extensions/ or load with:
--   lupus -e examples/extensions/eden-ai.lua
-- Then switch to an Eden model with /model (the choice persists).

local json = require("lupus.util.json")
local models = require("lupus.ai.models")

local BASE_URL = "https://api.edenai.run/v3/llm"
local EDEN_MODELS_URL = "https://api.edenai.run/v3/llm/models"
local MODELSDEV_URL = "https://models.dev/api.json"

local DEFAULT_MAX_TOKENS = 8192 -- fallback when models.dev has no match
local DEFAULT_CONTEXT_WINDOW = 128000 -- fallback if Eden omits context_length

-- ---------------------------------------------------------------------------
-- Helpers

-- Fetch a URL via curl (uses api.exec, yields).
local function fetch_json(api, url)
	local res = api.exec({ "curl", "-sS", "--max-time", "15", url })
	if res.code ~= 0 then
		return nil, "curl exited " .. res.code .. ": " .. (res.stderr:sub(1, 200))
	end
	local data, err = json.decode(res.stdout)
	if not data then
		return nil, "json decode failed: " .. tostring(err)
	end
	return data, nil
end

-- Eden prices per token; Pi/lupus expects $/million tokens.
local function per_million(per_token)
	if not per_token then
		return 0
	end
	return math.floor(per_token * 1000000 * 1e6 + 0.5) / 1e6
end

-- Map Eden's modality list down to what lupus understands.
local function map_input(modalities)
	if not modalities then
		return { "text" }
	end
	local input = {}
	for _, m in ipairs(modalities) do
		if m == "text" and not input.text then
			input[#input + 1] = "text"
		end
		if m == "image" and not input.image then
			input[#input + 1] = "image"
		end
	end
	return #input > 0 and input or { "text" }
end

-- ---------------------------------------------------------------------------
-- models.dev matching (to recover max output tokens)

local VENDOR_PREFIX =
	"^([Aa]nthropic|[Aa]mazon|[Mm]eta|[Aa]i21|[Cc]ohere|[Mm]istral|[Mm]istralAI|[Gg]oogle|[Dd]eepseek|[Qq]wen|[Mm]icrosoft|[Oo]pen[Aa][Ii]|[Bb]ytedance|[Nn]vidia|[Ii][Bb][Mm]%-[Gg]ranite|[Mm]oonshot[Aa][Ii]|[Uu][Ss]|[Ee][Uu]|[Aa]pac|[Gg]lobal)[%.%-]"

local function normalize_id(raw)
	local s = raw:lower():match("^[^@]+") or raw -- strip @region
	s = s:gsub("^/+", ""):gsub("/+$", "")
	-- last path segment (handles cloudflare/@cf/...)
	local last = s:match("/[^/]+$")
	if last then
		s = last:sub(2)
	end
	s = s:gsub(VENDOR_PREFIX, "") -- strip "anthropic." / "meta-" prefixes
	s = s:gsub("[_:]", "-")
	s = s:gsub("%-v%d+%-?%d*$", "") -- drop bedrock version suffixes (-v1:0)
	s = s:gsub("^%-+", ""):gsub("%-+$", "")
	return s
end

local function id_variants(raw)
	local n = normalize_id(raw)
	local no_date = n:gsub("%-%d%d%d%d%-%d%d%-%d%d$", "") -- gpt-5-2025-08-07 → gpt-5
	local seen = {}
	local out = {}
	local candidates = {
		n,
		no_date,
		n:gsub("%-%d%d%d%d%d%d%d%d$", ""),
		n:gsub("%-%d%d%d%d%d%d?%d?%d?$", ""),
		n:gsub("%-(latest|instruct|fp8|it|hf|preview)$", ""),
		n:gsub("%.", "-"),
		no_date:gsub("%-preview$", ""),
	}
	for _, c in ipairs(candidates) do
		if c ~= "" and not seen[c] then
			seen[c] = true
			out[#out + 1] = c
		end
	end
	return out
end

local function build_output_lookup(models_dev)
	local lookup = {}
	for _, provider in pairs(models_dev or {}) do
		local provider_models = type(provider) == "table" and provider.models
		if provider_models then
			for model_id, model_def in pairs(provider_models) do
				local output = model_def.limit and model_def.limit.output
				if output then
					for _, v in ipairs(id_variants(model_id)) do
						if not lookup[v] then
							lookup[v] = output
						end
					end
				end
			end
		end
	end
	return lookup
end

local function lookup_max_tokens(eden_id, lookup)
	for _, v in ipairs(id_variants(eden_id)) do
		if lookup[v] then
			return lookup[v]
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Build a lupus model entry from an Eden catalog entry

local function to_model(m, output_lookup)
	local caps = m.capabilities or {}
	local p = m.pricing or {}
	local cost = {
		input = per_million(p.input_cost_per_token),
		output = per_million(p.output_cost_per_token),
		cache_read = per_million(p.cache_read_input_token_cost),
		cache_write = per_million(p.cache_creation_input_token_cost),
	}
	local context_window = m.context_length or DEFAULT_CONTEXT_WINDOW
	local input = map_input(caps.input_modalities)

	return {
		id = m.id,
		name = m.id,
		provider = "edenai",
		api = "openai-completions",
		base_url = BASE_URL,
		reasoning = caps.supports_reasoning == true,
		context_window = context_window,
		max_tokens = lookup_max_tokens(m.id, output_lookup) or DEFAULT_MAX_TOKENS,
		cost = cost,
		input = input,
	}
end

-- ---------------------------------------------------------------------------
-- Extension entry

return function(api)
	-- Register the provider in the models registry so it's treated like any
	-- other built-in provider (env var resolution, --list-models, etc.).
	-- We use the internal require because lupus's extension API doesn't expose
	-- register_provider() — but extensions can require lupus modules.

	-- 1. Fetch Eden's model catalog (public endpoint, no key needed).
	local eden_data, err = fetch_json(api, EDEN_MODELS_URL)
	if not eden_data then
		api.notify("eden-ai: could not fetch model catalog: " .. tostring(err), "error")
		return
	end

	local eden_models = eden_data.data or (type(eden_data) == "table" and eden_data.models) or {}
	if #eden_models == 0 then
		api.notify("eden-ai: empty model catalog", "warning")
		return
	end

	-- 2. Fetch models.dev for max output tokens (best-effort).
	local output_lookup = {}
	local dev_data, dev_err = fetch_json(api, MODELSDEV_URL)
	if dev_data then
		output_lookup = build_output_lookup(dev_data)
	else
		api.notify("eden-ai: models.dev unavailable (" .. tostring(dev_err) .. "), using default max_tokens", "warning")
	end

	-- 3. Convert each Eden model to a lupus model entry.
	local lupus_models = {}
	for _, m in ipairs(eden_models) do
		if type(m) == "table" and m.id then
			lupus_models[#lupus_models + 1] = to_model(m, output_lookup)
		end
	end

	api.notify(
		("eden-ai: loaded %d models%s"):format(
			#lupus_models,
			dev_data and " (max_tokens resolved from models.dev)" or ""
		)
	)

	-- 4. Add the provider config and models to lupus's settings, then reload
	--    the model registry.
	--    `api.config` is the merged settings table.
	if not api.config.providers then
		api.config.providers = {}
	end
	api.config.providers["edenai"] = {
		base_url = BASE_URL,
		env = "EDENAI_API_KEY",
	}
	if not api.config.models then
		api.config.models = {}
	end
	for _, m in ipairs(lupus_models) do
		api.config.models[#api.config.models + 1] = m
	end

	-- Reload the model registry so --list-models and /model see them.
	models.load(api.config)

	-- 5. Normalize upstream context-overflow errors so the agent retries
	--    instead of surfacing a hard failure.
	local OVERFLOW = "context" -- simplified match; Eden returns "context_length_exceeded"
	api.on("message_end", function(ev)
		local msg = ev.message
		if msg.role ~= "assistant" then
			return
		end
		if msg.provider ~= "edenai" or msg.stop_reason ~= "error" then
			return
		end
		local err = msg.error_message or ""
		if err:find(OVERFLOW, 1, true) then
			return
		end
		-- Rewrite the error so the agent sees it as context overflow and compacts.
		msg.error_message = "context_length_exceeded: " .. err
	end)
end
