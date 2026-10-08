-- test.lua — Search Tools plugin tests
--
-- Regression-tests the grep tool. Two concerns:
--   1. Regex command construction. The original bug: the regex pattern was
--      interpolated BARE into a `bash -c` string, so a `|` was parsed as a
--      shell pipe (rg's output went to a nonexistent command and the search
--      silently returned 0). The fix quotes every dynamic value.
--   2. Backend routing. Substring (default) must use Zay's built-in
--      search_files (self-contained, no rg); only regex=true shells out to rg.
--
-- Command and error tests mock the bridge. Integration tests below restore
-- the real bridge and exercise the handler against temporary fixture files.
local test = test_runner
local real_zay = zay

-- ── Mock the zay bridge, then load the plugin ──────────────────────
local registered = {}
local last_bash = nil
local bash_reply = nil
local last_search = nil
local search_reply = nil
-- Controls the mocked file/dir discrimination for the file-path gating tests.
-- When a path is present in this map, file_info returns that type; otherwise
-- it defaults to "directory" (the common case).
local file_info_types = {}

zay = {
  json_decode = real_zay.json_decode,
  register_tool = function(tool)
    registered[tool.name] = tool
  end,
  run_bash = function(cmd, opts)
    last_bash = { cmd = cmd, opts = opts }
    return bash_reply
  end,
  run_shell = function(cmd, opts)
    last_bash = { cmd = cmd, opts = opts }
    return bash_reply
  end,
  -- Mirrors the bridge contract: "posix" wraps in '...' escaping ' as '\'' ;
  -- "native" applies the PowerShell '' rule on Windows only (on POSIX the two
  -- dialects are identical). The plugin picks the dialect to match the runner,
  -- so with both runners stubbed here it asks for "native".
  shell_quote = function(s, dialect)
    local is_win = type(package) == "table" and type(package.config) == "string"
      and package.config:sub(1, 1) == "\\"
    if dialect == "native" and is_win then
      return "'" .. tostring(s):gsub("'", "''") .. "'"
    end
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
  end,
  search_files = function(root, pattern, opts)
    last_search = { root = root, pattern = pattern, opts = opts }
    return search_reply
  end,
  find_files = function(root, pattern, opts)
    return { root = root, total_matches = 0, results = {}, truncated = false }
  end,
  -- Mocked cross-platform discriminator. In production this is the Zig bridge
  -- (sanitizePath + stat.kind); here we drive it from file_info_types so the
  -- gating logic can be tested deterministically.
  file_info = function(path)
    local t = file_info_types[path] or "directory"
    return { size = 0, type = t, extension = "", language = "", mime_type = "" }
  end,
}

-- Load the plugin source (registers grep + glob into `registered`). The test
-- runner builds with cwd at the repo root; io + load are available because the
-- runner uses a full-access sandbox.
local f = assert(io.open("plugins/packages/search-tools/init.lua", "r"))
local src = f:read("*a")
f:close()
assert(load(src))()

local grep = registered.grep
local function rg_line(file, line, content)
  return assert(real_zay.json_encode({type="match", data={
    path={text=file}, line_number=line, lines={text=content .. "\n"},
  }})) .. "\n"
end

local function reset()
  last_bash = nil
  last_search = nil
end

-- ── Regex command construction (the bug surface) ────────────────────

