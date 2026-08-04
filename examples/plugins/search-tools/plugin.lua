-- plugin.lua — Search Tools manifest
return {
  name = "search-tools",
  version = "1.0.0",
  author = "Nova",
  description = "Grep file contents and glob for files by name",
  license = "MIT",
  permissions = {
    -- require_others is advisory pending enforcement (T3).
    require_others = false,
  },
}
