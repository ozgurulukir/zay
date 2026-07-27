-- init.lua — File Watcher plugin initialization
-- Demonstrates event-driven plugin using the Nova event bus.
-- Listens for tool calls and tracks file-related operations.

-- Track file operations across the session
local file_ops = {}

-- Subscribe to tool call events
nova.on("tool_call_started", function(data)
  if data.name == "bash" then
    -- We'll check the result when it finishes
  end
end)

nova.on("tool_call_finished", function(data)
  if data.name == "bash" and data.success then
    -- A bash command completed successfully
    -- In a real plugin, you might parse the output for file changes
  end
end)

-- Register a tool that reports file operation statistics
nova.register_tool({
  name = "file_stats",
  description = "Returns statistics about file operations in this session",
  parameters = {},
  handler = function()
    local count = #file_ops
    return "File operations tracked this session: " .. count
  end,
})

-- Register a tool that records a file operation
nova.register_tool({
  name = "track_file_op",
  description = "Records a file operation for tracking",
  parameters = {
    operation = {
      type = "string",
      description = "The operation type (read, write, delete, rename)",
    },
    path = {
      type = "string",
      description = "The file path",
    },
  },
  handler = function(params)
    table.insert(file_ops, {
      operation = params.operation,
      path = params.path,
      timestamp = os.time(),
    })
    return "Tracked " .. params.operation .. " on " .. params.path
  end,
})
