-- init.lua — Todo plugin
-- A todo.txt-format task tracker. The authoritative task list lives in
-- `.nova/todos.txt` (todo.txt standard, editable in any text editor, survives
-- restarts). Detailed per-task plans live in a sidecar `.nova/todos/plans.json`,
-- keyed by a stable `id:N` tag, so `todo_list` can stay compact while plans are
-- loaded lazily via `todo_get_plan`.
--
-- todo.txt line format:
--   (A) 2024-01-15 Call client +project @phone due:2024-01-20 id:1
--   ^priority ^creation          ^text      ^proj ^ctx  ^due    ^stable-id
--   x 2024-01-18 2024-01-15 Done task +project
--   ^done ^completion ^creation
--
-- plans.json shape:
--   { "1": { "summary": str, "steps": [{text, done}], "notes": str } }
--
-- Tools: todo_list, todo_add, todo_done, todo_delete, todo_prioritize,
--        todo_write, todo_get_plan, todo_set_plan, todo_check_step

local TODOS_FILE = ".nova/todos.txt"
local PLANS_FILE = ".nova/todos/plans.json"
local PLANS_DIR = ".nova/todos"

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

-- ── id helpers ──────────────────────────────────────────────────────

-- Resolve a task's stable id from its id: tag, falling back to its array
-- index. The id: tag is the durable handle for plan lookups; the index is the
-- transient handle todo_list/todo_done/todo_delete use within one call.
local function task_id(t, index)
  if t.id then return tostring(t.id) end
  return tostring(index)
end

-- ── todo.txt parser ─────────────────────────────────────────────────