test.describe("grep regex command construction", function()
  test.it("registers grep and glob tools", function()
    test.assert.is_true(registered.grep ~= nil)
    test.assert.is_true(registered.glob ~= nil)
  end)

  test.it("single-quotes a regex pattern so `|` is not a shell pipe", function()
    reset()
    bash_reply = { stdout = "", stderr = "", code = 1 }
    grep.handler({ pattern = "mcp__|lua__", regex = true })
    test.assert.contains("-e 'mcp__|lua__'", last_bash.cmd)
    -- The bare (unquoted) form is the bug; it must not appear.
    test.assert.is_false(string.find(last_bash.cmd, "-e mcp__", 1, true) ~= nil)
  end)

  test.it("single-quotes a multi-word regex pattern", function()
    reset()
    bash_reply = { stdout = "", stderr = "", code = 1 }
    grep.handler({ pattern = "defer .*deinit", regex = true })
    test.assert.contains("-e 'defer .*deinit'", last_bash.cmd)
  end)

  test.it("escapes single quotes inside the pattern", function()
    reset()
    bash_reply = { stdout = "", stderr = "", code = 1 }
    grep.handler({ pattern = "it's|that", regex = true })
    local is_win = false
    if type(package) == "table" and type(package.config) == "string" then
      is_win = (package.config:sub(1, 1) == "\\")
    elseif type(zay) == "table" and type(zay.get_env) == "function" then
      is_win = (zay.get_env("OS") == "Windows_NT")
    end
    if is_win then
      test.assert.contains([['it''s|that']], last_bash.cmd)
    else
      test.assert.contains([['it'\''s|that']], last_bash.cmd)
    end
  end)

  test.it("quotes the include glob and a root with spaces", function()
    reset()
    bash_reply = { stdout = "", stderr = "", code = 1 }
    grep.handler({ pattern = "foo", regex = true, include = "*.zig", path = "src dir" })
    test.assert.contains("--glob '*.zig'", last_bash.cmd)
    test.assert.contains("'src dir'", last_bash.cmd)
  end)

  test.it("adds -i only when case-insensitive", function()
    reset()
    bash_reply = { stdout = "", stderr = "", code = 1 }
    grep.handler({ pattern = "foo", regex = true })
    test.assert.contains(" -i ", last_bash.cmd)
    grep.handler({ pattern = "foo", regex = true, case_sensitive = true })
    test.assert.is_false(string.find(last_bash.cmd, " -i ", 1, true) ~= nil)
  end)
end)

-- ── Backend routing ─────────────────────────────────────────────────

test.describe("grep backend routing", function()
  test.it("substring uses built-in search_files, not rg", function()
    reset()
    search_reply = { query = "foo", total_matches = 0, results = {}, truncated = false }
    grep.handler({ pattern = "foo" }) -- regex defaults to false
    test.assert.is_true(last_search ~= nil)
    test.assert.is_true(last_bash == nil)
  end)

  test.it("regex shells out to rg, not search_files", function()
    reset()
    bash_reply = { stdout = "", stderr = "", code = 1 }
    grep.handler({ pattern = "foo", regex = true })
    test.assert.is_true(last_bash ~= nil)
    test.assert.is_true(last_search == nil)
  end)
end)

-- ── Regex output handling ───────────────────────────────────────────

test.describe("grep regex output handling", function()
  test.it("groups rg output by file", function()
    reset()
    bash_reply = {
      stdout = rg_line("src/a.zig", 10, "hello") .. rg_line("src/a.zig", 20, "world") .. rg_line("src/b.zig", 5, "hello"),
      stderr = "",
      code = 0,
    }
    local out = grep.handler({ pattern = "hello", regex = true })
    test.assert.contains("Found 3 matches:", out)
    test.assert.contains("src/a.zig:", out)
    test.assert.contains("Line 10: hello", out)
    test.assert.contains("src/b.zig:", out)
  end)

  test.it("keeps content that contains colons intact", function()
    reset()
    bash_reply = { stdout = rg_line("src/a.zig", 3, "map: key: value"), stderr = "", code = 0 }
    local out = grep.handler({ pattern = "map", regex = true })
    test.assert.contains("Line 3: map: key: value", out)
  end)

  test.it("reports no matches on rg exit 1", function()
    reset()
    bash_reply = { stdout = "", stderr = "", code = 1 }
    local out = grep.handler({ pattern = "zzz", regex = true })
    test.assert.contains("No matches found for: zzz", out)
  end)

  test.it("surfaces invalid regex (rg exit 2)", function()
    reset()
    bash_reply = { stdout = "", stderr = "regex parse error", code = 2 }
    local _, out = grep.handler({ pattern = "(", regex = true })
    test.assert.contains("invalid regex or unreadable path", out)
  end)

  test.it("caps output at max_results with a truncation marker", function()
    reset()
    local lines = {}
    for i = 1, 10 do
      table.insert(lines, rg_line("f.zig", i, "match"))
    end
    bash_reply = { stdout = table.concat(lines, "\n") .. "\n", stderr = "", code = 0 }
    local out = grep.handler({ pattern = "match", regex = true, max_results = 3 })
    test.assert.contains("Found at least 4 matches (showing first 3", out)
  end)

  test.it("reports regex needs rg when rg is missing (exit 127)", function()
    reset()
    bash_reply = { stdout = "", stderr = "rg: command not found", code = 127 }
    local _, out = grep.handler({ pattern = "foo", regex = true })
    test.assert.contains("needs ripgrep", out)
  end)

  test.it("reports error when run_bash fails (nil) for regex", function()
    reset()
    bash_reply = nil
    local _, out = grep.handler({ pattern = "foo", regex = true })
    test.assert.contains("regex search failed", out)
  end)
end)

-- ── Substring output handling (built-in search) ─────────────────────

test.describe("grep substring output handling", function()
  test.it("groups native results by file", function()
    reset()
    search_reply = {
      query = "hello",
      total_matches = 2,
      truncated = false,
      results = {
        { file = "src/a.zig", line = 1, content = "hello" },
        { file = "src/b.zig", line = 2, content = "hello world" },
      },
    }
    local out = grep.handler({ pattern = "hello" })
    test.assert.is_true(last_bash == nil)
    test.assert.contains("Found 2 matches:", out)
    test.assert.contains("src/a.zig:", out)
    test.assert.contains("Line 1: hello", out)
    test.assert.contains("src/b.zig:", out)
  end)

  test.it("reports no matches when search_files finds none", function()
    reset()
    search_reply = { query = "zzz", total_matches = 0, results = {}, truncated = false }
    local out = grep.handler({ pattern = "zzz" })
    test.assert.contains("No matches found for: zzz", out)
  end)

  test.it("forwards include, case_sensitive and max_results to search_files", function()
    reset()
    search_reply = { query = "x", total_matches = 0, results = {}, truncated = false }
    grep.handler({ pattern = "x", include = "*.zig", case_sensitive = true, max_results = 7 })
    test.assert.equal("*.zig", last_search.opts.file_pattern)
    test.assert.equal(true, last_search.opts.case_sensitive)
    test.assert.equal(7, last_search.opts.max_results)
  end)

  test.it("reports an error when search_files fails (nil)", function()
    reset()
    search_reply = nil
    local _, out = grep.handler({ pattern = "foo" })
    test.assert.contains("could not search", out)
  end)

  test.it("passes an exact file root to the native bridge", function()
    reset()
    -- An explicit file remains the root; the bridge searches it directly.
    file_info_types["src/skill.zig"] = "file"
    search_reply = {
      query = "deinit",
      total_matches = 1,
      truncated = false,
      results = { { file = "src/skill.zig", line = 18, content = "deinit" } },
    }
    local out = grep.handler({ pattern = "deinit", path = "src/skill.zig" })
    -- Preserve the original file and any caller-supplied include filter.
    test.assert.equal("src/skill.zig", last_search.root)
    test.assert.equal(nil, last_search.opts.file_pattern)
    test.assert.contains("src/skill.zig:", out)
  end)

  test.it("keeps directory-path `path` behavior unchanged (regression)", function()
    reset()
    -- No file_info override -> "src" is treated as a directory.
    search_reply = {
      query = "x",
      total_matches = 1,
      truncated = false,
      results = { { file = "src/a.zig", line = 1, content = "x" } },
    }
    grep.handler({ pattern = "x", path = "src" })
    test.assert.equal("src", last_search.root)
    test.assert.equal(nil, last_search.opts.file_pattern)
  end)
end)

test.describe("glob file-path gating", function()
  local glob = registered.glob

  test.it("returns the single file named by a file-path `path`", function()
    file_info_types["src/skill.zig"] = "file"
    -- Mock find_files to return two candidates; the handler must keep only the
    -- one whose basename matches the restriction.
    zay.find_files = function(root, pattern, opts)
      return {
        root = root,
        total_matches = 2,
        results = {
          { path = "src/skill.zig" },
          { path = "src/other.zig" },
        },
        truncated = false,
      }
    end
    local out = glob.handler({ pattern = "*.zig", path = "src/skill.zig" })
    test.assert.contains("src/skill.zig", out)
    test.assert.is_false(string.find(out, "other.zig", 1, true) ~= nil)
  end)

  test.it("keeps directory-path `path` behavior unchanged (regression)", function()
    zay.find_files = function(root, pattern, opts)
      return {
        root = root,
        total_matches = 1,
        results = { { path = "src/skill.zig" } },
        truncated = false,
      }
    end
    local out = glob.handler({ pattern = "*.zig", path = "src" })
    test.assert.contains("src/skill.zig", out)
  end)
end)

test.describe("grep portable regex behavior", function()
  test.it("reports an exact-file include check failure", function()
    reset()
    local original_find = zay.find_files
    file_info_types["target.zig"] = "file"
    zay.find_files = function() return nil, "PathTraversal" end
    local out, err = grep.handler({pattern="needle", path="target.zig", include="*.zig", regex=true})
    zay.find_files = original_find
    test.assert.equal(nil, out)
    test.assert.equal(nil, last_bash)
    test.assert.contains("PathTraversal", err)
  end)
  test.it("keeps Windows drive letters and colons in file paths", function()
    bash_reply = {stdout=rg_line("C:/repo/src/a:b.zig", 7, "value: needle"), stderr="", code=0}
    local out = assert(grep.handler({pattern="needle", regex=true}))
    test.assert.contains("C:/repo/src/a:b.zig:", out)
    test.assert.contains("Line 7: value: needle", out)
  end)
  test.it("passes relative file paths once without changing cwd", function()
    bash_reply = {stdout="", stderr="", code=1}
    grep.handler({pattern="needle", path="src/skill.zig", regex=true})
    test.assert.contains("-- 'src/skill.zig'", last_bash.cmd)
    test.assert.equal(nil, last_bash.opts.cwd)
  end)
  test.it("does not report empty stdout as success on a shell failure", function()
    bash_reply = {stdout="", stderr="access denied", code=126}
    local out, err = grep.handler({pattern="needle", regex=true})
    test.assert.equal(nil, out)
    test.assert.contains("exit 126", err)
  end)
  test.it("bounds long Unicode match lines without splitting UTF-8", function()
    bash_reply = {stdout=rg_line("src/ü.zig", 1, string.rep("a", 199) .. "ü tail"), stderr="", code=0}
    local out = assert(grep.handler({pattern="a", regex=true}))
    test.assert.contains("src/ü.zig:", out)
    test.assert.is_true(utf8.len(out) ~= nil)
    test.assert.contains(string.rep("a", 199) .. "…", out)
  end)
  test.it("reports malformed ripgrep output instead of no matches", function()
    bash_reply = {stdout="{broken", stderr="", code=0}
    local out, err = grep.handler({pattern="needle", regex=true})
    test.assert.equal(nil, out)
    test.assert.contains("decode ripgrep", err)
  end)
  test.it("surfaces PowerShell's exit-1 mapping of ripgrep errors", function()
    bash_reply = {stdout="", stderr="regex parse error", code=1}
    local out, err = grep.handler({pattern="(", regex=true})
    test.assert.equal(nil, out)
    test.assert.contains("regex parse error", err)
  end)
  test.it("rejects a path before spawning the shell when file_info fails", function()
    reset()
    local original_info = zay.file_info
    zay.file_info = function() return nil, "PathOutsideCwd" end
    local out, err = grep.handler({pattern="needle", path="../outside", regex=true})
    zay.file_info = original_info
    test.assert.equal(nil, out)
    test.assert.equal(nil, last_bash)
    test.assert.contains("PathOutsideCwd", err)
  end)
  test.it("matches the quote dialect to the selected runner", function()
    local original_quote, original_shell = zay.shell_quote, zay.run_shell
    local dialect
    zay.shell_quote = function(s, d) dialect=d; return original_quote(s, d) end
    bash_reply = {stdout="", stderr="", code=1}
    grep.handler({pattern="needle", regex=true})
    test.assert.equal("native", dialect)
    zay.run_shell = nil
    grep.handler({pattern="needle", regex=true})
    zay.run_shell, zay.shell_quote = original_shell, original_quote
    test.assert.equal("posix", dialect)
  end)
end)

-- Only registration is intercepted: every filesystem, quoting, shell and JSON
-- operation below uses the actual Zay bridge. Clean up even after an assertion.
local function with_fixture(fn)
  local mocked = zay
  zay = real_zay
  local root = ".grep-test-" .. os.time() .. "-" .. math.random(1000000)
  local ok, err = pcall(function()
    assert(zay.mkdir(root .. "/src/nested"))
    assert(zay.write_file(root .. "/src/target.zig", "needle\nUPPER\n"))
    assert(zay.write_file(root .. "/src/nested/target.zig", "needle sibling\n"))
    assert(zay.write_file(root .. "/src/prefix-target.zig", "needle prefix\n"))
    assert(zay.write_file(root .. "/src/space ' file.txt", "needle quoted\n"))
    fn(root)
  end)
  local cleaned, cleanup_err = zay.delete_path(root, {recursive=true})
  zay = mocked
  assert(ok, err)
  assert(cleaned, cleanup_err)
end

test.describe("grep real Zay bridge integration", function()
  test.it("searches only the requested file, including include intersection", function()
    with_fixture(function(root)
      local out = assert(grep.handler({pattern="needle", path=root .. "/src/target.zig"}))
      test.assert.contains("Found 1 matches:", out)
      test.assert.is_false(out:find("sibling", 1, true))
      test.assert.is_false(out:find("prefix", 1, true))
      out = assert(grep.handler({pattern="needle", path=root .. "/src/target.zig", include="*.lua"}))
      test.assert.contains("No matches", out)
      local excluded = assert(zay.find_files(root .. "/src/target.zig", "*.lua"))
      test.assert.equal(0, excluded.total_matches)
      local included = assert(zay.find_files(root .. "/src/target.zig", "**/target.?ig"))
      test.assert.equal(1, included.total_matches)
    end)
  end)
  test.it("supports basename and recursive relative path globs", function()
    with_fixture(function(root)
      for _, include in ipairs({"**/*.zig", "target.?ig", "nested/*.zig"}) do
        local out = assert(grep.handler({pattern="needle", path=root .. "/src", include=include}))
        test.assert.contains("Line 1: needle sibling", out)
        test.assert.is_false(out:find("quoted", 1, true))
      end
      local out = assert(grep.handler({pattern="needle", path=root .. "/src", include="nested/*.zig"}))
      test.assert.contains("Found 1 matches:", out)
    end)
  end)
  test.it("handles case sensitivity, result caps and missing roots", function()
    with_fixture(function(root)
      local out = assert(grep.handler({pattern="upper", path=root .. "/src/target.zig"}))
      test.assert.contains("Line 2: UPPER", out)
      out = assert(grep.handler({pattern="upper", path=root .. "/src/target.zig", case_sensitive=true}))
      test.assert.contains("No matches", out)
      out = assert(grep.handler({pattern="needle", path=root .. "/src", max_results=1}))
      test.assert.contains("showing first 1", out)
      local clamped = zay.search_files(root .. "/src/target.zig", "needle", {max_results=9223372036854775807})
      test.assert.equal(1, clamped.total_matches)
      local result, err = grep.handler({pattern="needle", path=root .. "/missing"})
      test.assert.equal(nil, result)
      test.assert.contains("could not search", err)
      result, err = grep.handler({pattern="needle", path="../", regex=true})
      test.assert.equal(nil, result)
      test.assert.contains("PathTraversal", err)
    end)
  end)
  test.it("runs regex searches on relative directories and quoted file paths", function()
    with_fixture(function(root)
      local availability = zay.run_shell("rg --version")
      if not availability or availability.code ~= 0 then
        local out, err = grep.handler({pattern="needle", path=root .. "/src", regex=true})
        test.assert.equal(nil, out)
        test.assert.is_true(err ~= nil)
        print("ripgrep unavailable: verified error; live regex checks skipped")
        return
      end
      for _, path in ipairs({root .. "/src", root .. "/src/target.zig", root .. "/src/space ' file.txt"}) do
        local out = assert(grep.handler({pattern="need(le|less)", path=path, regex=true}))
        test.assert.contains("Line 1: needle", out)
        if path ~= root .. "/src" then test.assert.contains("Found 1 matches:", out) end
      end
      for _, include in ipairs({"*.lua", "nested/*.zig"}) do
        local out = assert(grep.handler({pattern="needle", path=root .. "/src/target.zig", include=include, regex=true}))
        test.assert.contains("No matches", out)
      end
      for _, include in ipairs({"*.zig", "**/target.?ig"}) do
        local out = assert(grep.handler({pattern="needle", path=root .. "/src/target.zig", include=include, regex=true}))
        test.assert.contains("Found 1 matches:", out)
      end
      local out, err = grep.handler({pattern="needle", path=root .. "/missing", regex=true})
      test.assert.equal(nil, out)
      test.assert.contains("unreadable path", err)
      out, err = grep.handler({pattern="(", path=root .. "/src", regex=true})
      test.assert.equal(nil, out)
      test.assert.contains("invalid regex", err)
    end)
  end)
end)

test.run()
