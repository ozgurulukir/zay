-- plugin.lua — Custom Search plugin manifest
return {
  name = "custom-search",
  version = "1.0.0",
  author = "Nova",
  description = "A configurable search tool that searches files by pattern",
  license = "MIT",
  permissions = {
    file_access = true,
    require_others = false,
  },
}
