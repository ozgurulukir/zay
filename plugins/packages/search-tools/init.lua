-- init.lua — Search Tools
-- Registers `grep` (content search) and `glob` (filename search). Both return
-- grouped, bounded output with truncation markers. `grep` has two backends:
-- substring search (the default) uses Zay's built-in search_files — self-
-- contained, no external binary; regex search (regex=true) shells out to
-- ripgrep, because search_files is substring-only and Lua patterns are not
-- PCRE (no alternation). Quoting for the rg line goes through
-- `zay.shell_quote` with a dialect matched to the runner (see the grep
-- handler). Scope differs by backend: ripgrep honors .gitignore; the native
-- walker skips dotfiles but scans gitignored dirs (vendor/, zig-cache/).

-- Build the rg invocation as a single shell command string with every dynamic
-- value quoted via the supplied `quote` function (regex mode only). rg exit
-- codes the handler relies on: 0 = matches, 1 = no matches, 2 = error (e.g.
-- bad regex); shell returns 127 when rg itself is missing.
local function fail(message)
  return nil, "Error: " .. message
end

local function build_rg_command(pattern, root, include, case_sensitive, quote)
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

-- JSON keeps drive letters, colons and escaped newlines in paths unambiguous
-- on every shell. Stop decoding after one overflow match to bound Lua work.
local function group_rg_output(raw, pattern, max_results)
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
  local out = {}
  if truncated then
    table.insert(out, string.format("Found at least %d matches (showing first %d, more available):", shown + 1, shown))
  else
    table.insert(out, string.format("Found %d matches:", shown))
  end
  table.insert(out, "")
  for _, file in ipairs(file_order) do
    table.insert(out, file .. ":")
    for _, m in ipairs(by_file[file]) do
      table.insert(out, string.format("  Line %d: %s", m.line, m.content))
    end
    table.insert(out, "")
  end
  return table.concat(out, "\n"):gsub("\n$", "")
end

-- Local, separator-agnostic path splitters. The plugin sandbox does not
-- expose `std`, and these only ever run AFTER `zay.file_info` has confirmed
-- the path is a file — so the file/dir decision stays on the Zig side
-- (cross-platform). Splitting on either '/' or '\' mirrors Zay's own
-- separator-agnostic path handling and is safe on Windows and POSIX alike.
local function dirname_of(p)
  local last = 0
  for i = 1, #p do
    local c = p:sub(i, i)
    if c == "/" or c == "\\" then last = i end
  end
  if last == 0 then return "." end
  return p:sub(1, last - 1)
end

local function basename_of(p)
  local last = 0
  for i = 1, #p do
    local c = p:sub(i, i)
    if c == "/" or c == "\\" then last = i end
  end
  return p:sub(last + 1)
end

-- Resolve a user-supplied `path` into a (root_dir, restriction) pair.
-- Cross-platform file/dir discrimination is delegated to `zay.file_info`
-- (Zig: sanitizePath + stat.kind — identical on Windows and Linux). We never
-- guess file-vs-directory from the path string, which would diverge across
-- platforms (no realpath on Windows, different separators).
-- Returns:
--   dir, nil            when path is a directory (or discrimination failed)
--   dir, basename       when path is a single file: search its parent dir and
--                       restrict results to that one file by name.
local function resolve_search_root(path)
  local root = path or "."
  local ok, info = pcall(function() return zay.file_info(root) end)
  if ok and info and info.type == "file" then
    return dirname_of(root), basename_of(root)
  end
  return root, nil
end

-- Substring search via Zay's native walker — the primary substring path.
-- Self-contained (no external binary). Scope: skips dotfiles but NOT
-- gitignored dirs, so vendor/ and zig-cache/ are searched; for a
-- gitignore-aware search use regex=true (ripgrep) or bash with rg.
-- File roots are searched directly by the bridge, without a recursive walk.
local function native_substring_search(params, root, case_sensitive, max_results)
  local file_pattern = params.include
  local result, err = zay.search_files(root, params.pattern, {
    file_pattern = file_pattern,
    case_sensitive = case_sensitive,
    max_results = max_results,
  })
  if result == nil then
    return fail("could not search " .. root .. ": " .. tostring(err or "unknown error"))
  end
  if result.error then
    return fail("could not search " .. root .. ": " .. tostring(result.error))
  end
  if result.total_matches == 0 then
    return "No matches found for: " .. params.pattern
  end

  local by_file = {}
  local file_order = {}
  for _, m in ipairs(result.results or {}) do
    if not by_file[m.file] then
      by_file[m.file] = {}
      table.insert(file_order, m.file)
    end
    table.insert(by_file[m.file], m)
  end

  local out = {}
  local shown = #(result.results or {})
  if result.truncated then
    table.insert(out, string.format("Found %d matches (showing first %d, more available):", result.total_matches, shown))
  else
    table.insert(out, string.format("Found %d matches:", result.total_matches))
  end
  table.insert(out, "")
  for _, file in ipairs(file_order) do
    table.insert(out, file .. ":")
    for _, m in ipairs(by_file[file]) do
      table.insert(out, string.format("  Line %d: %s", m.line, m.content))
    end
    table.insert(out, "")
  end
  return table.concat(out, "\n"):gsub("\n$", "")
