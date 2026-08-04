-- init.lua — File Watcher plugin initialization
-- Demonstrates event-driven plugin using the Nova event bus.
-- Counts file-related tool calls by kind (write/edit/delete/rename/copy).
--
-- The `tool_call_finished` payload carries only `name`/`call_id`/`success`
-- (no args, no paths), so event-driven tracking can only classify by the
-- tool name. Manual `track_file_op` records stay separate.

-- Per-kind counters derived from tool_call_finished events.
local event_counts = {
  write = 0,
  edit = 0,
  delete = 0,
  rename = 0,
  copy = 0,
}

-- Manual records added via track_file_op.
local file_ops = {}

-- Classify a fully-qualified tool name (`lua__<plugin>__<tool>`) into a
-- file-operation kind, or nil if it isn't a file operation we track.
local function classify(name)
  if name == "lua__file-tools__write" then return "write" end
  if name == "lua__file-tools__edit" then return "edit" end
  if name == "lua__path-tools__delete_path" then return "delete" end
  if name == "lua__path-tools__move_path" then return "rename" end
  if name == "lua__path-tools__copy_path" then return "copy" end
  return nil
end

-- Count successful file-operation tool calls by kind.
nova.on("tool_call_finished", function(data)
  if not data.success then return end
  local kind = classify(data.name)
  if kind then
    event_counts[kind] = event_counts[kind] + 1
  end
end)

-- Register a tool that reports file operation statistics
nova.register_tool({
  name = "file_stats",
  description = "Returns statistics about file operations in this session",
  parameters = {},
  handler = function()
    local parts = {}
    for _, kind in ipairs({ "write", "edit", "delete", "rename", "copy" }) do
      if event_counts[kind] > 0 then
        table.insert(parts, kind .. "=" .. event_counts[kind])
      end
    end
    local event_summary = #parts > 0 and table.concat(parts, ", ") or "none"
    local manual_count = #file_ops
    return string.format(
      "Event-tracked file operations: %s. Manually tracked: %d.",
      event_summary,
      manual_count
    )
  end,
})

-- Register a tool that records a file operation manually
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
