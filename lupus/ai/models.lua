-- Model registry: a built-in catalog plus user-defined providers/models
-- from config. A model is:
--   { id, name, provider, api = "anthropic-messages" | "openai-completions",
--     base_url, reasoning = bool, context_window, max_tokens,
--     cost = { input, output, cache_read, cache_write } }   -- $/Mtok

local models = {}

local providers = {
	anthropic = {
		api = "anthropic-messages",
		base_url = "https://api.anthropic.com",
		env = "ANTHROPIC_API_KEY",
	},
	openai = {
		api = "openai-completions",
		base_url = "https://api.openai.com/v1",
		env = "OPENAI_API_KEY",
	},
	openrouter = {
		api = "openai-completions",
		base_url = "https://openrouter.ai/api/v1",
		env = "OPENROUTER_API_KEY",
	},
	groq = {
		api = "openai-completions",
		base_url = "https://api.groq.com/openai/v1",
		env = "GROQ_API_KEY",
	},
	ollama = {
		api = "openai-completions",
		base_url = "http://localhost:11434/v1",
		env = nil, -- no key needed
	},
}

local builtin = {
	-- Anthropic
	{
		id = "claude-opus-4-5",
		name = "Claude Opus 4.5",
		provider = "anthropic",
		reasoning = true,
		context_window = 200000,
		max_tokens = 32000,
		cost = { input = 5, output = 25, cache_read = 0.5, cache_write = 6.25 },
	},
	{
		id = "claude-sonnet-4-5",
		name = "Claude Sonnet 4.5",
		provider = "anthropic",
		reasoning = true,
		context_window = 200000,
		max_tokens = 64000,
		cost = { input = 3, output = 15, cache_read = 0.3, cache_write = 3.75 },
	},
	{
		id = "claude-haiku-4-5",
		name = "Claude Haiku 4.5",
		provider = "anthropic",
		reasoning = true,
		context_window = 200000,
		max_tokens = 64000,
		cost = { input = 1, output = 5, cache_read = 0.1, cache_write = 1.25 },
	},
	-- OpenAI
	{
		id = "gpt-5.1",
		name = "GPT-5.1",
		provider = "openai",
		reasoning = true,
		context_window = 400000,
		max_tokens = 128000,
		cost = { input = 1.25, output = 10, cache_read = 0.125, cache_write = 0 },
	},
	{
		id = "gpt-5.1-codex",
		name = "GPT-5.1 Codex",
		provider = "openai",
		reasoning = true,
		context_window = 400000,
		max_tokens = 128000,
		cost = { input = 1.25, output = 10, cache_read = 0.125, cache_write = 0 },
	},
	{
		id = "gpt-4.1",
		name = "GPT-4.1",
		provider = "openai",
		reasoning = false,
		context_window = 1000000,
		max_tokens = 32768,
		cost = { input = 2, output = 8, cache_read = 0.5, cache_write = 0 },
	},
}

local registry = nil

local function materialize(entry, provider_overrides)
	local prov = providers[entry.provider] or provider_overrides[entry.provider]
	local m = {
		id = entry.id,
		name = entry.name or entry.id,
		provider = entry.provider,
		api = entry.api or (prov and prov.api) or "openai-completions",
		base_url = entry.base_url or (prov and prov.base_url),
		reasoning = entry.reasoning or false,
		context_window = entry.context_window or 128000,
		max_tokens = entry.max_tokens or 8192,
		cost = entry.cost or { input = 0, output = 0, cache_read = 0, cache_write = 0 },
	}
	return m
end

--- Build the registry. `config` may carry `providers` (same shape as the
--- built-in provider table, plus api_key) and `models` (model entries).
function models.load(config)
	config = config or {}
	registry = { list = {}, by_key = {} }

	for name, prov in pairs(config.providers or {}) do
		providers[name] = {
			api = prov.api or "openai-completions",
			base_url = prov.base_url,
			env = prov.env,
			api_key = prov.api_key,
		}
	end

	local function add(entry)
		local m = materialize(entry, config.providers or {})
		registry.list[#registry.list + 1] = m
		registry.by_key[m.provider .. "/" .. m.id] = m
		if not registry.by_key[m.id] then
			registry.by_key[m.id] = m
		end
	end

	for _, entry in ipairs(builtin) do
		add(entry)
	end
	for _, entry in ipairs(config.models or {}) do
		add(entry)
	end
	return registry
end

local function ensure_loaded()
	if not registry then
		models.load({})
	end
end

--- Find a model: exact "provider/id", exact id, then case-insensitive
--- substring of id or name.
function models.get(query)
	ensure_loaded()
	if not query or query == "" then
		return nil
	end
	local hit = registry.by_key[query]
	if hit then
		return hit
	end
	local needle = query:lower()
	for _, m in ipairs(registry.list) do
		if m.id:lower():find(needle, 1, true) or m.name:lower():find(needle, 1, true) then
			return m
		end
	end
	return nil
end

function models.list()
	ensure_loaded()
	return registry.list
end

--- Resolve the API key for a model: config keys > provider env var.
function models.api_key(model, config)
	local keys = config and config.api_keys or {}
	if keys[model.provider] then
		return keys[model.provider]
	end
	local prov = providers[model.provider]
	if prov and prov.api_key then
		return prov.api_key
	end
	if prov and prov.env then
		return os.getenv(prov.env)
	end
	return nil
end

--- True when the model can be used right now (has a key or needs none).
function models.available(model, config)
	local prov = providers[model.provider]
	if prov and prov.env == nil and not prov.api_key then
		return true
	end
	return models.api_key(model, config) ~= nil
end

--- Default model: the first available one, preferring Anthropic order.
function models.default(config)
	ensure_loaded()
	for _, m in ipairs(registry.list) do
		if models.available(m, config) then
			return m
		end
	end
	return nil
end

function models.provider_info(name)
	return providers[name]
end

--- All known providers, sorted by name: { name, env, api, base_url,
--- has_key (a key is configured directly on the provider) }.
function models.providers()
	local out = {}
	for name, prov in pairs(providers) do
		out[#out + 1] = {
			name = name,
			env = prov.env,
			api = prov.api,
			base_url = prov.base_url,
			has_key = prov.api_key ~= nil,
		}
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

return models
