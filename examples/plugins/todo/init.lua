-- init.lua — Todo plugin
-- A todo.txt-format task tracker. The authoritative list lives in
-- `.nova/todos.txt` on disk (so it survives restarts and the user can edit it
-- in any editor); an in-Lua `_G.todos` cache avoids re-parsing every call.
--
-- Format (todo.txt standard):
--   (A) 2024-01-15 Call client +project @phone due:2024-01-20
--   ^priority ^creation          ^text      ^proj ^ctx  ^key:value
--   x 2024-01-18 2024-01-15 Done task +project
--   ^done ^completion ^creation
--
-- Tools: todo_write, todo_list, todo_add, todo_done, todo_delete, todo_prioritize

local TODOS_FILE = ".nova/todos.txt"

-- ── date helpers ────────────────────────────────────────────────────

-- Today's date as YYYY-MM-DD (uses os.date, which the sandbox allows).
local function today()
  return os.date("%Y-%m-%d")
end

-- Compare two YYYY-MM-DD date strings lexicographically (works because the
-- format is zero-padded and fixed-width).
local function date_le(a, b)
  return a <= b
end

-- ── todo.txt parser ─────────────────────────────────────────────────

-- Parse one todo.txt line into a structured record. Returns:
--   { done=bool, priority=?, created=?, completed=?, text=string,
--     projects={...}, contexts={...}, tags={key=value,...} }
-- Tolerates malformed lines (treats them as plain text with done=false).
local function parse_line(line)
  local t = {
    done = false,
    priority = nil,
    created = nil,
    completed = nil,
    text = "",
    projects = {},
    contexts = {},
    tags = {},
  }
  if line == nil or line == "" then return t end

  local rest = line

  -- Completion marker: a line starting with "x " (lowercase x, space).
  if rest:sub(1, 2) == "x " then
    t.done = true
    rest = rest:sub(3)
  end

  -- After optional completion, an optional completion date (YYYY-MM-DD).
  local m = rest:match("^(%d%d%d%d%-%d%d%-%d%d)%s+")
  if m then
    if t.done then
      t.completed = m
    else
      -- A bare date at the start of an open task is the creation date.
      t.created = m
    end
    rest = rest:sub(#m + 2)
  end

  -- Priority: (A) through (Z) at the very start.
  local pri = rest:match("^%(([A-Z])%)%s+")
  if pri then
    t.priority = pri
    rest = rest:sub(4) -- "(X) " is 4 chars
  end

  -- After optional priority, another optional date: for a completed task this
  -- is the creation date; for an open task it could be creation (if the first
  -- date was absent). todo.txt allows: "x <completed> <created> <pri?> text"
  -- and "(<pri>) <created> text".
  local m2 = rest:match("^(%d%d%d%d%-%d%d%-%d%d)%s+")
  if m2 then
    if t.created == nil then
      t.created = m2
    end
    rest = rest:sub(#m2 + 2)
  end

  -- The remainder is the task text. Extract projects, contexts, key:value.
  t.text = rest
  for proj in rest:gmatch("%+(%w+)") do
    table.insert(t.projects, proj)
  end
  for ctx in rest:gmatch("@(%w+)") do
    table.insert(t.contexts, ctx)
  end
  for key, val in rest:gmatch("(%w+):(%S+)") do
    -- Skip words that are part of URLs or that collide with +/@ tokens.
    if key ~= "http" and key ~= "https" then
      t.tags[key] = val
    end
  end

  return t
end

-- Render a parsed task record back to a todo.txt line.
local function render_line(t)
  local parts = {}
  if t.done then
    table.insert(parts, "x")
    if t.completed then table.insert(parts, t.completed) end
  end
  if t.priority then
    table.insert(parts, "(" .. t.priority .. ")")
  end
  if t.created then
    table.insert(parts, t.created)
  end
  table.insert(parts, t.text)
  return table.concat(parts, " ")
end

-- Render a task for human/model display with a checkbox and metadata.
local function render_task(t, index)
  local box = t.done and "[x]" or "[ ]"
  local pri = t.priority and (" (" .. t.priority .. ")") or ""
  local idx = string.format("%2d", index)
  local due = ""
  if t.tags["due"] then
    -- Flag overdue tasks.
    if not t.done and date_le(t.tags["due"], today()) then
      due = " [DUE:" .. t.tags["due"] .. "]"
    else
      due = " (due:" .. t.tags["due"] .. ")"
    end
  end
  local text = t.done and ("~~" .. t.text .. "~~") or t.text
  return string.format("%s %s%s %s%s", idx, box, pri, text, due)
end

-- ── file I/O ────────────────────────────────────────────────────────

-- Load todos from disk into _G.todos (a 1-indexed array of task records).
-- Returns true on success. Creates the file if missing.
local function load_todos()
  if _G.todos ~= nil then return true end
  _G.todos = {}

  local result = nova.read_file(TODOS_FILE, {})
  if result == nil then
    return true -- file doesn't exist yet; start with empty list
  end

  for line in result.content:gmatch("[^\r\n]+") do
    local t = parse_line(line)
    if t.text ~= "" or t.done then
      table.insert(_G.todos, t)
    end
  end
  return true
end

-- Persist _G.todos back to disk and return the rendered summary.
local function save_todos()
  local lines = {}
  for _, t in ipairs(_G.todos) do
    local line = render_line(t)
    if line ~= "" then table.insert(lines, line) end
  end
  nova.write_file(TODOS_FILE, table.concat(lines, "\n") .. "\n")
end

-- Render the full todo list as a summary string. Only open tasks are shown by
-- default; completed tasks are included if `include_done` is true.
local function summarize(include_done)
  load_todos()
  local open_count = 0
  local done_count = 0
  for _, t in ipairs(_G.todos) do
    if t.done then done_count = done_count + 1 else open_count = open_count + 1 end
  end

  local out = {}
  table.insert(out, string.format("Todo list (%d open, %d done):", open_count, done_count))
  table.insert(out, "")

  if #_G.todos == 0 then
    table.insert(out, "(no tasks yet — use todo_add to create one)")
    return table.concat(out, "\n")
  end

  -- Sort open tasks: priority first (A before Z, unpriority last), then by
  -- creation date, then by index for stability.
  local function sort_key(t, index)
    local pri = t.priority and t.priority:byte() or 91 -- '[' = after 'Z' (90)
    return string.format("%c_%s_%04d", pri, t.created or "0000-00-00", index)
  end

  local indexed = {}
  for i, t in ipairs(_G.todos) do
    table.insert(indexed, { task = t, idx = i, key = sort_key(t, i) })
  end
  table.sort(indexed, function(a, b) return a.key < b.key end)

  for _, entry in ipairs(indexed) do
    local t = entry.task
    if not t.done then
      table.insert(out, render_task(t, entry.idx))
    end
  end

  if include_done and done_count > 0 then
    table.insert(out, "")
    table.insert(out, "Completed:")
    for _, entry in ipairs(indexed) do
      if entry.task.done then
        table.insert(out, render_task(entry.task, entry.idx))
      end
    end
  end

  return table.concat(out, "\n")
end

-- ── tools ───────────────────────────────────────────────────────────

-- todo_list: show the current todo list.
nova.register_tool({
  name = "todo_list",
  description = "Show the current todo list. Returns open tasks sorted by priority (A first) then date, with overdue items flagged. Pass include_done=true to also show completed tasks. Use this to check progress before starting the next step.",
  parameters = {
    include_done = {
      type = "boolean",
      description = "Include completed tasks in the output (default false)",
      optional = true,
    },
  },
  handler = function(params)
    return summarize(params.include_done == true)
  end,
})

-- todo_add: add a new task.
nova.register_tool({
  name = "todo_add",
  description = "Add a new task to the todo list. The task text follows todo.txt format: use +Project for projects, @context for contexts, due:YYYY-MM-DD for due dates, and optionally set a priority (A=high through Z=low). The creation date is set automatically. Returns the updated list.",
  parameters = {
    text = {
      type = "string",
      description = "Task description in todo.txt format (e.g. 'Fix the bug +backend @urgent due:2024-02-01')",
    },
    priority = {
      type = "string",
      description = "Single letter priority A-Z (optional)",
      optional = true,
    },
  },
  handler = function(params)
    if not params.text or params.text == "" then
      return "Error: task text is required"
    end
    load_todos()
    local t = {
      done = false,
      priority = params.priority,
      created = today(),
      completed = nil,
      text = params.text,
      projects = {},
      contexts = {},
      tags = {},
    }
    -- Extract tags/projects/contexts from the text.
    for proj in params.text:gmatch("%+(%w+)") do table.insert(t.projects, proj) end
    for ctx in params.text:gmatch("@(%w+)") do table.insert(t.contexts, ctx) end
    for key, val in params.text:gmatch("(%w+):(%S+)") do
      if key ~= "http" and key ~= "https" then t.tags[key] = val end
    end
    table.insert(_G.todos, t)
    save_todos()
    return "Added task #" .. #_G.todos .. ": " .. render_line(t) .. "\n\n" .. summarize(false)
  end,
})

-- todo_done: mark a task complete.
nova.register_tool({
  name = "todo_done",
  description = "Mark a task as done (completed). Sets the completion date automatically. Only mark a task done AFTER the required work is actually done and verified — never based on intent. Returns the updated list.",
  parameters = {
    id = {
      type = "number",
      description = "Task number (from todo_list) to mark complete",
    },
  },
  handler = function(params)
    load_todos()
    if params.id == nil or params.id < 1 or params.id > #_G.todos then
      return "Error: invalid task id (use todo_list to see valid ids)"
    end
    local t = _G.todos[params.id]
    if t.done then
      return "Task #" .. params.id .. " is already done."
    end
    t.done = true
    t.completed = today()
    save_todos()
    return "Completed task #" .. params.id .. ": " .. t.text .. "\n\n" .. summarize(false)
  end,
})

-- todo_delete: remove a task permanently.
nova.register_tool({
  name = "todo_delete",
  description = "Delete a task permanently from the todo list. Use this for tasks that were added by mistake or are no longer relevant (not for completed work — use todo_done for that). Returns the updated list.",
  parameters = {
    id = {
      type = "number",
      description = "Task number (from todo_list) to delete",
    },
  },
  handler = function(params)
    load_todos()
    if params.id == nil or params.id < 1 or params.id > #_G.todos then
      return "Error: invalid task id (use todo_list to see valid ids)"
    end
    local removed = table.remove(_G.todos, params.id)
    save_todos()
    return "Deleted: " .. removed.text .. "\n\n" .. summarize(false)
  end,
})

-- todo_prioritize: set or change a task's priority.
nova.register_tool({
  name = "todo_prioritize",
  description = "Set or change a task's priority (A=high through Z=low). Pass priority as a single uppercase letter. Pass empty string or nil to remove priority. Returns the updated list.",
  parameters = {
    id = {
      type = "number",
      description = "Task number (from todo_list)",
    },
    priority = {
      type = "string",
      description = "Single letter A-Z, or empty to remove priority",
      optional = true,
    },
  },
  handler = function(params)
    load_todos()
    if params.id == nil or params.id < 1 or params.id > #_G.todos then
      return "Error: invalid task id (use todo_list to see valid ids)"
    end
    local t = _G.todos[params.id]
    local pri = params.priority
    if pri and #pri == 1 then
      pri = pri:upper()
      if pri:byte() >= 65 and pri:byte() <= 90 then
        t.priority = pri
      else
        return "Error: priority must be a letter A-Z"
      end
    elseif pri and #pri == 0 then
      t.priority = nil
    else
      return "Error: priority must be a single letter A-Z or empty"
    end
    save_todos()
    return "Set priority " .. (t.priority or "(none)") .. " on task #" .. params.id .. "\n\n" .. summarize(false)
  end,
})

-- todo_write: replace the entire list in one shot (for bulk reordering).
nova.register_tool({
  name = "todo_write",
  description = "Replace the ENTIRE todo list with the provided tasks. Each task is a todo.txt line. Use this when you need to reorder or rewrite the whole list; for single-task changes prefer todo_add/done/delete. Each line follows todo.txt format: '(A) text +project @context due:YYYY-MM-DD'. Returns the new list.",
  parameters = {
    tasks = {
      type = "string",
      description = "Newline-separated todo.txt lines (replaces the entire list)",
    },
  },
  handler = function(params)
    if not params.tasks then
      return "Error: tasks string is required"
    end
    _G.todos = {}
    for line in params.tasks:gmatch("[^\r\n]+") do
      local t = parse_line(line)
      if t.text ~= "" or t.done then
        table.insert(_G.todos, t)
      end
    end
    save_todos()
    return "Replaced todo list with " .. #_G.todos .. " tasks.\n\n" .. summarize(false)
  end,
})

-- ── event hook: remind on turn start ────────────────────────────────

-- On each turn start, load the todos and log a reminder if there are overdue
-- or high-priority open tasks. This is a passive log only (no tool output);
-- it keeps the todo list fresh in _G.todos and surfaces urgency. The model
-- will see any overdue items when it calls todo_list.
nova.on("turn_started", function(data)
  load_todos()
  local overdue = 0
  local high_pri = 0
  for _, t in ipairs(_G.todos) do
    if not t.done then
      if t.tags["due"] and date_le(t.tags["due"], today()) then
        overdue = overdue + 1
      end
      if t.priority == "A" then
        high_pri = high_pri + 1
      end
    end
  end
  -- No-op on success; the log is for diagnostics only. The model should call
  -- todo_list explicitly to see the full state.
  if overdue > 0 or high_pri > 0 then
    -- Intentionally silent: we refresh _G.todos here so the first todo_list
    -- call this turn is fast and reflects disk state.
  end
end)
