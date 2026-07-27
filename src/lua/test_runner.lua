--[[
test_runner.lua — Minimal Lua test framework for Nova plugins.

Provides describe/it/assert API similar to Busted or LuaUnit.
Usage:
  local test = require("test_runner")
  test.describe("my plugin", function()
    test.it("does something", function()
      test.assert.equal(4, 2 + 2)
    end)
  end)
  test.run()
]]

local test_runner = {}

-- Test state
local suites = {}
local current_suite = nil
local failures = 0
local successes = 0

-- ANSI color codes (when available)
local color = {
  green = "\27[32m",
  red = "\27[31m",
  yellow = "\27[33m",
  cyan = "\27[36m",
  reset = "\27[0m",
}

--- Define a test suite.
-- @param name string: suite description
-- @param fn function: suite body containing it() calls
function test_runner.describe(name, fn)
  table.insert(suites, { name = name, tests = {} })
  current_suite = suites[#suites]
  local ok, err = pcall(fn)
  if not ok then
    io.stderr:write(string.format("SUITE ERROR: %s\n", err))
  end
  current_suite = nil
end

--- Define a single test case.
-- @param name string: test description
-- @param fn function: test body; raises an error on failure
function test_runner.it(name, fn)
  if not current_suite then
    error("it() must be called inside describe()")
  end
  table.insert(current_suite.tests, { name = name, fn = fn })
end

--- Assertion functions.
test_runner.assert = {}

--- Assert that a value is truthy.
function test_runner.assert.is_true(value, message)
  if not value then
    error(message or "expected truthy value, got " .. tostring(value))
  end
end

--- Assert that a value is falsy.
function test_runner.assert.is_false(value, message)
  if value then
    error(message or "expected falsy value, got " .. tostring(value))
  end
end

--- Assert that two values are equal (using ==).
function test_runner.assert.equal(expected, actual, message)
  if expected ~= actual then
    error(message or string.format("expected %s, got %s", tostring(expected), tostring(actual)))
  end
end

--- Assert that two values are NOT equal.
function test_runner.assert.not_equal(a, b, message)
  if a == b then
    error(message or string.format("expected %s ~= %s", tostring(a), tostring(b)))
  end
end

--- Assert that a string matches a pattern.
function test_runner.assert.matches(pattern, str, message)
  if not string.find(str, pattern) then
    error(message or string.format("expected '%s' to match '%s'", str, pattern))
  end
end

--- Assert that a function raises an error.
function test_runner.assert.error(fn, expected_message, message)
  local ok, err = pcall(fn)
  if ok then
    error(message or "expected error, but none was raised")
  end
  if expected_message and not string.find(err, expected_message) then
    error(message or string.format("expected error containing '%s', got '%s'", expected_message, err))
  end
end

--- Assert that a table has a given key.
function test_runner.assert.has_key(key, tbl, message)
  if tbl[key] == nil then
    error(message or string.format("expected table to have key '%s'", key))
  end
end

--- Assert that a string contains a substring.
function test_runner.assert.contains(sub, str, message)
  if not string.find(str, sub, 1, true) then
    error(message or string.format("expected '%s' to contain '%s'", str, sub))
  end
end

--- Run all registered test suites and print results.
-- @return boolean: true if all tests passed
function test_runner.run()
  local total = 0
  local passed = 0
  local failed = 0

  io.write(color.cyan .. "Running Lua plugin tests...\n" .. color.reset)

  for _, suite in ipairs(suites) do
    io.write(string.format("  %s:\n", suite.name))
    for _, test in ipairs(suite.tests) do
      total = total + 1
      local ok, err = pcall(test.fn)
      if ok then
        passed = passed + 1
        io.write(string.format("    %s✓%s %s\n", color.green, color.reset, test.name))
      else
        failed = failed + 1
        io.write(string.format("    %s✗%s %s\n", color.red, color.reset, test.name))
        io.write(string.format("      %s%s%s\n", color.yellow, err, color.reset))
      end
    end
  end

  io.write(string.format("\n%d tests: %d passed, %d failed\n", total, passed, failed))

  if failed > 0 then
    io.write(color.red .. "SOME TESTS FAILED\n" .. color.reset)
  else
    io.write(color.green .. "ALL TESTS PASSED\n" .. color.reset)
  end

  return failed == 0
end

return test_runner
