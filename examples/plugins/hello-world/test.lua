-- test.lua — Hello World plugin tests
--
-- Loads the real plugin source with a mocked `nova` bridge and exercises the
-- actual handlers (greet, current_time) rather than stdlib tautologies. The
-- `nova` bridge is mocked so the handlers run without a live Nova runtime.
local test = test_runner

-- ── Mock the nova bridge, then load the plugin ──────────────────────
local registered = {}
nova = {
  register_tool = function(tool)
    registered[tool.name] = tool
  end,
}

local f = assert(io.open("examples/plugins/hello-world/init.lua", "r"))
local src = f:read("*a")
f:close()
assert(load(src, "@hello-world/init.lua"))()

test.describe("hello-world plugin", function()
  test.it("registers greet and current_time tools", function()
    test.assert.is_true(registered.greet ~= nil)
    test.assert.is_true(registered.current_time ~= nil)
  end)

  test.it("greets by name", function()
    test.assert.equal("Hello, Alice!", registered.greet.handler({ name = "Alice" }))
  end)

  test.it("greets World when name is missing", function()
    test.assert.equal("Hello, World!", registered.greet.handler({}))
  end)

  test.it("current_time matches HH:MM:SS", function()
    local out = registered.current_time.handler({})
    test.assert.matches("%d%d:%d%d:%d%d", out)
  end)
end)

test.run()
