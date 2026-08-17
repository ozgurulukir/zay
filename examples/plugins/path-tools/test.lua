-- test.lua — Path Tools plugin tests

local test = test_runner

local registered = {}
local mock_calls = {}

nova = {
  register_tool = function(tool)
    registered[tool.name] = tool
  end,
  mkdir = function(path)
    table.insert(mock_calls, { op = "mkdir", path = path })
    return path ~= "fail_dir"
  end,
  copy_path = function(src, dst)
    table.insert(mock_calls, { op = "copy", src = src, dst = dst })
    return src ~= "fail_src"
  end,
  move_path = function(src, dst)
    table.insert(mock_calls, { op = "move", src = src, dst = dst })
    return src ~= "fail_src"
  end,
  delete_path = function(path, opts)
    table.insert(mock_calls, { op = "delete", path = path, opts = opts })
    return path ~= "fail_path"
  end,
}

local f = assert(io.open("examples/plugins/path-tools/init.lua", "r"))
local src = f:read("*a")
f:close()
assert(load(src))()

test.describe("path-tools plugin", function()
  test.it("registers all 4 path manipulation tools", function()
    test.assert.is_true(registered["create_directory"] ~= nil)
    test.assert.is_true(registered["copy_path"] ~= nil)
    test.assert.is_true(registered["move_path"] ~= nil)
    test.assert.is_true(registered["delete_path"] ~= nil)
  end)

  test.it("create_directory handler calls nova.mkdir", function()
    local res = registered["create_directory"].handler({ path = "src/nested/dir" })
    test.assert.contains("Created directory: src/nested/dir", res)

    local err = registered["create_directory"].handler({ path = "fail_dir" })
    test.assert.contains("Error: could not create", err)
  end)

  test.it("copy_path handler calls nova.copy_path", function()
    local res = registered["copy_path"].handler({ source_path = "a.txt", destination_path = "b.txt" })
    test.assert.contains("Copied a.txt to b.txt", res)

    local err = registered["copy_path"].handler({ source_path = "fail_src", destination_path = "b.txt" })
    test.assert.contains("Error: could not copy", err)
  end)

  test.it("move_path handler calls nova.move_path", function()
    local res = registered["move_path"].handler({ source_path = "a.txt", destination_path = "b.txt" })
    test.assert.contains("Moved a.txt to b.txt", res)

    local err = registered["move_path"].handler({ source_path = "fail_src", destination_path = "b.txt" })
    test.assert.contains("Error: could not move", err)
  end)

  test.it("delete_path handler supports file and recursive deletion", function()
    local res1 = registered["delete_path"].handler({ path = "a.txt" })
    test.assert.contains("Deleted: a.txt", res1)

    local res2 = registered["delete_path"].handler({ path = "dir", recursive = true })
    test.assert.contains("Deleted (recursive): dir", res2)

    local err = registered["delete_path"].handler({ path = "fail_path" })
    test.assert.contains("Error: could not delete", err)
  end)
end)

return test.run()
