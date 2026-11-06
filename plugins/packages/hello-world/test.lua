-- test.lua — Hello World plugin tests
--
-- Loads the real plugin source with a mocked `zay` bridge and exercises the
-- actual handlers (greet, current_time) rather than stdlib tautologies. The
-- `zay` bridge is mocked so the handlers run without a live Zay runtime.
local test = test_runner

-- ── Bridge surface (must stay ABOVE the zay mock) ──────────────────
-- These assertions run against the REAL bridge tables the Zig test runner
-- registers: `plugin` unconditionally, `zay` because the runner provides an
-- Io. The `zay = { ... }` mock below replaces the real bridge for the
-- handler tests, so anything asserting on real bridge state belongs here —
-- capture values before the mock, assert inside the it blocks.
local bridge_shell_quote = zay and zay.shell_quote
local bridge_file_info = zay and zay.file_info
local bridge_json_encode = zay and zay.json_encode
local bridge_json_decode = zay and zay.json_decode

test.describe("bridge surface", function()
  test.it("exposes the plugin table with get_config", function()
    test.assert.is_true(type(plugin) == "table")
    test.assert.is_true(type(plugin.get_config) == "function")
  end)

  test.it("plugin.get_config returns nil without settings", function()
    test.assert.is_true(plugin.get_config() == nil)
  end)

  test.it("zay.shell_quote quotes for posix by default", function()
    test.assert.is_true(bridge_shell_quote ~= nil)
    test.assert.equal("'a'\\''b'", bridge_shell_quote("a'b"))
    test.assert.equal("''", bridge_shell_quote(""))
  end)

  test.it("zay.shell_quote rejects an unknown dialect", function()
    local v, err = bridge_shell_quote("x", "bogus")
    test.assert.is_true(v == nil)
    test.assert.is_true(string.find(err, "dialect", 1, true) ~= nil)
  end)

  test.it("zay.file_info inspects directories correctly", function()
    test.assert.is_true(bridge_file_info ~= nil)
    local info = bridge_file_info(".")
    test.assert.is_true(info ~= nil)
    test.assert.equal("directory", info.type)
  end)

  test.it("zay.json_encode handles numeric keys and circular references", function()
    test.assert.is_true(bridge_json_encode ~= nil)
    test.assert.is_true(bridge_json_decode ~= nil)
    local mixed = { [5] = "five", name = "test" }
    local encoded = bridge_json_encode(mixed)
    local decoded = bridge_json_decode(encoded)
    test.assert.equal("five", decoded["5"])
    test.assert.equal("test", decoded["name"])
    local circ = { a = 1 }
    circ.loop = circ
    local circ_encoded = bridge_json_encode(circ)
    test.assert.is_true(circ_encoded ~= nil)
    test.assert.is_true(string.find(circ_encoded, "null", 1, true) ~= nil)
  end)
end)

-- ── Mock the zay bridge, then load the plugin ──────────────────────
local registered = {}
zay = {
  register_tool = function(tool)
    registered[tool.name] = tool
  end,
}

local f = assert(io.open("plugins/packages/hello-world/init.lua", "r"))
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
