-- plugin.lua — Hello World plugin manifest
return {
  name = "hello-world",
  version = "1.0.0",
  author = "Nova",
  description = "A minimal example plugin that registers a greeting tool",
  license = "MIT",
  permissions = {
    require_others = false,
  },
}