-- Parse one todo.txt line into a structured record. Returns:
--   { done=bool, priority=?, created=?, completed=?, text=string, id=?number,
--     projects={...}, contexts={...}, tags={key=value,...} }
-- Tolerates malformed lines (treats them as plain text with done=false).
local function parse_line(line)
  local t = {
    done = false,
    priority = nil,
    created = nil,
    completed = nil,
    text = "",
    id = nil,
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

  -- The id: tag is a stable numeric handle for plan lookups. Promote it to a
  -- top-level field so callers don't have to dig through tags.
  if t.tags["id"] then
    local n = tonumber(t.tags["id"])
    if n then t.id = n end
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

-- Render a task for human/model display with a checkbox and metadata. The
-- optional `plan_step_count` (or nil) adds a compact `[plan:N steps]` marker so
-- the model knows a plan exists without loading its (potentially long) body —
-- this is the context-hygiene boundary: plans never appear in todo_list output.
local function render_task(t, index, plan_step_count)
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
  local plan_marker = ""
  if plan_step_count and plan_step_count > 0 then
    plan_marker = string.format(" [plan:%d steps]", plan_step_count)
  end
  local text = t.done and ("~~" .. t.text .. "~~") or t.text
  return string.format("%s %s%s %s%s%s", idx, box, pri, text, due, plan_marker)
end

-- ── todo.txt file I/O ───────────────────────────────────────────────

-- Load todos from disk into _G.todos (a 1-indexed array of task records).
-- Reads fresh on every call rather than caching across turns: todo.txt is small
-- and a stale cache previously masked edits made in an external editor (the
-- cache was only cleared by todo_write). This keeps the in-Lua view always
-- consistent with disk.
local function load_todos()
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

-- Persist _G.todos back to disk.
local function save_todos()
  local lines = {}
  for _, t in ipairs(_G.todos) do
    local line = render_line(t)
    if line ~= "" then table.insert(lines, line) end
  end
  nova.write_file(TODOS_FILE, table.concat(lines, "\n") .. "\n")
end

-- ── plans.json file I/O ─────────────────────────────────────────────

-- Load the plan sidecar. Returns a table keyed by id-string. A missing or
-- corrupt file yields an empty table (plans are best-effort; we never let a
-- bad sidecar block the task list).
local function load_plans()
  local result = nova.read_file(PLANS_FILE, {})
  if result == nil then
    return {}
  end
  local decoded = nova.json_decode(result.content)
  if decoded == nil then
    -- Corrupt JSON: start fresh rather than failing the whole plugin.
    return {}
  end
  return decoded
end

-- Persist plans back to the sidecar with pretty indentation so a human can read
-- or hand-edit it in a text editor.
local function save_plans(plans)
  nova.mkdir(PLANS_DIR)
  local json = nova.json_encode(plans, { pretty = true })
  nova.write_file(PLANS_FILE, json)
end

-- Count the steps in a plan, defensively (missing steps table -> 0).
local function plan_step_count(plan)
  if plan and plan.steps and type(plan.steps) == "table" then
    return #plan.steps
  end
  return 0
end

-- ── summaries ───────────────────────────────────────────────────────

-- Render the full todo list as a summary string. Only open tasks are shown by
-- default; completed tasks are included if `include_done` is true. Each task
-- shows a compact plan marker (count only) so the list stays small; plan
-- bodies are fetched separately via todo_get_plan.
local function summarize(include_done)
  load_todos()
  local plans = load_plans()
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
      local steps = plan_step_count(plans[task_id(t, entry.idx)])
      table.insert(out, render_task(t, entry.idx, steps))
    end
  end

  if include_done and done_count > 0 then
    table.insert(out, "")
    table.insert(out, "Completed:")
    for _, entry in ipairs(indexed) do
      if entry.task.done then
        local steps = plan_step_count(plans[task_id(entry.task, entry.idx)])
        table.insert(out, render_task(entry.task, entry.idx, steps))
      end
    end
  end

  return table.concat(out, "\n")
end

-- ── tools: core list operations ─────────────────────────────────────

-- todo_list: show the current todo list.
nova.register_tool({
  name = "todo_list",
  description = "Show the current todo list. Returns open tasks sorted by priority (A first) then date, with overdue items flagged and a compact [plan:N steps] marker when a plan exists. Pass include_done=true to also show completed tasks. Plan bodies are NOT included here — call todo_get_plan for details. Use this to check progress before starting the next step.",
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
  description = "Add a new task to the todo list. The task text follows todo.txt format: use +Project for projects, @context for contexts, due:YYYY-MM-DD for due dates, and optionally set a priority (A=high through Z=low). A stable id:N tag is assigned automatically for plan lookups. The creation date is set automatically. Returns the updated list.",
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

    -- Assign the next stable id: scan existing id: tags for the max, then +1.
    -- This keeps ids monotonic and stable across delete/reorder (unlike array
    -- indices, which shift on table.remove).
    local max_id = 0
    for _, t in ipairs(_G.todos) do
      if t.id and t.id > max_id then max_id = t.id end
    end
    local new_id = max_id + 1

    -- Append id:N to the text so it round-trips through todo.txt on disk.
    -- Avoid a double id: if the caller already included one, replace it.
    local text = params.text
    if text:match("%sid:%d+") then
      text = text:gsub("%sid:%d+", " id:" .. new_id)
    else
      text = text .. " id:" .. new_id
    end

    local t = {
      done = false,
      priority = params.priority,
      created = today(),
      completed = nil,
      text = text,
      id = new_id,
      projects = {},
      contexts = {},
      tags = { id = tostring(new_id) },
    }
    -- Extract tags/projects/contexts from the text.
    for proj in text:gmatch("%+(%w+)") do table.insert(t.projects, proj) end
    for ctx in text:gmatch("@(%w+)") do table.insert(t.contexts, ctx) end
    for key, val in text:gmatch("(%w+):(%S+)") do
      if key ~= "http" and key ~= "https" then t.tags[key] = val end
    end
    table.insert(_G.todos, t)
    save_todos()
    return "Added task #" .. #_G.todos .. " (id:" .. new_id .. "): " .. render_line(t) .. "\n\n" .. summarize(false)
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
  description = "Replace the ENTIRE todo list with the provided tasks. Each task is a todo.txt line. Use this when you need to reorder or rewrite the whole list; for single-task changes prefer todo_add/done/delete. Each line follows todo.txt format: '(A) text +project @context due:YYYY-MM-DD'. Existing id:N tags are preserved; tasks without one are assigned fresh ids. Returns the new list.",
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
    -- Backfill missing ids so every task remains plan-addressable after a rewrite.
    local max_id = 0
    for _, t in ipairs(_G.todos) do
      if t.id and t.id > max_id then max_id = t.id end
    end
    for _, t in ipairs(_G.todos) do
      if t.id == nil then
        max_id = max_id + 1
        t.id = max_id
        t.tags["id"] = tostring(max_id)
        t.text = t.text .. " id:" .. max_id
      end
    end
    save_todos()
    return "Replaced todo list with " .. #_G.todos .. " tasks.\n\n" .. summarize(false)
  end,
})

-- ── tools: detailed plans (lazy-loaded sidecar) ─────────────────────

-- todo_get_plan: fetch the full plan for one task.
nova.register_tool({
  name = "todo_get_plan",
  description = "Get the detailed plan for a task (summary, checklist steps with done state, and notes). Call this BEFORE starting work on a task whose todo_list line showed [plan:N steps] — it shows how the work was decomposed. Returns 'No plan for task #N' if none exists; use todo_set_plan to create one.",
  parameters = {
    id = {
      type = "number",
      description = "Task number (from todo_list) whose plan to read",
    },
  },
  handler = function(params)
    load_todos()
    if params.id == nil or params.id < 1 or params.id > #_G.todos then
      return "Error: invalid task id (use todo_list to see valid ids)"
    end
    local t = _G.todos[params.id]
    local key = task_id(t, params.id)
    local plans = load_plans()
    local plan = plans[key]
    if not plan then
      return "No plan for task #" .. params.id .. " (id:" .. key .. "): " .. t.text
        .. "\nUse todo_set_plan to create one."
    end

    local out = {}
    table.insert(out, string.format("Plan for task #%d (id:%s): %s", params.id, key, t.text))
    table.insert(out, "")
    if plan.summary then
      table.insert(out, "Summary: " .. plan.summary)
      table.insert(out, "")
    end
    if plan.steps and #plan.steps > 0 then
      table.insert(out, "Steps:")
      local done_n = 0
      for i, s in ipairs(plan.steps) do
        local box = s.done and "[x]" or "[ ]"
        table.insert(out, string.format("  %s %d. %s", box, i, s.text or ""))
        if s.done then done_n = done_n + 1 end
      end
      table.insert(out, "")
      table.insert(out, string.format("(%d of %d steps done)", done_n, #plan.steps))
    else
      table.insert(out, "Steps: (none)")
    end
    if plan.notes and plan.notes ~= "" then
      table.insert(out, "")
      table.insert(out, "Notes: " .. plan.notes)
    end
    return table.concat(out, "\n")
  end,
})

-- todo_set_plan: create or replace a task's plan.
nova.register_tool({
  name = "todo_set_plan",
  description = "Create or replace a task's detailed plan before doing multi-step work. Write a one-line summary, break the work into checklist steps (newline-separated), and optionally add free-form notes. The plan is stored separately in plans.json so todo_list stays compact — plan bodies are fetched on demand via todo_get_plan. Returns the saved plan.",
  parameters = {
    id = {
      type = "number",
      description = "Task number (from todo_list) to plan",
    },
    summary = {
      type = "string",
      description = "One-line plan summary (what this task accomplishes)",
    },
    steps = {
      type = "string",
      description = "Checklist steps, one per line (newline-separated). Each becomes a [ ] item you can check off with todo_check_step.",
    },
    notes = {
      type = "string",
      description = "Free-form notes, gotchas, or context (optional)",
      optional = true,
    },
  },
  handler = function(params)
    load_todos()
    if params.id == nil or params.id < 1 or params.id > #_G.todos then
      return "Error: invalid task id (use todo_list to see valid ids)"
    end
    if not params.summary or params.summary == "" then
      return "Error: summary is required"
    end
    if not params.steps or params.steps == "" then
      return "Error: steps is required (use newline-separated checklist; pass a single line if just one step)"
    end

    local t = _G.todos[params.id]
    local key = task_id(t, params.id)

    -- Parse the steps string into {text, done=false} records. Blank lines are
    -- skipped so a trailing newline doesn't create an empty step.
    local step_list = {}
    for line in params.steps:gmatch("[^\r\n]+") do
      if line ~= "" then
        table.insert(step_list, { text = line, done = false })
      end
    end

    local plans = load_plans()
    plans[key] = {
      summary = params.summary,
      steps = step_list,
      notes = params.notes or "",
    }
    save_plans(plans)

    return string.format("Plan set for task #%d (id:%s): %s\n%d steps recorded.\n\nUse todo_get_plan to view it.",
      params.id, key, t.text, #step_list)
  end,
})

-- todo_check_step: toggle a step's completion in a plan.
nova.register_tool({
  name = "todo_check_step",
  description = "Toggle a step's completion (done <-> not done) in a task's plan checklist. Use this right after finishing a planned step to track granular progress. Returns the updated plan. Requires a plan to exist (create one with todo_set_plan first).",
  parameters = {
    id = {
      type = "number",
      description = "Task number (from todo_list)",
    },
    step = {
      type = "number",
      description = "Step number to toggle (1-indexed, as shown by todo_get_plan)",
    },
  },
  handler = function(params)
    load_todos()
    if params.id == nil or params.id < 1 or params.id > #_G.todos then
      return "Error: invalid task id (use todo_list to see valid ids)"
    end
    local t = _G.todos[params.id]
    local key = task_id(t, params.id)
    local plans = load_plans()
    local plan = plans[key]
    if not plan or not plan.steps or #plan.steps == 0 then
      return "Error: no plan steps for task #" .. params.id
        .. ". Use todo_set_plan to create one first."
    end
    if params.step == nil or params.step < 1 or params.step > #plan.steps then
      return string.format("Error: invalid step number (1-%d). Use todo_get_plan to see steps.", #plan.steps)
    end

    local s = plan.steps[params.step]
    s.done = not s.done
    save_plans(plans)

    local state = s.done and "done" or "open"
    return string.format("Step %d marked %s for task #%d.\n\n", params.step, state, params.id)
      .. "Use todo_get_plan to view the full plan."
  end,
})

-- ── event hook: keep cache fresh on turn start ──────────────────────

-- On each turn start, force a reload of the todo cache so the first todo_*
-- call this turn reflects any external edits to todos.txt. This stays silent:
-- it does not inject plan bodies or task text into the turn's context — the
-- model must call todo_list / todo_get_plan explicitly to see anything.
nova.on("turn_started", function(data)
  load_todos()
end)
