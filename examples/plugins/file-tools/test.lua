-- test.lua — File Tools plugin tests
--
-- Loads the real plugin source with a mocked `nova` bridge and exercises the
-- handlers. Covers:
--   B6  line splitter edge cases (empty, trailing newline, blank lines).
--   B6  extension() basename fix (src.d/file, .gitignore, archive.tar.gz).
--   B6  read truncation marker when the byte budget is exceeded.
--   B6  edit rejects new_string == old_string.
local test = test_runner

-- ── Mock the nova bridge, then load the plugin ──────────────────────
local registered = {}
local file_content = ""
local read_result = nil
local write_reply = true
local edit_reply = true
local last_write = nil

nova = {
  register_tool = function(tool)
    registered[tool.name] = tool
  end,
  read_file = function(path, opts)
    if read_result ~= nil then return read_result end
    return { content = file_content, path = path }
  end,
  write_file = function(path, content)
    last_write = { path = path, content = content }
    return write_reply
  end,
  edit_file = function(path, old_string, new_string)
    return edit_reply
  end,
  list_dir = function() return nil end,
}

local f = assert(io.open("examples/plugins/file-tools/init.lua", "r"))
local src = f:read("*a")
f:close()
assert(load(src, "@file-tools/init.lua"))()

local read = registered.read
local write = registered.write
local edit = registered.edit

local function reset(content)
  file_content = content or ""
  read_result = nil
  write_reply = true
  edit_reply = true
  last_write = nil
end

-- ── B6: line splitter edge cases ────────────────────────────────────

test.describe("read line splitting", function()
  test.it("empty file yields zero lines", function()
    reset("")
    local out = read.handler({ path = "f.txt" })
    test.assert.contains("End of file", out)
    test.assert.is_false(out:find("1: ", 1, true) ~= nil, "no numbered lines")
  end)

  test.it("single line without newline is one line", function()
    reset("a")
    local out = read.handler({ path = "f.txt" })
    test.assert.contains("1: a", out)
  end)

  test.it("trailing newline does not create an extra blank line", function()
    reset("a\n")
    local out = read.handler({ path = "f.txt" })
    test.assert.contains("1: a", out)
    test.assert.is_false(out:find("2: ", 1, true) ~= nil, "no phantom line 2")
  end)

  test.it("blank line between lines is counted", function()
    reset("a\n\nb")
    local out = read.handler({ path = "f.txt" })
    test.assert.contains("1: a", out)
    test.assert.contains("2: ", out)
    test.assert.contains("3: b", out)
  end)
end)

-- ── B6: extension() basename fix ────────────────────────────────────

test.describe("read binary detection", function()
  test.it("a dot in a directory name does not defeat binary detection", function()
    reset("plain text\n")
    -- src.d/file has no extension; it must not be treated as a binary.
    local out = read.handler({ path = "src.d/file" })
    test.assert.is_false(out:find("binary", 1, true) ~= nil, "src.d/file is not binary")
  end)

  test.it("archive.tar.gz is detected as binary via gz", function()
    reset("\0\x01\x02")
    local out = read.handler({ path = "archive.tar.gz" })
    test.assert.contains("binary", out)
  end)

  test.it("a dotfile name is not an extension (.gz dotfile stays text)", function()
    reset("plain text\n")
    -- ".gz" is a dotfile (leading dot, no further dot), so it has NO
    -- extension. The buggy version derived "gz" from the leading dot and
    -- flagged the file binary via BINARY_EXTS despite plain-text content.
    local out = read.handler({ path = ".gz" })
    test.assert.is_false(out:find("binary", 1, true) ~= nil, ".gz dotfile is not binary")
    test.assert.contains("1: plain text", out)
  end)

  test.it("a file with no extension is readable", function()
    reset("plain text\n")
    local out = read.handler({ path = "noext" })
    test.assert.contains("1: plain text", out)
  end)
end)

-- ── B6: read truncation marker ──────────────────────────────────────

test.describe("read truncation", function()
  test.it("appends a truncation marker when the byte budget is exceeded", function()
    -- A single wide line over the 50000-byte budget.
    local big = string.rep("x", 60000)
    read_result = { content = big, path = "big.txt" }
    local out = read.handler({ path = "big.txt" })
    test.assert.contains("truncated", out)
  end)
end)

-- ── B6: edit rejects equal strings ──────────────────────────────────

test.describe("edit validation", function()
  test.it("rejects new_string == old_string", function()
    reset("hello world")
    local out = edit.handler({ path = "f.txt", old_string = "hello", new_string = "hello" })
    test.assert.contains("Error:", out)
    test.assert.contains("must differ", out)
  end)
end)

-- ── basic write / count / replace ───────────────────────────────────

test.describe("write and edit basics", function()
  test.it("write reports byte count on success", function()
    reset("")
    local out = write.handler({ path = "f.txt", content = "abc" })
    test.assert.contains("3 bytes", out)
  end)

  test.it("edit surfaces a write failure", function()
    reset("hello world")
    write_reply = nil
    local out = edit.handler({ path = "f.txt", old_string = "hello", new_string = "goodbye", replace_all = true })
    test.assert.contains("Error:", out)
  end)
end)

test.run()
