-- plugin.lua — Git Tools manifest
return {
  name = "git-tools",
  version = "1.0.0",
  author = "Nova",
  description = "Inspect git status, diff, log, branch, and create commits",
  license = "MIT",
  permissions = {
    -- require_others is advisory pending enforcement (T3).
    require_others = false,
  },
}
