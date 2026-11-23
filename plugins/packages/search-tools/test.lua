-- test.lua — Search Tools plugin tests
--
-- Regression-tests the grep and glob tools:
--   1. Regex command construction. The original bug: the regex pattern was
--      interpolated BARE into a `bash -c` string, so a `|` was parsed as a
--      shell pipe (rg's output went to a nonexistent command and the search
--      silently returned 0). The fix quotes every dynamic value.
--   2. Backend routing. Substring (default) uses Zay's built-in search_files
--      (self-contained, no rg); regex=true shells out to rg (#590: a literal
--      search that finds nothing is retried as a regex when the pattern
--      carries regex syntax).
--   3. #590 reliability: rg output is bounded per file and narrowed once
--      when it overflows the plugin shell's cap; glob hands a file root to
--      the bridge; paths print relative to the workspace; the manifest's
--      budgets cover what grep asks for.
--
-- Command and error tests mock the bridge. Integration tests below restore
-- the real bridge and exercise the handler against temporary fixture files.
local test = test_runner
local real_zay = zay

-- ── Mock the zay bridge, then load the plugin ──────────────────────
local registered = {}
local last_bash = nil
local bash_reply = nil
local bash_err = nil
-- Replies for successive shell calls, in order; the last one repeats. Each
-- is `{ result = <table or nil>, err = <string or nil> }`. Empty: every
-- call answers `bash_reply` / `bash_err`.
local bash_sequence = {}
local bash_cmds = {}
local last_search = nil
local search_reply = nil
local last_find = nil
local find_reply = nil
-- Controls the mocked file/dir discrimination for the file-path gating tests.
-- When a path is present in this map, file_info returns that type; otherwise
-- it defaults to "directory" (the common case).
local file_info_types = {}
local file_info_calls = 0
local mock_cwd = "/workspace"
local mock_env = {}