end

-- ── grep ────────────────────────────────────────────────────────────

zay.register_tool({
  name = "grep",
  description = "Search file contents recursively. Returns matches grouped by file as `path:` headers with indented `Line N: <content>` entries. By default does a literal substring search with Zay's built-in search (no external tools; skips dotfiles but scans gitignored dirs like vendor/). Set regex=true for full regular expressions (alternation `a|b`, `.*`, character classes) via ripgrep, which respects .gitignore and requires `rg` installed. Supports an `include` glob filter (e.g. '*.zig'). To count matches within files, use bash with rg directly instead of this tool.",
  parameters = {
    pattern = {
      type = "string",
      description = "Text pattern to search for",
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
      description = "Treat pattern as a regex via ripgrep (default false = literal substring via built-in search)",
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

    -- Substring (default): Zay's native search. Self-contained, no external
    -- binary, identical behavior in every environment.
    if not params.regex then
      return native_substring_search(params, root, case_sensitive, max_results)
    end

    -- Regex: ripgrep via shell (search_files is substring-only; Lua patterns
    -- are not PCRE). Quoting in build_rg_command keeps `|`, spaces, etc. from
    -- being parsed by the shell. The dialect must match the runner that will
    -- interpret the line: "native" for run_shell (PowerShell '' rule on
    -- Windows), "posix" for a run_bash fallback (git-bash is POSIX even on
    -- Windows). On POSIX both dialects are identical.
    -- Validate the target through the filesystem boundary before passing it to
    -- a shell. The shell cwd remains the active workspace, so relative paths
    -- are resolved once and explicit files retain their identity.
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
    local shell_runner = zay.run_shell or zay.run_bash
    local dialect = (shell_runner == zay.run_shell) and "native" or "posix"
    local quote = function(s) return zay.shell_quote(s, dialect) end
    local cmd, quote_err = build_rg_command(params.pattern, root, params.include, case_sensitive, quote)
    if cmd == nil then
      return fail("could not quote regex search arguments: " .. tostring(quote_err or "unknown error"))
    end
    -- rg over large repos can exceed the 30 s default; give it a 60 s budget.
    local bash_result, shell_err = shell_runner(cmd, { timeout = 60 })

    if bash_result == nil then
      return fail("regex search failed: " .. tostring(shell_err or "unknown error"))
    end
    if bash_result.code == 127 then
      return fail("regex search needs ripgrep (rg), which is not installed")
    end
    if bash_result.code == 2 then
      return fail("regex search failed (invalid regex or unreadable path): " .. (bash_result.stderr or ""))
    end
    if bash_result.code == 1 then
      -- The PowerShell bridge maps unsuccessful native exits to 1. ripgrep
      -- emits diagnostics for errors, and leaves stderr empty for no matches.
      if bash_result.stderr and bash_result.stderr ~= "" then
        return fail("regex search failed (invalid regex or unreadable path): " .. bash_result.stderr)
      end
      return "No matches found for: " .. params.pattern
    end
    if bash_result.code ~= 0 then
      return fail("regex search failed (exit " .. tostring(bash_result.code) .. "): " .. (bash_result.stderr or "unknown error"))
    end
    return group_rg_output(bash_result.stdout, params.pattern, max_results)
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
      description = "Root directory to search in (default: active workspace)",
      optional = true,
    },
    max_results = {
      type = "integer",
      description = "Maximum results (default 100)",
      optional = true,
    },
  },
  handler = function(params)
    local root, file_restriction = resolve_search_root(params.path)
    local max_results = math.max(1, math.min(math.floor(params.max_results or 100), 200))
    local opts = { max_results = max_results }

    local result, err = zay.find_files(root, params.pattern, opts)
    if result == nil then
      return fail("glob failed for " .. params.pattern .. ": " .. tostring(err or "unknown error"))
    end

    -- When `path` pointed at a single file, keep only that file (the walk
    -- happened in its parent dir). Restriction is by basename, so it works
    -- regardless of the user's glob pattern.
    local matches = result.results or {}
    if file_restriction and file_restriction ~= "" then
      local filtered = {}
      for _, f in ipairs(matches) do
        if basename_of(f.path) == file_restriction then
          table.insert(filtered, f)
        end
      end
      matches = filtered
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
      table.insert(lines, f.path)
    end
    return table.concat(lines, "\n")
  end,
})
