-- init.lua — Search Tools
-- Registers `grep` (content search) and `glob` (filename search). Both return
-- grouped, bounded output with truncation markers. `grep` has two backends:
-- substring search (the default) uses Nova's built-in search_files — self-
-- contained, no external binary; regex search (regex=true) shells out to
-- ripgrep, because search_files is substring-only and Lua patterns are not
-- PCRE (no alternation). Scope differs by backend: ripgrep honors .gitignore;
-- the native walker skips dotfiles but scans gitignored dirs (vendor/,
-- zig-cache/).

-- POSIX shell single-quote escaping: wrap in '...' and turn each embedded '
-- into '\''. The shell then passes the bytes through verbatim as ONE argument
-- — no pipe, space, glob, or backslash interpretation. This is the fix for
-- patterns like "mcp__|lua__": interpolated bare into a `bash -c` string, the
-- `|` was parsed as a shell pipe (rg's output went to a nonexistent command
-- and the search silently returned 0). Quoted, rg receives the real pattern.
local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Build the rg invocation as a single shell command string with every dynamic
-- value quoted (regex mode only). rg exit codes the handler relies on:
-- 0 = matches, 1 = no matches, 2 = error (e.g. bad regex); bash returns 127
-- when rg itself is missing.
local function build_rg_command(pattern, root, include, case_sensitive)
  local argv = { "rg", "--line-number", "--no-heading", "--color", "never" }
  if not case_sensitive then
    table.insert(argv, "-i")
  end
  if include and include ~= "" then
    table.insert(argv, "--glob")
    table.insert(argv, shell_quote(include))
  end
  table.insert(argv, "-e")
  table.insert(argv, shell_quote(pattern))
  table.insert(argv, shell_quote(root))
  return table.concat(argv, " ")
end

-- Turn raw `rg --line-number` output into grouped format. Each rg line is
-- `path:line:content`; split on the first two colons so content that itself
-- contains colons is not mangled. Counts every match but only keeps the first
-- `max_results`, so output stays bounded (the tool's contract) even when rg
-- returns thousands of hits.
local function group_rg_output(raw, pattern, max_results)
  local by_file = {}
  local file_order = {}
  local total = 0
  local shown = 0
  for line in raw:gmatch("[^\n]+") do
    local first = line:find(":")
    if first then
      local second = line:find(":", first + 1)
      if second then
        total = total + 1
        if shown < max_results then
          shown = shown + 1
          local file = line:sub(1, first - 1)
          local lno = line:sub(first + 1, second - 1)
          local content = line:sub(second + 1)
          if not by_file[file] then
            by_file[file] = {}
            table.insert(file_order, file)
          end
          table.insert(by_file[file], { line = lno, content = content })
        end
      end
    end
  end

  if total == 0 then
    return "No matches found for: " .. pattern
  end

  local out = {}
  if shown < total then
    table.insert(out, string.format("Found %d matches (showing first %d, more available):", total, shown))
  else
    table.insert(out, string.format("Found %d matches:", total))
  end
  table.insert(out, "")
  for _, file in ipairs(file_order) do
    table.insert(out, file .. ":")
    for _, m in ipairs(by_file[file]) do
      table.insert(out, string.format("  Line %s: %s", m.line, m.content))
    end
    table.insert(out, "")
  end
  return table.concat(out, "\n"):gsub("\n$", "")
end

-- Substring search via Nova's native walker — the primary substring path.
-- Self-contained (no external binary). Scope: skips dotfiles but NOT
-- gitignored dirs, so vendor/ and zig-cache/ are searched; for a
-- gitignore-aware search use regex=true (ripgrep) or bash with rg.
local function native_substring_search(params, root, case_sensitive, max_results)
  local result = nova.search_files(root, params.pattern, {
    file_pattern = params.include,
    case_sensitive = case_sensitive,
    max_results = max_results,
  })
  if result == nil then
    return "Error: could not search " .. root
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

nova.register_tool({
  name = "grep",
  description = "Search file contents recursively. Returns matches grouped by file as `path:` headers with indented `Line N: <content>` entries. By default does a literal substring search with Nova's built-in search (no external tools; skips dotfiles but scans gitignored dirs like vendor/). Set regex=true for full regular expressions (alternation `a|b`, `.*`, character classes) via ripgrep, which respects .gitignore and requires `rg` installed. Supports an `include` glob filter (e.g. '*.zig'). To count matches within files, use bash with rg directly instead of this tool.",
  parameters = {
    pattern = {
      type = "string",
      description = "Text pattern to search for",
    },
    path = {
      type = "string",
      description = "Root directory to search in (default: project root)",
      optional = true,
    },
    include = {
      type = "string",
      description = "File glob filter (e.g. '*.zig', '*.lua')",
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
      type = "number",
      description = "Maximum matches to return (default 50, max 200)",
      optional = true,
    },
  },
  handler = function(params)
    local root = params.path or "."
    local case_sensitive = params.case_sensitive or false
    local max_results = math.min(params.max_results or 50, 200)

    -- Substring (default): Nova's native search. Self-contained, no external
    -- binary, identical behavior in every environment.
    if not params.regex then
      return native_substring_search(params, root, case_sensitive, max_results)
    end

    -- Regex: ripgrep via bash (search_files is substring-only; Lua patterns
    -- are not PCRE). Quoting in build_rg_command keeps `|`, spaces, etc. from
    -- being parsed by the shell.
    local cmd = build_rg_command(params.pattern, root, params.include, case_sensitive)
    local bash_result = nova.run_bash(cmd, { cwd = root })

    if bash_result == nil then
      return "Error: regex search failed"
    end
    if bash_result.code == 127 then
      return "Error: regex search needs ripgrep (rg), which is not installed"
    end
    if bash_result.code == 2 then
      return "Error: invalid regex pattern: " .. (bash_result.stderr or "")
    end
    if bash_result.code == 1 or bash_result.stdout == "" then
      return "No matches found for: " .. params.pattern
    end
    return group_rg_output(bash_result.stdout, params.pattern, max_results)
  end,
})

-- ── glob ────────────────────────────────────────────────────────────

nova.register_tool({
  name = "glob",
  description = "Find files by name using a glob pattern (e.g. '**/*.zig', 'src/**/*.ts'). Returns matching file paths, one per line. Fast and works on any codebase size. When searching, you can call this tool multiple times in a single response with different patterns to find files efficiently.",
  parameters = {
    pattern = {
      type = "string",
      description = "Glob pattern (supports **, *, ? — e.g. '**/*.zig', 'src/**/*.ts')",
    },
    path = {
      type = "string",
      description = "Root directory to search in (default: project root)",
      optional = true,
    },
    max_results = {
      type = "number",
      description = "Maximum results (default 100)",
      optional = true,
    },
  },
  handler = function(params)
    local root = params.path or "."
    local opts = { max_results = params.max_results or 100 }

    local result = nova.find_files(root, params.pattern, opts)
    if result == nil then
      return "Error: glob failed for " .. params.pattern
    end

    if result.total_matches == 0 then
      return "No files found matching: " .. params.pattern
    end

    local lines = {}
    table.insert(lines, string.format("Found %d files:", result.total_matches))
    if result.truncated then
      table.insert(lines, "(results truncated — narrow your pattern or pass max_results)")
    end
    table.insert(lines, "")
    for _, f in ipairs(result.results or {}) do
      table.insert(lines, f.path)
    end
    return table.concat(lines, "\n")
  end,
})
