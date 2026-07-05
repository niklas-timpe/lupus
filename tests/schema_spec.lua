local s = require("lupus.schema")
local json = require("lupus.util.json")

describe("schema", function()
	local params = s.object({
		path = s.string({ desc = "File path", required = true }),
		offset = s.integer({ desc = "Start line" }),
		limit = s.integer({ desc = "Max lines", default = 2000 }),
		mode = s.enum({ "head", "tail" }, { desc = "Direction" }),
		tags = s.array(s.string({}), { desc = "Tags" }),
		force = s.boolean({}),
	})

	it("accepts valid arguments and applies defaults", function()
		local ok, v = s.validate(params, { path = "/tmp/x", offset = 5 })
		assert.is_true(ok)
		assert.equals("/tmp/x", v.path)
		assert.equals(5, v.offset)
		assert.equals(2000, v.limit)
	end)

	it("rejects missing required fields", function()
		local ok, err = s.validate(params, { offset = 1 })
		assert.is_false(ok)
		assert.matches("path", err)
	end)

	it("rejects wrong types with a useful message", function()
		local ok, err = s.validate(params, { path = 42 })
		assert.is_false(ok)
		assert.matches("expected string", err)
	end)

	it("coerces whole floats to integers", function()
		local ok, v = s.validate(params, { path = "x", offset = 3.0 })
		assert.is_true(ok)
		assert.equals(3, v.offset)
		assert.equals(0, v.offset % 1)
	end)

	it("rejects fractional numbers for integer fields", function()
		local ok, err = s.validate(params, { path = "x", offset = 3.5 })
		assert.is_false(ok)
		assert.matches("integer", err)
	end)

	it("validates enums", function()
		local ok = s.validate(params, { path = "x", mode = "head" })
		assert.is_true(ok)
		local ok2, err = s.validate(params, { path = "x", mode = "sideways" })
		assert.is_false(ok2)
		assert.matches("one of", err)
	end)

	it("validates arrays element-wise", function()
		local ok, v = s.validate(params, { path = "x", tags = { "a", "b" } })
		assert.is_true(ok)
		assert.same({ "a", "b" }, v.tags)
		local ok2, err = s.validate(params, { path = "x", tags = { "a", 7 } })
		assert.is_false(ok2)
		assert.matches("tags%[2%]", err)
	end)

	it("treats JSON null as absent", function()
		local ok, v = s.validate(params, { path = "x", offset = json.null })
		assert.is_true(ok)
		assert.is_nil(v.offset)
	end)

	it("passes unknown keys through", function()
		local ok, v = s.validate(params, { path = "x", extra = "kept" })
		assert.is_true(ok)
		assert.equals("kept", v.extra)
	end)

	it("generates JSON schema with required array and sorted properties", function()
		local js = s.to_json_schema(params)
		assert.equals("object", js.type)
		assert.equals("string", js.properties.path.type)
		assert.equals("File path", js.properties.path.description)
		assert.same({ "path" }, js.required)
		-- required must encode as a JSON array even when empty
		local empty = s.to_json_schema(s.object({ a = s.string({}) }))
		assert.matches('"required":%[%]', json.encode(empty))
	end)

	it("generates enum and array schemas", function()
		local js = s.to_json_schema(params)
		assert.same({ "head", "tail" }, js.properties.mode.enum)
		assert.equals("array", js.properties.tags.type)
		assert.equals("string", js.properties.tags.items.type)
		assert.equals(2000, js.properties.limit.default)
	end)
end)