local function next_bash_reply(call_index)
  if #bash_sequence == 0 then return { result = bash_reply, err = bash_err } end
  return bash_sequence[math.min(call_index, #bash_sequence)]
end

zay = {
  json_decode = real_zay.json_decode,
  register_tool = function(tool)
    registered[tool.name] = tool
  end,
  run_bash = function(cmd, opts)
    local reply = next_bash_reply(#bash_cmds + 1)
    table.insert(bash_cmds, cmd)
    last_bash = { cmd = cmd, opts = opts }
    return reply.result, reply.err
  end,
  run_shell = function(cmd, opts)
    local reply = next_bash_reply(#bash_cmds + 1)
    table.insert(bash_cmds, cmd)
    last_bash = { cmd = cmd, opts = opts }
    return reply.result, reply.err
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
    last_find = { root = root, pattern = pattern, opts = opts }
    if find_reply ~= nil then return find_reply.result, find_reply.err end
    return { root = root, total_matches = 0, results = {}, truncated = false }
  end,
  -- Mocked cross-platform discriminator. In production this is the Zig bridge
  -- (sanitizePath + stat.kind); here we drive it from file_info_types so the
  -- gating logic can be tested deterministically.
  file_info = function(path)
    file_info_calls = file_info_calls + 1
    local t = file_info_types[path] or "directory"
    return { size = 0, type = t, extension = "", language = "", mime_type = "" }
  end,
  get_cwd = function() return mock_cwd end,
  get_env = function(name) return mock_env[name] end,
}

-- Load the plugin source (registers grep + glob into `registered`). The test
-- runner builds with cwd at the repo root; io + load are available because the
-- runner uses a full-access sandbox.
local f = assert(io.open("plugins/packages/search-tools/init.lua", "r"))
local src = f:read("*a")
f:close()
assert(load(src))()

local grep = registered.grep
local glob = registered.glob
local function rg_line(file, line, content)
  return assert(real_zay.json_encode({type="match", data={
    path={text=file}, line_number=line, lines={text=content .. "\n"},
  }})) .. "\n"
end

local no_match = { query = "", total_matches = 0, results = {}, truncated = false }

local function reset()
  last_bash = nil
  bash_reply = nil
  bash_err = nil
  bash_sequence = {}
  bash_cmds = {}
  last_search = nil
  last_find = nil
  find_reply = nil
  file_info_calls = 0
  mock_cwd = "/workspace"
  mock_env = {}
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

  test.it("bounds ripgrep to the requested matches per file", function()
    reset()
    bash_reply = { stdout = "", stderr = "", code = 1 }
    grep.handler({ pattern = "needle", regex = true, max_results = 20 })
    -- The bound is a quoted argument ahead of the pattern, so the stream is
    -- capped at its source instead of only after the shell drains it.
    test.assert.contains("-m '20' -e 'needle' -- '.'", last_bash.cmd)
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

-- ── #590: regex retry for an undecided pattern ──────────────────────

test.describe("grep regex retry", function()
  test.it("retries regex syntax that found nothing literal", function()
    local retried = { "a|b", "foo.*bar", "^import", "\\bword\\b", "[Ff]oo", "(x)", "https?://", "a+b", "x{2,3}", "end$" }
    for _, pattern in ipairs(retried) do
      reset()
      search_reply = no_match
      bash_reply = { stdout = "", stderr = "", code = 1 }
      grep.handler({ pattern = pattern })
      test.assert.is_true(last_search ~= nil, "literal search runs first for: " .. pattern)
      test.assert.is_true(last_bash ~= nil, "expected a regex retry for: " .. pattern)
      test.assert.contains("-e '" .. pattern .. "'", last_bash.cmd)
    end
  end)

  test.it("never retries plain text", function()
    local literal = { "zzz", "foo.bar", "*.zig", "a*b", "foo bar", "src/main.zig", "a-b_c" }
    for _, pattern in ipairs(literal) do
      reset()
      search_reply = no_match
      local out = grep.handler({ pattern = pattern })
      test.assert.is_true(last_bash == nil, "unexpected regex retry for: " .. pattern)
      test.assert.contains("No matches found for: " .. pattern, out)
    end
  end)

  test.it("reports regex matches from the retry and says it switched", function()
    reset()
    search_reply = no_match
    bash_reply = { stdout = rg_line("src/a.zig", 10, "hello"), stderr = "", code = 0 }
    local out, extra = grep.handler({ pattern = "hello|world" })
    test.assert.equal(nil, extra)
    test.assert.contains("No literal substring matched: hello|world", out)
    test.assert.contains("showing regular-expression matches (ripgrep):", out)
    test.assert.contains("Found 1 matches:", out)
    test.assert.contains("Line 10: hello", out)
  end)

  test.it("says both searches were empty when the retry finds nothing too", function()
    reset()
    search_reply = no_match
    bash_reply = { stdout = "", stderr = "", code = 1 }
    local out = grep.handler({ pattern = "a|b" })
    test.assert.contains("No literal substring matched: a|b", out)
    test.assert.contains("showing regular-expression matches (ripgrep):\nNo matches found for: a|b", out)
  end)

  test.it("does not retry a literal search that found something", function()
    reset()
    search_reply = {
      query = "a|b", total_matches = 1, truncated = false,
      results = { { file = "src/a.zig", line = 1, content = "a|b" } },
    }
    local out = grep.handler({ pattern = "a|b" })
    test.assert.is_true(last_bash == nil, "a literal hit answers the question")
    test.assert.contains("Found 1 matches:", out)
    test.assert.is_false(out:find("regular-expression", 1, true) ~= nil)
  end)

  test.it("regex=false keeps the search literal even for regex syntax", function()
    reset()
    search_reply = no_match
    local out = grep.handler({ pattern = "a|b", regex = false })
    test.assert.is_true(last_bash == nil, "regex=false disables the retry")
    test.assert.contains("No matches found for: a|b", out)
  end)

  test.it("keeps the literal answer when the retry cannot run", function()
    -- ripgrep is not installed.
    reset()
    search_reply = no_match
    bash_reply = { stdout = "", stderr = "rg: command not found", code = 127 }
    local out = grep.handler({ pattern = "a|b" })
    test.assert.contains("No matches found for: a|b", out)
    test.assert.contains("regular-expression retry unavailable", out)
    test.assert.contains("needs ripgrep", out)

    -- The shell refused the line.
    reset()
    search_reply = no_match
    bash_err = "UnsafeShellBlocked: command rejected by Zay's shell safety classifier"
    local out_blocked = grep.handler({ pattern = "a|b" })
    test.assert.contains("No matches found for: a|b", out_blocked)
    test.assert.contains("regular-expression retry unavailable", out_blocked)
    test.assert.contains("UnsafeShellBlocked", out_blocked)
    test.assert.is_false(out_blocked:find("showing regular-expression matches", 1, true) ~= nil)

    -- The pattern is not a valid regex either.
    reset()
    search_reply = no_match
    bash_reply = { stdout = "", stderr = "regex parse error", code = 2 }
    local out_invalid = grep.handler({ pattern = "(" })
    test.assert.contains("No matches found for: (", out_invalid)
    test.assert.contains("invalid regex", out_invalid)
  end)

  test.it("reports a bridge failure of the literal search as before", function()
    reset()
    search_reply = nil
    local out, err = grep.handler({ pattern = "a|b" })
    test.assert.equal(nil, out)
    test.assert.contains("could not search", err)
    test.assert.is_true(last_bash == nil, "no retry behind a failed bridge call")
  end)
end)

-- ── #590: ripgrep output that overflows the plugin shell ────────────

test.describe("grep regex output bound", function()
  test.it("narrows an overflowing search to one line per file", function()
    reset()
    bash_sequence = {
      { result = nil, err = "StreamTooLong" },
      { result = { stdout = rg_line("src/a.zig", 1, "match") .. rg_line("src/b.zig", 7, "match"), stderr = "", code = 0 } },
    }
    local out, extra = grep.handler({ pattern = "needle", regex = true })
    test.assert.equal(nil, extra)
    test.assert.equal(2, #bash_cmds)
    test.assert.contains("-m '50'", bash_cmds[1])
    test.assert.contains("-m '1'", bash_cmds[2])
    test.assert.contains("Found 2 matches: (one line per file", out)
    test.assert.contains("Line 1: match", out)
    test.assert.contains("Line 7: match", out)
  end)

  test.it("reports a search too broad for one call with a way to narrow it", function()
    reset()
    bash_sequence = {
      { result = nil, err = "StreamTooLong" },
      { result = nil, err = "StreamTooLong" },
    }
    local out, err = grep.handler({ pattern = "needle", regex = true })
    test.assert.equal(nil, out)
    test.assert.contains("too much for one call", err)
    test.assert.contains("narrow", err)
    test.assert.equal(2, #bash_cmds)
  end)

  test.it("never narrows for any other shell failure", function()
    reset()
    bash_sequence = { { result = nil, err = "Timeout" } }
    local out, err = grep.handler({ pattern = "needle", regex = true })
    test.assert.equal(nil, out)
    test.assert.contains("Timeout", err)
    test.assert.equal(1, #bash_cmds)
  end)

  test.it("does not narrow a stream that fits", function()
    reset()
    bash_reply = { stdout = rg_line("src/a.zig", 1, "match"), stderr = "", code = 0 }
    local out = grep.handler({ pattern = "needle", regex = true })
    test.assert.equal(1, #bash_cmds)
    test.assert.is_false(out:find("one line per file", 1, true) ~= nil)
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
    local out, extra = grep.handler({ pattern = "hello", regex = true })
    test.assert.equal(nil, extra)
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
    local out, extra = grep.handler({ pattern = "hello" })
    test.assert.equal(nil, extra)
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

-- ── #590: glob hands the path to the bridge as given ────────────────

test.describe("glob path handling", function()
  local function find_rows(paths)
    return { result = { root = "", total_matches = #paths, results = paths, truncated = false } }
  end

  test.it("passes an exact file path straight to find_files", function()
    reset()
    file_info_types["src/skill.zig"] = "file"
    find_reply = find_rows({ { path = "src/skill.zig", name = "skill.zig" } })
    local out = glob.handler({ pattern = "*.zig", path = "src/skill.zig" })
    -- The bridge takes an exact file as its root; no parent walk, no
    -- file/dir guess from the path string.
    test.assert.equal("src/skill.zig", last_find.root)
    test.assert.equal("*.zig", last_find.pattern)
    test.assert.equal(0, file_info_calls)
    test.assert.contains("src/skill.zig", out)
    test.assert.contains("Found 1 files:", out)
  end)

  test.it("prints the bridge's rows without a second basename filter", function()
    reset()
    -- A nested same-named file used to leak through the parent walk and then
    -- survive the basename filter; what an exact root matches is the
    -- bridge's decision, and the plugin reports exactly that.
    find_reply = find_rows({ { path = "src/nested/target.zig" }, { path = "src/target.zig" } })
    local out = glob.handler({ pattern = "**/target.zig", path = "src" })
    test.assert.contains("src/nested/target.zig", out)
    test.assert.contains("src/target.zig", out)
    test.assert.equal("src", last_find.root)
  end)

  test.it("keeps directory-path `path` behavior unchanged (regression)", function()
    reset()
    find_reply = find_rows({ { path = "src/skill.zig" } })
    local out = glob.handler({ pattern = "*.zig", path = "src" })
    test.assert.contains("src/skill.zig", out)
    test.assert.equal("src", last_find.root)
  end)

  test.it("defaults the root to the active workspace", function()
    reset()
    glob.handler({ pattern = "*.zig" })
    test.assert.equal(".", last_find.root)
  end)

  test.it("clamps max_results and forwards it", function()
    reset()
    glob.handler({ pattern = "*.zig", max_results = 5000 })
    test.assert.equal(200, last_find.opts.max_results)
  end)

  test.it("reports a failed walk instead of an empty result", function()
    reset()
    find_reply = { result = { root = ".", total_matches = 0, results = {}, truncated = true, error = "AccessDenied" } }
    local out, err = glob.handler({ pattern = "*.zig" })
    test.assert.equal(nil, out)
    test.assert.contains("AccessDenied", err)
  end)

  test.it("reports no files for an empty walk", function()
    reset()
    local out = glob.handler({ pattern = "*.zig" })
    test.assert.contains("No files found matching: *.zig", out)
  end)
end)

-- ── #590: both backends print workspace-relative paths ──────────────

test.describe("workspace-relative paths", function()
  test.it("prints native matches under the workspace relative to it", function()
    reset()
    mock_cwd = "/home/me/proj"
    search_reply = {
      query = "x", total_matches = 2, truncated = false,
      results = {
        { file = "/home/me/proj/src/a.zig", line = 1, content = "x" },
        { file = "/home/me/other/b.zig", line = 2, content = "x" },
      },
    }
    local out = grep.handler({ pattern = "x" })
    test.assert.contains("src/a.zig:", out)
    test.assert.is_false(out:find("/home/me/proj", 1, true) ~= nil, "workspace prefix is dropped")
    test.assert.contains("/home/me/other/b.zig:", out)
  end)

  test.it("never strips a sibling directory that differs only by case", function()
    reset()
    mock_cwd = "/home/me/Proj"
    search_reply = {
      query = "x", total_matches = 1, truncated = false,
      results = { { file = "/home/me/proj/src/a.zig", line = 1, content = "x" } },
    }
    local out = grep.handler({ pattern = "x" })
    test.assert.contains("/home/me/proj/src/a.zig:", out)
  end)

  test.it("folds case for Windows paths", function()
    reset()
    mock_env.OS = "Windows_NT"
    mock_cwd = "C:\\Users\\me\\proj"
    search_reply = {
      query = "x", total_matches = 1, truncated = false,
      results = { { file = "c:/Users/me/proj/src/a.zig", line = 1, content = "x" } },
    }
    local out = grep.handler({ pattern = "x" })
    test.assert.contains("src/a.zig:", out)
    test.assert.is_false(out:find("Users", 1, true) ~= nil, "workspace prefix is dropped")
  end)

  test.it("strips ripgrep's ./ prefix", function()
    reset()
    bash_reply = { stdout = rg_line("./src/a.zig", 1, "hello"), stderr = "", code = 0 }
    local out = grep.handler({ pattern = "hello", regex = true })
    test.assert.contains("src/a.zig:", out)
    test.assert.is_false(out:find("./src", 1, true) ~= nil)
  end)

  test.it("prints glob paths relative to the workspace", function()
    reset()
    -- A trailing separator on the workspace path must not defeat the match.
    mock_cwd = "/home/me/proj/"
    find_reply = { result = { root = ".", total_matches = 2, truncated = false, results = {
      { path = "/home/me/proj/src/a.zig", name = "a.zig" },
      { path = "/opt/vendor/b.zig", name = "b.zig" },
    } } }
    local out = glob.handler({ pattern = "**/*.zig" })
    test.assert.contains("src/a.zig", out)
    test.assert.is_false(out:find("/home/me", 1, true) ~= nil, "workspace prefix is dropped")
    test.assert.contains("/opt/vendor/b.zig", out)
  end)
end)

-- ── #590: the manifest budgets what grep asks for ───────────────────

test.describe("manifest budgets", function()
  test.it("give the dispatch the time grep requests from the shell", function()
    local manifest_file = assert(io.open("plugins/packages/search-tools/plugin.lua", "r"))
    local manifest = assert(load(manifest_file:read("*a")))()
    manifest_file:close()
    local init_file = assert(io.open("plugins/packages/search-tools/init.lua", "r"))
    local requested = assert(init_file:read("*a"):match("timeout = (%d+)"))
    init_file:close()
    -- The sandbox deadline bounds every shell call; a larger request would
    -- be silently clamped to it.
    test.assert.is_true(manifest.permissions.timeout_ms >= tonumber(requested) * 1000,
      "timeout_ms " .. tostring(manifest.permissions.timeout_ms) .. "s < the " .. requested .. "s grep asks for")
    test.assert.is_true((manifest.permissions.instruction_limit or 0) >= 1000000)
    test.assert.is_true((manifest.permissions.memory_limit_mb or 0) >= 64)
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
    reset()
    bash_reply = {stdout=rg_line("C:/repo/src/a:b.zig", 7, "value: needle"), stderr="", code=0}
    local out = assert(grep.handler({pattern="needle", regex=true}))
    test.assert.contains("C:/repo/src/a:b.zig:", out)
    test.assert.contains("Line 7: value: needle", out)
  end)
  test.it("passes relative file paths once without changing cwd", function()
    reset()
    bash_reply = {stdout="", stderr="", code=1}
    grep.handler({pattern="needle", path="src/skill.zig", regex=true})
    test.assert.contains("-- 'src/skill.zig'", last_bash.cmd)
    test.assert.equal(nil, last_bash.opts.cwd)
  end)
  test.it("does not report empty stdout as success on a shell failure", function()
    reset()
    bash_reply = {stdout="", stderr="access denied", code=126}
    local out, err = grep.handler({pattern="needle", regex=true})
    test.assert.equal(nil, out)
    test.assert.contains("exit 126", err)
  end)
  test.it("bounds long Unicode match lines without splitting UTF-8", function()
    reset()
    bash_reply = {stdout=rg_line("src/ü.zig", 1, string.rep("a", 199) .. "ü tail"), stderr="", code=0}
    local out = assert(grep.handler({pattern="a", regex=true}))
    test.assert.contains("src/ü.zig:", out)
    test.assert.is_true(utf8.len(out) ~= nil)
    test.assert.contains(string.rep("a", 199) .. "…", out)
  end)
  test.it("reports malformed ripgrep output instead of no matches", function()
    reset()
    bash_reply = {stdout="{broken", stderr="", code=0}
    local out, err = grep.handler({pattern="needle", regex=true})
    test.assert.equal(nil, out)
    test.assert.contains("decode ripgrep", err)
  end)
  test.it("surfaces PowerShell's exit-1 mapping of ripgrep errors", function()
    reset()
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
    reset()
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

local function ripgrep_available()
  local availability = zay.run_shell("rg --version")
  return availability ~= nil and availability.code == 0
end

test.describe("grep real Zay bridge integration", function()
  test.it("searches only the requested file, including include intersection", function()
    with_fixture(function(root)
      local out = assert(grep.handler({pattern="needle", path=root .. "/src/target.zig"}))
      test.assert.contains("Found 1 matches:", out)
      test.assert.is_false(out:find("sibling", 1, true) ~= nil)
      test.assert.is_false(out:find("prefix", 1, true) ~= nil)
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
        test.assert.is_false(out:find("quoted", 1, true) ~= nil)
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
  test.it("prints native paths relative to the workspace, like ripgrep", function()
    with_fixture(function(root)
      local out = assert(grep.handler({pattern="needle", path=root .. "/src/nested/target.zig"}))
      test.assert.contains(root .. "/src/nested/target.zig:", out)
      local workspace = assert(zay.get_cwd())
      test.assert.is_false(out:find(workspace, 1, true) ~= nil, "no host-absolute prefix")
      local listed = assert(glob.handler({pattern="**/target.zig", path=root .. "/src"}))
      test.assert.contains(root .. "/src/target.zig", listed)
      test.assert.contains(root .. "/src/nested/target.zig", listed)
    end)
  end)
  test.it("retries a regex-syntax pattern that found nothing literal", function()
    with_fixture(function(root)
      if not ripgrep_available() then
        print("ripgrep unavailable: live regex checks skipped")
        return
      end
      local out = assert(grep.handler({pattern="needle|absent", path=root .. "/src/target.zig"}))
      test.assert.contains("No literal substring matched: needle|absent", out)
      test.assert.contains("showing regular-expression matches (ripgrep):", out)
      test.assert.contains("Line 1: needle", out)
    end)
  end)
  test.it("runs regex searches on relative directories and quoted file paths", function()
    with_fixture(function(root)
      if not ripgrep_available() then
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
  test.it("searches for text the shell safety matcher flags as code", function()
    with_fixture(function(root)
      if not ripgrep_available() then
        print("ripgrep unavailable: classifier checks skipped")
        return
      end
      -- The local matcher used to hard-block each of these lines: a bare
      -- `sudo`, the fork-bomb shape and a root wipe are plain search text.
      local out = assert(grep.handler({pattern="nee(dle)|sudo", path=root .. "/src/target.zig", regex=true}))
      test.assert.contains("Found 1 matches:", out)
      for _, pattern in ipairs({":\\(\\)", "rm -rf /", "brew"}) do
        local missed, err = grep.handler({pattern=pattern, path=root .. "/src/target.zig", regex=true})
        test.assert.is_true(missed ~= nil, "regex search for " .. pattern .. " was blocked: " .. tostring(err))
        test.assert.contains("No matches", missed)
      end
    end)
  end)
  test.it("narrows a regex search that overflows the plugin shell", function()
    with_fixture(function(root)
      if not ripgrep_available() then
        print("ripgrep unavailable: overflow check skipped")
        return
      end
      -- 400 files x 60 matching lines: far past the 512 KB a plugin shell
      -- call may return, even with the per-file bound.
      assert(zay.mkdir(root .. "/many"))
      for i = 1, 400 do
        assert(zay.write_file(root .. "/many/f" .. string.format("%03d", i) .. ".txt", string.rep("hit\n", 60)))
      end
      local out, err = grep.handler({pattern="hit", path=root .. "/many", regex=true})
      test.assert.is_true(out ~= nil, "broad search failed instead of narrowing: " .. tostring(err))
      test.assert.contains("one line per file", out)
      test.assert.contains("Found at least 51 matches (showing first 50", out)
      test.assert.contains("Line 1: hit", out)
      test.assert.is_false(out:find("Line 2:", 1, true) ~= nil, "one line per file")
    end)
  end)
end)

test.run()
