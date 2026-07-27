-- init.lua — Custom Search plugin initialization
-- Demonstrates a tool with configurable behavior.
-- Reads settings from plugin.get_config() and uses them at runtime.

-- Read plugin configuration (set in config.json's plugins section)
local config = plugin.get_config() or {}

-- Default settings
local settings = {
  max_results = config.max_results or 10,
  case_sensitive = config.case_sensitive or false,
  default_pattern = config.default_pattern or "*.lua",
}

-- Search history
local search_history = {}

-- Register the search tool
nova.register_tool({
  name = "search_files",
  description = "Searches for files matching a pattern with configurable options",
  parameters = {
    pattern = {
      type = "string",
      description = "File glob pattern to search for (e.g., '*.zig', '*.md')",
    },
    max_results = {
      type = "number",
      description = "Maximum number of results to return (default: from config)",
      optional = true,
    },
    case_sensitive = {
      type = "boolean",
      description = "Whether the search is case-sensitive (default: from config)",
      optional = true,
    },
  },
  handler = function(params)
    local pattern = params.pattern or settings.default_pattern
    local max = params.max_results or settings.max_results
    local cs = params.case_sensitive
    if cs == nil then cs = settings.case_sensitive end

    -- Record in search history
    table.insert(search_history, {
      pattern = pattern,
      max_results = max,
      timestamp = os.time(),
    })

    -- In a real plugin, this would use io.popen or a native binding
    -- to actually search the filesystem. For this example, we return
    -- a description of what would happen.
    local result = string.format(
      "Searching for '%s' (max: %d, case-sensitive: %s)",
      pattern, max, tostring(cs)
    )
    return result
  end,
})

-- Register a tool to view search history
nova.register_tool({
  name = "search_history",
  description = "Returns the search history for this session",
  parameters = {},
  handler = function()
    if #search_history == 0 then
      return "No searches performed yet"
    end
    local lines = {}
    for i, entry in ipairs(search_history) do
      table.insert(lines, string.format(
        "%d. '%s' (max: %d)",
        i, entry.pattern, entry.max_results
      ))
    end
    return table.concat(lines, "\n")
  end,
})
