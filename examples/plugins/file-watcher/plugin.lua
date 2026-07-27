-- plugin.lua — File Watcher plugin manifest
return {
  name = "file-watcher",
  version = "1.0.0",
  author = "Nova",
  description = "Listens for file changes and notifies the agent",
  license = "MIT",
  permissions = {
    file_access = true,
    require_others = false,
  },
}
