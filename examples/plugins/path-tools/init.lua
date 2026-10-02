-- init.lua — Path Tools
-- Registers create_directory / copy_path / move_path / delete_path. Every
-- operation goes through Zay's sandboxed path validator (sanitizePath), so
-- traversal outside the active workspace is rejected. Prefer these over shell
-- filesystem commands: the bridge owns path validation and cross-platform
-- behavior.

local function fail(message)
  return nil, "Error: " .. message
end

-- ── create_directory ────────────────────────────────────────────────

zay.register_tool({
  name = "create_directory",
  description = "Create a directory, including any necessary parent directories. The bridge confines it to the current active workspace.",
  parameters = {
    path = {
      type = "string",
      description = "Directory path to create (relative to the current active workspace or absolute)",
    },
  },
  handler = function(params)
    local ok, err = zay.mkdir(params.path)
    if ok then
      return "Created directory: " .. params.path
    end
    return fail("could not create directory " .. params.path .. ": " .. tostring(err or "unknown error"))
  end,
})

-- ── copy_path ───────────────────────────────────────────────────────

zay.register_tool({
  name = "copy_path",
  description = "Copy one file from source to destination inside the current active workspace. This plugin does not provide recursive directory copy.",
  parameters = {
    source_path = {
      type = "string",
      description = "Source file path (relative to the current active workspace or absolute)",
    },
    destination_path = {
      type = "string",
      description = "Destination file path (relative to the current active workspace or absolute)",
    },
  },
  handler = function(params)
    local ok, err = zay.copy_path(params.source_path, params.destination_path)
    if ok then
      return string.format("Copied %s to %s", params.source_path, params.destination_path)
    end
    return fail(string.format("could not copy %s to %s: %s", params.source_path, params.destination_path, tostring(err or "unknown error")))
  end,
})

-- ── move_path ───────────────────────────────────────────────────────

zay.register_tool({
  name = "move_path",
  description = "Move (rename) a file or directory inside the current active workspace. The bridge owns path validation.",
  parameters = {
    source_path = {
      type = "string",
      description = "Source path (relative to the current active workspace or absolute)",
    },
    destination_path = {
      type = "string",
      description = "Destination path (relative to the current active workspace or absolute)",
    },
  },
  handler = function(params)
    local ok, err = zay.move_path(params.source_path, params.destination_path)
    if ok then
      return string.format("Moved %s to %s", params.source_path, params.destination_path)
    end
    return fail(string.format("could not move %s to %s: %s", params.source_path, params.destination_path, tostring(err or "unknown error")))
  end,
})

-- ── delete_path ─────────────────────────────────────────────────────

zay.register_tool({
  name = "delete_path",
  description = "Delete a file or directory inside the current active workspace. Inspect the target first; pass recursive=true only when you intend to remove the whole tree. Deletion is irreversible.",
  parameters = {
    path = {
      type = "string",
      description = "Path to delete (relative to the current active workspace or absolute)",
    },
    recursive = {
      type = "boolean",
      description = "Remove a directory and all its contents recursively (default false)",
      optional = true,
    },
  },
  handler = function(params)
    local opts = {}
    if params.recursive ~= nil then opts.recursive = params.recursive end
    local ok, err = zay.delete_path(params.path, opts)
    if ok then
      local note = params.recursive and " (recursive)" or ""
      return "Deleted" .. note .. ": " .. params.path
    end
    return fail("could not delete " .. params.path .. ": " .. tostring(err or "unknown error"))
  end,
})
