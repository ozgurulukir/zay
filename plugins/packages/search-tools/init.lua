-- init.lua — Search Tools
-- Registers `grep` (content search) and `glob` (filename search). Both return
-- grouped, bounded output with truncation markers.
--
-- `grep` has two backends. Literal search runs through Zay's built-in
-- search_files: self-contained, no external binary, and the default. Regex
-- search shells out to ripgrep, because search_files is substring-only and
-- Lua patterns are not PCRE (no alternation). The tool is named `grep`, so
-- models pass regex syntax without asking for it: when `regex` is left unset
-- and the pattern carries unambiguous regex syntax, a literal search that
-- finds nothing is retried as a regular expression. Quoting for the rg line
-- goes through `zay.shell_quote` with a dialect matched to the runner.
-- Scope differs by backend: ripgrep honors .gitignore; the native walker
-- skips dotfiles but scans gitignored dirs (vendor/, zig-cache/).

local function fail(message)
  return nil, "Error: " .. message
end

-- Regex syntax that is not ordinary text: alternation, escapes, groups,
-- classes, bounds, anchors, `?`, `+` and `.*`. A lone `.` or `*` is left
-- out on purpose: both are common in literal strings, and a regex retry
-- would then answer a question nobody asked.
local function looks_like_regex(pattern)
  -- `]` leads the class because a Lua pattern escapes with `%`, not `\`.
  return pattern:find("[][\\|(){}^$?+]") ~= nil or pattern:find(".*", 1, true) ~= nil
end

-- Paths are printed relative to the active workspace whenever they sit
-- inside it, so both backends report the same shape: ripgrep already prints
-- workspace-relative paths, the native walker returns absolute ones.
local function display_path(path)
  local shown = (path:gsub("\\", "/")):gsub("^%./", "")
  local cwd = zay.get_cwd()
  if not cwd or cwd == "" then return shown end
  local root = (cwd:gsub("\\", "/")):gsub("[/]+$", "")
  if root == "" then return shown end
  -- Windows paths are case-insensitive; POSIX ones are not, and folding
  -- there could hand back a sibling directory's file.
  local fold = function(p) return p end
  if zay.get_env("OS") == "Windows_NT" then
    fold = function(p) return p:lower() end
  end
  local prefix = fold(root) .. "/"
  if fold(shown):sub(1, #prefix) == prefix then
    return shown:sub(#root + 2)
  end
  return shown
end

-- Grouped listing shared by both backends: a summary line, then each file
-- as a `path:` header with indented `Line N: <content>` entries.
local function render(summary, by_file, file_order)
  if #file_order == 0 then return summary end
  local out = { summary, "" }
  for _, file in ipairs(file_order) do
    table.insert(out, file .. ":")
    for _, m in ipairs(by_file[file]) do
      table.insert(out, string.format("  Line %d: %s", m.line, m.content))
    end
    table.insert(out, "")
  end
  return (table.concat(out, "\n"):gsub("\n$", ""))
end

-- ── native (literal) backend ────────────────────────────────────────

-- Substring search via Zay's native walker — the primary substring path.
-- Self-contained (no external binary). Scope: skips dotfiles but NOT
-- gitignored dirs, so vendor/ and zig-cache/ are searched; for a
-- gitignore-aware search use regex=true (ripgrep) or bash with rg. File
-- roots are searched directly by the bridge, without a recursive walk.
-- Returns the bridge's result table, or nil + message.
local function native_search(params, root, case_sensitive, max_results)
  local result, err = zay.search_files(root, params.pattern, {
    file_pattern = params.include,
    case_sensitive = case_sensitive,
    max_results = max_results,
  })
  if result == nil then
    return fail("could not search " .. root .. ": " .. tostring(err or "unknown error"))
  end
  if result.error then
    return fail("could not search " .. root .. ": " .. tostring(result.error))
  end
  return result
end

local function render_native(result, pattern)
  if result.total_matches == 0 then return "No matches found for: " .. pattern end

  local by_file, file_order = {}, {}
  for _, m in ipairs(result.results or {}) do
    local file = display_path(m.file)
    if not by_file[file] then
      by_file[file] = {}
      table.insert(file_order, file)
    end
    table.insert(by_file[file], m)
  end

  local shown = #(result.results or {})
  local summary
  if result.truncated then
    summary = string.format("Found %d matches (showing first %d, more available):", result.total_matches, shown)
  else
    summary = string.format("Found %d matches:", result.total_matches)
  end
  return render(summary, by_file, file_order)
end

-- ── regex backend (ripgrep) ─────────────────────────────────────────

-- Build the rg invocation as a single shell command string with every dynamic
-- value quoted via the supplied `quote` function. rg exit codes the handler
-- relies on: 0 = matches, 1 = no matches, 2 = error (e.g. bad regex); shell
-- returns 127 when rg itself is missing.
local function build_rg_command(pattern, root, include, case_sensitive, max_count, quote)
  local argv = { "rg", "--json", "--color", "never" }
  if not case_sensitive then
    table.insert(argv, "-i")
  end
  if include and include ~= "" then
    table.insert(argv, "--glob")
    local quoted, err = quote(include)
    if quoted == nil then return nil, err end
    table.insert(argv, quoted)
  end
  -- Bound the stream at its source: at most `max_count` matching lines per
  -- file. `--max-columns` cannot do this — it has no effect under --json.
  table.insert(argv, "-m")
  local quoted_count, count_err = quote(tostring(max_count))
  if quoted_count == nil then return nil, count_err end
  table.insert(argv, quoted_count)
  table.insert(argv, "-e")
  local quoted_pattern, pattern_err = quote(pattern)
  if quoted_pattern == nil then return nil, pattern_err end
  table.insert(argv, quoted_pattern)
  table.insert(argv, "--")
  local quoted_root, root_err = quote(root)
  if quoted_root == nil then return nil, root_err end
  table.insert(argv, quoted_root)
  return table.concat(argv, " ")
end

-- Regex mode runs through a shell, so the target is validated through the
-- filesystem boundary first. The shell cwd remains the active workspace and
-- the target is passed as an argument: relative paths resolve once and
-- explicit files keep their identity.
-- Returns true to proceed, a finished result string, or nil + message.
local function regex_target_check(params, root)
  local info, path_err = zay.file_info(root)
  if not info then
    return fail("regex search failed (unreadable path): " .. tostring(path_err or root))
  end
  -- Ripgrep bypasses --glob for explicit files. Check the exact root with
  -- the bridge's glob matcher so include still intersects the file target.
  if info.type == "file" and params.include then
    local included, include_err = zay.find_files(root, params.include, {max_results=1})
    if not included or included.error then
      return fail("could not filter regex search path: " .. tostring(include_err or (included and included.error)))
    end
    if included.total_matches == 0 then
      return "No matches found for: " .. params.pattern
    end
  end
  return true
end

-- JSON keeps drive letters, colons and escaped newlines in paths unambiguous
-- on every shell. Stop decoding after one overflow match to bound Lua work.
-- `note` is appended to the summary line when the caller narrowed the search.
local function group_rg_output(raw, pattern, max_results, note)
  local by_file, file_order = {}, {}
  local shown, truncated = 0, false
  for line in raw:gmatch("[^\n]+") do
    local event, err = zay.json_decode(line)
    if not event then return fail("could not decode ripgrep output: " .. tostring(err)) end
    if event.type == "match" then
      if shown == max_results then
        truncated = true
        break
      end
      local data = event.data
      local file = data.path.text
      local content = data.lines.text
      if not file or not content then
        return fail("ripgrep returned non-UTF-8 paths or content; use literal search")
      end
      shown = shown + 1
      file = display_path(file)
      if not by_file[file] then
        by_file[file] = {}
        table.insert(file_order, file)
      end
      content = content:gsub("[\r\n]+$", "")
      if #content > 200 then
        local last = 200
        -- JSON text is UTF-8; do not cut through a multibyte character.
        while last > 0 and content:byte(last + 1) >= 128 and content:byte(last + 1) < 192 do
          last = last - 1
        end
        content = content:sub(1, last) .. "…"
      end
      table.insert(by_file[file], { line = data.line_number, content = content })
    end
  end
  if shown == 0 then return "No matches found for: " .. pattern end
  local summary
  if truncated then
    summary = string.format("Found at least %d matches (showing first %d, more available):", shown + 1, shown)
  else
    summary = string.format("Found %d matches:", shown)
  end
  return render(summary .. (note or ""), by_file, file_order)
end

-- Run one ripgrep search with at most `max_count` matching lines per file.
-- Returns the grouped output, or nil + message with a third value of true
-- when the failure is the plugin shell's output cap: ripgrep matched more
-- than one stream can carry, which a narrower `max_count` may still fit.
local function run_rg(params, root, case_sensitive, max_results, max_count, note)
  local target, target_err = regex_target_check(params, root)
  if target ~= true then return target, target_err end

  -- The quoting dialect must match the runner that interprets the line:
  -- "native" for run_shell (PowerShell '' rule on Windows), "posix" for a
  -- run_bash fallback (git-bash is POSIX even on Windows). On POSIX both
  -- dialects are identical.
  local shell_runner = zay.run_shell or zay.run_bash
  local dialect = (shell_runner == zay.run_shell) and "native" or "posix"
  local quote = function(s) return zay.shell_quote(s, dialect) end
  local cmd, quote_err = build_rg_command(params.pattern, root, params.include, case_sensitive, max_count, quote)
  if cmd == nil then
    return fail("could not quote regex search arguments: " .. tostring(quote_err or "unknown error"))
  end
  -- rg over large repos can exceed the 30 s default; the manifest gives the
  -- dispatch the 60 s this ask needs.
  local result, shell_err = shell_runner(cmd, { timeout = 60 })

  if result == nil then
    return nil, "Error: regex search failed: " .. tostring(shell_err or "unknown error"), shell_err == "StreamTooLong"
  end
  if result.code == 127 then
    return fail("regex search needs ripgrep (rg), which is not installed")
  end
  if result.code == 2 then
    return fail("regex search failed (invalid regex or unreadable path): " .. (result.stderr or ""))
  end
  if result.code == 1 then
    -- The PowerShell bridge maps unsuccessful native exits to 1. ripgrep
    -- emits diagnostics for errors, and leaves stderr empty for no matches.
    if result.stderr and result.stderr ~= "" then
      return fail("regex search failed (invalid regex or unreadable path): " .. result.stderr)
    end
    return "No matches found for: " .. params.pattern
  end
  if result.code ~= 0 then
    return fail("regex search failed (exit " .. tostring(result.code) .. "): " .. (result.stderr or "unknown error"))
  end
  return group_rg_output(result.stdout, params.pattern, max_results, note)
end

-- The plugin shell caps one command's output, and a broad pattern can
-- exceed it even with `max_results` matching lines per file. The retry keeps
-- one line per file; past that the search is too broad for a single call.
local function regex_search(params, root, case_sensitive, max_results)
  local text, err, overflowed = run_rg(params, root, case_sensitive, max_results, max_results)
  if text ~= nil then return text end
  if not overflowed then return nil, err end

  text, err, overflowed = run_rg(params, root, case_sensitive, max_results, 1,
    " (one line per file — narrow `path` or `include` to list every match)")
  if text ~= nil then return text end
  if overflowed then
    return fail("regex search matched too much for one call even at one line per file; narrow `path` or `include`")
  end
  return nil, err
end

-- ── grep ────────────────────────────────────────────────────────────

zay.register_tool({
  name = "grep",
  description = "Search file contents recursively. Returns matches grouped by file as `path:` headers with indented `Line N: <content>` entries. By default does a literal substring search with Zay's built-in search (no external tools; skips dotfiles but scans gitignored dirs like vendor/). Regex syntax (alternation `a|b`, `.*`, character classes, anchors) that finds nothing as literal text is retried automatically as a regular expression via ripgrep. Set regex=true to search as a regular expression directly (respects .gitignore, requires `rg`), or regex=false for literal-only. Supports an `include` glob filter (e.g. '*.zig'). To count matches within files, use bash with rg directly instead of this tool.",
  parameters = {
    pattern = {
      type = "string",
      description = "Text to search for. A literal substring by default; regex syntax such as `a|b`, `foo.*bar` or `^import` is retried as a regular expression when the literal search finds nothing",
    },
    path = {
      type = "string",
      description = "File or root directory to search in (default: active workspace)",
      optional = true,
    },
    include = {
      type = "string",
      description = "File glob filter (*, **, ?; e.g. '*.zig', 'src/**/*.lua')",
      optional = true,
    },
    regex = {
      type = "boolean",
      description = "Treat the pattern as a regular expression via ripgrep. Omit for a literal search with an automatic regex retry; false disables the retry",
      optional = true,
    },
    case_sensitive = {
      type = "boolean",
      description = "Case-sensitive search (default false)",
      optional = true,
    },
    max_results = {
      type = "integer",
      description = "Maximum matches to return (default 50, max 200)",
      optional = true,
    },
  },
  handler = function(params)
    local root = params.path or "."
    local case_sensitive = params.case_sensitive or false
    -- Clamp to a positive integer (defense in depth with the Zig-side clamp):
    -- a fractional/negative max_results would otherwise reach the bridge and
    -- (before the Zig clamp) panic on the u32 cast.
    local max_results = math.max(1, math.min(math.floor(params.max_results or 50), 200))

    if params.regex == true then
      local text, err = regex_search(params, root, case_sensitive, max_results)
      if text == nil then return nil, err end
      return text
    end

    -- Substring: Zay's native search. Self-contained, no external
    -- binary, identical behavior in every environment.
    local literal, literal_err = native_search(params, root, case_sensitive, max_results)
    if literal == nil then return nil, literal_err end
    if literal.total_matches > 0 or params.regex == false or not looks_like_regex(params.pattern) then
      return render_native(literal, params.pattern)
    end

    -- Nothing literal, and the pattern reads as a regular expression: the
    -- caller most likely asked a regex question of a tool named `grep`. The
    -- retry is a courtesy — when it cannot run, the literal answer stands
    -- and says so.
    local retried, retry_err = regex_search(params, root, case_sensitive, max_results)
    if retried == nil then
      return "No matches found for: " .. params.pattern
        .. " (searched as a literal substring; regular-expression retry unavailable: "
        .. tostring(retry_err or "unknown error") .. ")"
    end
    return "No literal substring matched: " .. params.pattern
      .. " — showing regular-expression matches (ripgrep):\n" .. retried
  end,
})

-- ── glob ────────────────────────────────────────────────────────────

zay.register_tool({
  name = "glob",
  description = "Find files by name using a glob pattern (e.g. '**/*.zig', 'src/**/*.ts'). Returns matching file paths, one per line. Skips dotfiles. Fast and works on any codebase size. When searching, you can call this tool multiple times in a single response with different patterns to find files efficiently.",
  parameters = {
    pattern = {
      type = "string",
      description = "Glob pattern (supports **, *, ? — e.g. '**/*.zig', 'src/**/*.ts')",
    },
    path = {
      type = "string",
      description = "Directory to search in, or one exact file (default: active workspace)",
      optional = true,
    },
    max_results = {
      type = "integer",
      description = "Maximum results (default 100, max 200)",
      optional = true,
    },
  },
  handler = function(params)
    local root = params.path or "."
    local max_results = math.max(1, math.min(math.floor(params.max_results or 100), 200))

    -- The path goes to the bridge as given: `zay.find_files` takes an exact
    -- file as its root and matches only that file, and walks a directory
    -- root recursively. Emulating a file with a walk of its parent leaks
    -- same-named files and can stop before reaching the target.
    local result, err = zay.find_files(root, params.pattern, { max_results = max_results })
    if result == nil then
      return fail("glob failed for " .. params.pattern .. ": " .. tostring(err or "unknown error"))
    end
    local matches = result.results or {}
    if result.error and #matches == 0 then
      return fail("glob failed for " .. params.pattern .. ": " .. tostring(result.error))
    end

    if #matches == 0 then
      return "No files found matching: " .. params.pattern
    end

    local lines = {}
    table.insert(lines, string.format("Found %d files:", #matches))
    if result.truncated then
      table.insert(lines, "(results truncated — narrow your pattern or pass max_results)")
    end
    table.insert(lines, "")
    for _, f in ipairs(matches) do
      table.insert(lines, display_path(f.path))
    end
    return table.concat(lines, "\n")
  end,
})
