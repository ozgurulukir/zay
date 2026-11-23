-- test.lua — File Tools plugin tests
--
-- Loads the real plugin source with a mocked `zay` bridge and exercises the
-- handlers. Covers:
--   B6  line splitter edge cases (empty, trailing newline, blank lines).
--   B6  extension() basename fix (src.d/file, .gitignore, archive.tar.gz).
--   B6  read truncation marker when the byte budget is exceeded.
--   B6  edit rejects new_string == old_string.
--   #591 read pages through the bridge's line range (sentinel line, footers).
--   #591 edit refuses a file the 1 MB read cap clipped, before any write.
--   #591 split_lines keeps every line of a multi-thousand-line file.
local test = test_runner
local real_zay = zay

-- ── Mock the zay bridge, then load the plugin ──────────────────────
local registered = {}
local file_content = ""
local read_result = nil
-- When set, derives the read reply from the requested window instead of
-- returning `read_result` verbatim, mirroring the real bridge's slicing.
local read_window = nil
local write_reply = true
local edit_reply = true
local last_write = nil
local last_read = nil
local edit_calls = 0

zay = {
  register_tool = function(tool)
    registered[tool.name] = tool
  end,
  read_file = function(path, opts)
    last_read = { path = path, opts = opts }
    if read_window ~= nil then return read_window(path, opts) end
    if read_result ~= nil then return read_result end
    return { content = file_content, path = path }
  end,
  write_file = function(path, content)
    last_write = { path = path, content = content }
    return write_reply
  end,
  edit_file = function(path, old_string, new_string)
    edit_calls = edit_calls + 1
    return edit_reply
  end,
  list_dir = function() return nil end,
}

local f = assert(io.open("plugins/packages/file-tools/init.lua", "r"))
local src = f:read("*a")
f:close()
assert(load(src, "@file-tools/init.lua"))()

local read = registered.read
local write = registered.write
local edit = registered.edit

local function reset(content)
  file_content = content or ""
  read_result = nil
  read_window = nil
  write_reply = true
  edit_reply = true
  last_write = nil
  last_read = nil
  edit_calls = 0
end

-- ── B6: line splitter edge cases ────────────────────────────────────

