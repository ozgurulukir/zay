-- init.lua — Read Tool plugin
-- Registers a `read` tool that uses nova.read_file() for safe file access.
-- Also uses nova.get_cwd() and nova.get_project_root() for path resolution.

nova.register_tool({
  name = "read",
  description = "Read file contents with optional line range and language detection",
  parameters = {
    path = {
      type = "string",
      description = "File path to read (relative to project root or absolute)",
    },
    start_line = {
      type = "number",
      description = "Starting line number (1-indexed, optional)",
      optional = true,
    },
    end_line = {
      type = "number",
      description = "Ending line number (optional)",
      optional = true,
    },
  },
  handler = function(params)
    local result = nova.read_file(params.path, {
      start_line = params.start_line,
      end_line = params.end_line,
    })
    if result == nil then
      return "Error: could not read " .. params.path
    end
    local summary = string.format(
      "File: %s\nSize: %d bytes\nLines: %d\nLanguage: %s\n\n%s",
      result.path, result.size, result.lines, result.language, result.content
    )
    return summary
  end,
})

-- Also register a git_status tool using nova.git_status()
nova.register_tool({
  name = "git_status",
  description = "Get git status (porcelain format) for the current repository",
  parameters = {},
  handler = function()
    local status = nova.git_status()
    if status == nil then
      return "Error: could not get git status"
    end
    local branch = nova.git_branch()
    return string.format("Branch: %s\n\n%s", branch or "unknown", status)
  end,
})