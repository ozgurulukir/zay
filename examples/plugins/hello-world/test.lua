-- test.lua — Hello World plugin tests
local test = test_runner

test.describe("hello-world plugin", function()
  test.it("greets by name", function()
    test.assert.equal("Hello, Alice!", "Hello, Alice!")
  end)

  test.it("greets with default", function()
    test.assert.equal("Hello, World!", "Hello, World!")
  end)

  test.it("os.date returns a string", function()
    local time = os.date("%H:%M:%S")
    test.assert.is_true(type(time) == "string")
    test.assert.matches("%d+:%d+:%d+", time)
  end)

  test.it("math operations work", function()
    test.assert.equal(4, 2 + 2)
    test.assert.equal(1, math.floor(1.5))
  end)

  test.it("string operations work", function()
    test.assert.equal("HELLO", string.upper("hello"))
    test.assert.equal(5, string.len("hello"))
  end)

  test.it("table operations work", function()
    local t = { a = 1, b = 2 }
    test.assert.equal(1, t.a)
    test.assert.equal(2, t.b)
  end)

  test.it("assert.error catches errors", function()
    test.assert.error(function()
      error("expected error")
    end)
  end)

  test.it("assert.matches works", function()
    test.assert.matches("hello", "hello world")
  end)

  test.it("assert.contains works", function()
    test.assert.contains("world", "hello world")
  end)

  test.it("assert.has_key works", function()
    test.assert.has_key("name", { name = "test" })
  end)
end)
