-- plugin.lua — File Tools manifest
-- Unified file read/write/edit/list toolset mirroring the tool shapes models
-- already know from Claude Code / OpenCode / Zed agents.
return {
  name = "file-tools",
  version = "1.0.0",
  author = "Nova",
  description = "Read, write, edit, and list files safely",
  license = "MIT",
  permissions = {
    -- require_others is advisory pending enforcement (T3).
    require_others = false,
  },
}
