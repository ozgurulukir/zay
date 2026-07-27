-- init.lua — Hello World plugin initialization
-- This is the entry point loaded by Nova when the plugin starts.
-- It registers a simple greeting tool.

-- Register a tool that returns a greeting
nova.register_tool({
  name = "greet",
  description = "Returns a friendly greeting",
  parameters = {
    name = {
      type = "string",
      description = "The name to greet",
    },
  },
  handler = function(params)
    local person = params.name or "World"
    return "Hello, " .. person .. "!"
  end,
})

-- Register a tool that returns the current time
nova.register_tool({
  name = "current_time",
  description = "Returns the current time",
  parameters = {},
  handler = function()
    return "The current time is: " .. os.date("%H:%M:%S")
  end,
})
