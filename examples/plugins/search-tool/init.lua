-- init.lua — Search Tool plugin
-- Registers a `search` tool using nova.search_files() for recursive grep.
-- Also uses nova.run_bash() for ripgrep fallback when available.

nova.register_tool({
  name = "search",
  description = "Search file contents recursively with pattern matching",
  parameters = {
    root = {
      type = "string",
      description = "Root directory to search",
    },
    pattern = {
      type = "string",
      description = "Text pattern to search for",
    },
    file_pattern = {
      type = "string",
      description = "File glob filter (e.g. '*.lua', optional)",
      optional = true,
    },
    case_sensitive = {
      type = "boolean",
      description = "Case-sensitive search (default: false, optional)",
      optional = true,
    },
    max_results = {
      type = "number",
      description = "Maximum results (default: 50, max: 200, optional)",
      optional = true,
    },
  },
  handler = function(params)
    local result = nova.search_files(params.root, params.pattern, {
      file_pattern = params.file_pattern,
      case_sensitive = params.case_sensitive,
      max_results = params.max_results,
    })
    if result == nil then
      return "Error: could not search " .. params.root
    end
    local lines = {}
    table.insert(lines, string.format("Query: %s", result.query))
    table.insert(lines, string.format("Total matches: %d", result.total_matches))
    if result.truncated then
      table.insert(lines, "(results truncated)")
    end
    table.insert(lines, "")
    for _, r in ipairs(result.results or {}) do
      table.insert(lines, string.format("%s:%d: %s", r.file, r.line, r.content))
    end
    return table.concat(lines, "\n")
  end,
})

-- Fast search using ripgrep via nova.run_bash()
nova.register_tool({
  name = "rg_search",
  description = "Fast search using ripgrep (falls back to grep if rg not available)",
  parameters = {
    pattern = {
      type = "string",
      description = "Pattern to search for",
    },
    path = {
      type = "string",
      description = "Directory to search in (default: project root)",
      optional = true,
    },
  },
  handler = function(params)
    local root = params.path or nova.get_project_root()
    local cmd = string.format("rg --line-number --no-heading %s %s 2>/dev/null || grep -rn %s %s",
      params.pattern, root, params.pattern, root)
    local result = nova.run_bash(cmd, { cwd = root })
    if result.code == 0 then
      return result.stdout
    else
      return "No matches or search failed: " .. result.stderr
    end
  end,
})