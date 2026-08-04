-- plugin.lua — File Watcher plugin manifest
return {
  name = "file-watcher",
  version = "1.0.0",
  author = "Nova",
  description = "Listens for file changes and notifies the agent",
  license = "MIT",
  -- require_others is advisory pending enforcement (T3); file_access is
  -- omitted because this plugin does no file I/O of its own.
  permissions = {
    require_others = false,
  },
}
