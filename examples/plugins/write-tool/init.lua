-- init.lua — Write Tool plugin
-- Registers `write` and `edit` tools using nova.write_file() and nova.edit_file().
-- Also uses nova.run_bash() for git-aware operations.

nova.register_tool({
  name = "write",
  description = "Write content to a file (atomic write, path traversal protected)",
  parameters = {
    path = {
      type = "string",
      description = "File path to write",
    },
    content = {
      type = "string",
      description = "Content to write",
    },
  },
  handler = function(params)
    local ok = nova.write_file(params.path, params.content)
    if ok then
      return string.format("Wrote %d bytes to %s", #params.content, params.path)
    else
      return "Error: could not write to " .. params.path
    end
  end,
})

nova.register_tool({
  name = "edit",
  description = "Replace first occurrence of a string in a file",
  parameters = {
    path = {
      type = "string",
      description = "File path to edit",
    },
    old_string = {
      type = "string",
      description = "Text to replace",
    },
    new_string = {
      type = "string",
      description = "Replacement text",
    },
  },
  handler = function(params)
    local ok = nova.edit_file(params.path, params.old_string, params.new_string)
    if ok then
      return "Edited " .. params.path
    else
      return "Error: could not edit " .. params.path
    end
  end,
})

-- Git-aware write: write + stage
nova.register_tool({
  name = "write_and_stage",
  description = "Write content to a file and stage it with git",
  parameters = {
    path = {
      type = "string",
      description = "File path to write",
    },
    content = {
      type = "string",
      description = "Content to write",
    },
  },
  handler = function(params)
    local ok = nova.write_file(params.path, params.content)
    if not ok then
      return "Error: could not write to " .. params.path
    end
    local result = nova.run_bash("git add " .. params.path, {})
    if result.code == 0 then
      return string.format("Wrote and staged %s", params.path)
    else
      return string.format("Wrote %s but git add failed: %s", params.path, result.stderr)
    end
  end,
})