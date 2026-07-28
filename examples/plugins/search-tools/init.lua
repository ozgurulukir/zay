-- init.lua — Search Tools
-- Registers `grep` (content search) and `glob` (filename search). Both return
-- grouped, bounded output with truncation markers. `grep` falls back to
-- ripgrep via bash when regex is needed (Nova's search_files is substring-only).

-- Turn raw `rg --line-number` output into grouped format. Each rg line is
-- `path:line:content`; we split on the first two colons to avoid mangling
-- content that contains colons. Defined before the grep handler that uses it.
local function group_rg_output(raw, pattern)
  local by_file = {}
  local file_order = {}
  local total = 0
  for line in raw:gmatch("[^\n]+") do
    local first = line:find(":")
    if first then
      local second = line:find(":", first + 1)
      if second then
        local file = line:sub(1, first - 1)
        local lno = line:sub(first + 1, second - 1)
        local content = line:sub(second + 1)
        total = total + 1
        if not by_file[file] then
          by_file[file] = {}
          table.insert(file_order, file)
        end
        table.insert(by_file[file], { line = lno, content = content })
      end
    end
  end

  if total == 0 then
    return "No matches found for: " .. pattern
  end

  local out = {}
  table.insert(out, string.format("Found %d matches:", total))
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

-- ── grep ────────────────────────────────────────────────────────────

nova.register_tool({
  name = "grep",
  description = "Search file contents recursively. Returns matches grouped by file as `path:` headers with indented `Line N: <content>` entries. Supports an `include` glob filter (e.g. '*.zig'). For regex patterns, set regex=true to use ripgrep via bash. If you need to count matches within files, use bash with rg directly instead of this tool.",
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
      description = "Treat pattern as a regex (uses ripgrep; default false = substring)",
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
    local opts = {
      file_pattern = params.include,
      case_sensitive = params.case_sensitive or false,
      max_results = params.max_results or 50,
    }

    -- Regex path: shell out to ripgrep for real regex support.
    if params.regex then
      local cs_flag = params.case_sensitive and "" or " -i "
      local inc_flag = params.include and (" --glob '" .. params.include .. "'") or ""
      local cmd = string.format(
        "rg --line-number --no-heading%s %s -e %s %s 2>/dev/null || true",
        cs_flag, inc_flag, params.pattern, root
      )
      local bash_result = nova.run_bash(cmd, { cwd = root })
      if bash_result == nil then
        return "Error: regex search failed"
      end
      if bash_result.code ~= 0 and bash_result.stdout == "" then
        return "No matches found for: " .. params.pattern
      end
      local out = bash_result.stdout
      if out == "" then
        return "No matches found for: " .. params.pattern
      end
      -- Group raw rg output by file.
      return group_rg_output(out, params.pattern)
    end

    -- Substring path: Nova's native search_files.
    local result = nova.search_files(root, params.pattern, opts)
    if result == nil then
      return "Error: could not search " .. root
    end

    if result.total_matches == 0 then
      return "No matches found for: " .. params.pattern
    end

    -- Group results by file for readability.
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