test.describe("read line splitting", function()
  test.it("empty file yields zero lines", function()
    reset("")
    local out = read.handler({ path = "f.txt" })
    test.assert.contains("Empty file", out)
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
    local _, out = read.handler({ path = "archive.tar.gz" })
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

  test.it("drops lines past the line budget and says how many", function()
    local lines = {}
    for i = 1, 2003 do lines[i] = "row " .. i end
    read_result = { content = table.concat(lines, "\n"), path = "many.txt" }
    local out = read.handler({ path = "many.txt", limit = 2003 })
    test.assert.contains("2000: row 2000", out)
    test.assert.is_false(out:find("2001: ", 1, true) ~= nil, "line 2001 is over the budget")
    test.assert.contains("... 3 lines truncated ...", out)
  end)
end)

-- ── #591: read pages through the bridge's line range ────────────────

-- A bridge double for a newline-terminated file with the given lines. Like
-- the real `applyLineRange`, it returns the window's lines without the
-- terminator of the last one — so a blank final line comes back as nothing
-- but the newline that ends the line before it.
local function windowed(all)
  return function(_, opts)
    local picked = {}
    for i = opts.start_line, math.min(opts.end_line, #all) do
      picked[#picked + 1] = all[i]
    end
    return {
      content = table.concat(picked, "\n"),
      path = "windowed.txt",
      total_lines = #all,
      truncated = false,
    }
  end
end

test.describe("read line-range window", function()
  test.it("asks the bridge for the window plus one sentinel line", function()
    reset("")
    read.handler({ path = "f.txt" })
    test.assert.equal(1, last_read.opts.start_line)
    test.assert.equal(2001, last_read.opts.end_line)

    read.handler({ path = "f.txt", offset = 100, limit = 10 })
    test.assert.equal(100, last_read.opts.start_line)
    test.assert.equal(110, last_read.opts.end_line)
  end)

  test.it("keeps line numbers inside the bridge's accepted range", function()
    reset("")
    read.handler({ path = "f.txt", offset = 1e18, limit = 1e18 })
    test.assert.equal(2147483647, last_read.opts.start_line)
    test.assert.equal(2147483647, last_read.opts.end_line)
  end)

  test.it("stops at the limit when the sentinel line is present", function()
    reset("")
    local all = {}
    for i = 1, 2500 do all[i] = "line " .. i end
    read_window = windowed(all)
    local out = read.handler({ path = "windowed.txt", offset = 100, limit = 10 })
    test.assert.contains("100: line 100", out)
    test.assert.contains("109: line 109", out)
    test.assert.is_false(out:find("110: ", 1, true) ~= nil, "the sentinel is not shown")
    test.assert.contains("(Showing lines 100-109 of 2500. Use offset=110 to continue.)", out)
  end)

  test.it("reports the end of the file when the window holds the rest", function()
    reset("")
    read_window = windowed({ "one", "two", "three" })
    local out = read.handler({ path = "windowed.txt", offset = 2, limit = 50 })
    test.assert.contains("2: two", out)
    test.assert.contains("3: three", out)
    test.assert.contains("(Showing lines 2-3 of 3. End of file.)", out)
  end)

  test.it("restores a blank final line the bridge cannot return", function()
    reset("")
    -- "x" followed by one empty line: the window that reaches the end of the
    -- file comes back as "x\n", because a blank line is only a terminator.
    read_window = windowed({ "x", "" })
    local out = read.handler({ path = "windowed.txt" })
    test.assert.contains("1: x", out)
    test.assert.contains("2: ", out)
    test.assert.contains("(Showing lines 1-2 of 2. End of file.)", out)
  end)

  test.it("does not invent a blank line at the end of a normal file", function()
    reset("")
    read_window = windowed({ "x", "y" })
    local out = read.handler({ path = "windowed.txt" })
    test.assert.contains("2: y", out)
    test.assert.is_false(out:find("3: ", 1, true) ~= nil, "no phantom line 3")
    test.assert.contains("(Showing lines 1-2 of 2. End of file.)", out)
  end)

  test.it("reports an offset past the end of the file", function()
    reset("")
    read_window = windowed({ "x", "y" })
    local out = read.handler({ path = "windowed.txt", offset = 5 })
    test.assert.is_false(out:find("5: ", 1, true) ~= nil, "nothing to number")
    test.assert.contains("(No lines at offset 5; the file has 2 lines.)", out)
  end)
end)

test.describe("read keeps every line of a large file", function()
  local lines = {}
  for i = 1, 25000 do lines[i] = "row " .. i end

  test.it("numbers and counts 25,000 lines without losing one", function()
    reset()
    -- No `total_lines` and no window: the whole body goes through
    -- split_lines, and the count has to come out of the split itself.
    read_result = { content = table.concat(lines, "\n") .. "\n", path = "big.txt" }
    local out = read.handler({ path = "big.txt", limit = 25000 })
    test.assert.contains("1: row 1", out)
    test.assert.contains("2000: row 2000", out)
    test.assert.contains("... 23000 lines truncated ...", out)
    test.assert.contains("(Showing lines 1-25000 of 25000. End of file.)", out)
  end)

  test.it("reads the last page of a 25,000-line file on its own", function()
    reset()
    read_window = windowed(lines)
    local tail = read.handler({ path = "windowed.txt", offset = 24001 })
    test.assert.contains("24001: row 24001", tail)
    test.assert.contains("25000: row 25000", tail)
    test.assert.contains("(Showing lines 24001-25000 of 25000. End of file.)", tail)
  end)
end)

-- ── B6: edit rejects equal strings ──────────────────────────────────

test.describe("edit validation", function()
  test.it("rejects new_string == old_string", function()
    reset("hello world")
    local _, out = edit.handler({ path = "f.txt", old_string = "hello", new_string = "hello" })
    test.assert.contains("Error:", out)
    test.assert.contains("must differ", out)
  end)
end)

-- ── #591: edit refuses a file the read cap clipped ──────────────────

test.describe("edit on a file over the read cap", function()
  local capped = {
    -- The first 1 MB of a 5 MB file, exactly what `zay.read_file` returns.
    content = string.rep("x", 1024 * 1024),
    path = "big.log",
    truncated = true,
    full_size = 5 * 1024 * 1024,
  }

  test.it("replace_all refuses before writing and leaves the file intact", function()
    reset()
    read_result = capped
    local out, err = edit.handler({
      path = "big.log", old_string = "x", new_string = "y", replace_all = true,
    })
    test.assert.is_true(out == nil, "no success text")
    test.assert.contains("1 MB read limit", err)
    test.assert.contains("FileTooLarge", err)
    test.assert.is_true(last_write == nil, "the 1 MB prefix must never be written back")
  end)

  test.it("the single-replacement mode refuses before edit_file too", function()
    reset()
    read_result = capped
    local out, err = edit.handler({ path = "big.log", old_string = "x", new_string = "y" })
    test.assert.is_true(out == nil, "no success text")
    test.assert.contains("FileTooLarge", err)
    test.assert.equal(0, edit_calls)
    test.assert.is_true(last_write == nil, "nothing is written")
  end)

  test.it("a replace_all on a file that fits still writes every replacement", function()
    reset("alpha beta alpha")
    local out = edit.handler({ path = "f.txt", old_string = "alpha", new_string = "gamma", replace_all = true })
    test.assert.contains("Edited f.txt (2 replacements)", out)
    test.assert.equal("gamma beta gamma", last_write.content)
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
    local _, out = edit.handler({ path = "f.txt", old_string = "hello", new_string = "goodbye", replace_all = true })
    test.assert.contains("Error:", out)
  end)
end)

-- Only registration is intercepted above. The checks below run the handlers
-- against the real Zay bridge on temporary files; `zay` is restored after.
local function with_fixture(fn)
  local mocked = zay
  zay = real_zay
  local root = ".file-tools-test-" .. os.time() .. "-" .. math.random(1000000)
  local ok, err = pcall(function()
    assert(zay.mkdir(root))
    fn(root)
  end)
  local cleaned, cleanup_err = zay.delete_path(root, { recursive = true })
  zay = mocked
  assert(ok, err)
  assert(cleaned, cleanup_err)
end

test.describe("read paging against the real bridge", function()
  test.it("paged reads tile the file exactly like one unpaged read", function()
    with_fixture(function(root)
      -- Seven lines, blank lines inside and at the end, newline-terminated.
      local path = root .. "/seven.txt"
      local lines = { "one", "", "three", "four", "", "six", "" }
      assert(zay.write_file(path, table.concat(lines, "\n") .. "\n"))

      local whole = assert(read.handler({ path = path, limit = 7 }))
      test.assert.contains("(Showing lines 1-7 of 7. End of file.)", whole)
      test.assert.contains("2: ", whole)
      test.assert.contains("7: ", whole)

      local first = assert(read.handler({ path = path, offset = 1, limit = 3 }))
      test.assert.contains("1: one", first)
      test.assert.contains("3: three", first)
      test.assert.is_false(first:find("4: ", 1, true) ~= nil, "the sentinel stays out")
      test.assert.contains("(Showing lines 1-3 of 7. Use offset=4 to continue.)", first)

      -- The blank final line survives a window that reaches the end of the file.
      local last = assert(read.handler({ path = path, offset = 5, limit = 3 }))
      test.assert.contains("5: ", last)
      test.assert.contains("6: six", last)
      test.assert.contains("7: ", last)
      test.assert.contains("(Showing lines 5-7 of 7. End of file.)", last)
    end)
  end)

  test.it("counts an unterminated last line and reports offsets past the end", function()
    with_fixture(function(root)
      local path = root .. "/tail.txt"
      assert(zay.write_file(path, "a\nb\nc"))

      local out = assert(read.handler({ path = path }))
      test.assert.contains("3: c", out)
      test.assert.contains("(Showing lines 1-3 of 3. End of file.)", out)

      local past = assert(read.handler({ path = path, offset = 9 }))
      test.assert.contains("(No lines at offset 9; the file has 3 lines.)", past)
    end)
  end)
end)

test.describe("edit over the read cap against the real bridge", function()
  test.it("refuses to replace_all a file larger than 1 MB and keeps every byte", function()
    with_fixture(function(root)
      local path = root .. "/big.log"
      -- The needle sits past the 1 MB cap: a rewrite from the capped read
      -- would drop it together with the rest of the tail.
      local content = string.rep("x", 1024 * 1024 - 8) .. "\n" .. string.rep("y", 64) .. "\nneedle end\n"
      assert(zay.write_file(path, content))
      local before = assert(zay.file_info(path))
      test.assert.is_true(before.size > 1024 * 1024, "the fixture is over the read cap")

      local out, err = edit.handler({
        path = path, old_string = "needle", new_string = "found", replace_all = true,
      })
      test.assert.is_true(out == nil, "the edit is refused")
      test.assert.contains("FileTooLarge", err)

      -- The bridge cannot read past its own cap, so the tail is checked with
      -- bash (git-bash on Windows) through the posix quoting dialect.
      local after = assert(zay.file_info(path))
      test.assert.equal(before.size, after.size)
      local tail = assert(zay.run_bash("tail -c 12 " .. assert(zay.shell_quote(path, "posix"))))
      test.assert.equal(0, tail.code)
      test.assert.contains("needle end", tail.stdout)
    end)
  end)
end)

test.run()
