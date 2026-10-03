-- init.lua — Todo plugin
-- A todo.txt-format task tracker. The authoritative task list lives in
-- `.zay/todos.txt` (todo.txt standard, editable in any text editor, survives
-- restarts). Detailed per-task plans live in a sidecar `.zay/todos/plans.json`,
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

local TODOS_FILE = ".zay/todos.txt"
local PLANS_FILE = ".zay/todos/plans.json"
local PLANS_DIR = ".zay/todos"
local META_FILE = ".zay/todos/metadata.json"

local function fail(message)
  return nil, "Error: " .. message
end

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

-- Validate a numeric index: a number that is an integer in [1, n]. Rejects
-- fractional/zero/negative values (which would otherwise index _G.todos[2.5]
-- -> nil -> .done raises a Lua tool error) and non-numbers.
local function is_index(v, n)
  return type(v) == "number" and v >= 1 and v <= n and math.floor(v) == v
end

-- Resolve a task's stable id from its id: tag, falling back to its array
-- index. The id: tag is the durable handle for plan lookups; the index is the
-- transient handle todo_list/todo_done/todo_delete use within one call.
local function task_id(t, index)
  if t.id then return tostring(t.id) end
  return tostring(index)
end

local function clone_task(task)
  local copy = {}
  for key, value in pairs(task) do copy[key] = value end
  return copy
end

local function clone_tasks(tasks)
  local copy = {}
  for i, task in ipairs(tasks) do copy[i] = clone_task(task) end
  return copy
end

local function is_missing_error(err)
  if err == nil then return true end
  local message = tostring(err):lower()
  return message:find("notfound", 1, true) ~= nil
    or message:find("no such file", 1, true) ~= nil
    or message:find("enoent", 1, true) ~= nil
end

-- ── todo.txt parser ─────────────────────────────────────────────────

-- Match an anchored YYYY-MM-DD date at the start of `s`. The date must be
-- followed by a run of spaces OR end the line entirely; a date glued to text
-- ("2026-08-01urgent") is rejected. Returns the date and the remainder of the
-- string after the date+spaces, or nil (and the unchanged string) when there
-- is no valid date. Centralizing this keeps both date sites in parse_line
-- (completion/creation before the priority, creation after it) identical.
local function take_date(s)
  local date, spaces = s:match("^(%d%d%d%d%-%d%d%-%d%d)(%s*)")
  if not date then return nil, s end
  if spaces == "" and #s > #date then return nil, s end -- glued to text
  return date, s:sub(#date + #spaces + 1)
end

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
  -- take_date cuts by the real match length, so a multi-space separator can't
  -- leave a leading space that breaks the anchored date match below (the old
  -- `sub(#m + 2)` assumed exactly one space), and a date at end-of-line (a
  -- completed task with no text) still parses as the completion date.
  local date
  date, rest = take_date(rest)
  if date then
    if t.done then
      t.completed = date
    else
      -- A bare date at the start of an open task is the creation date.
      t.created = date
    end
  end

  -- Priority: (A) through (Z) at the very start. Capture the WHOLE match
  -- (marker + run of spaces) and cut by its length.
  local pri = rest:match("^(%(([A-Z])%)%s+)")
  if pri then
    t.priority = pri:match("%(([A-Z])%)")
    rest = rest:sub(#pri + 1)
  end

  -- After optional priority, another optional date: for a completed task this
  -- is the creation date; for an open task it could be creation (if the first
  -- date was absent). todo.txt allows: "x <completed> <created> <pri?> text"
  -- and "(<pri>) <created> text". Same acceptance rules as the first date
  -- site (take_date): end-of-line OK, glued-to-text rejected.
  local date2
  date2, rest = take_date(rest)
  if date2 then
    if t.created == nil then
      t.created = date2
    end
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

-- Load todos from disk into a 1-indexed array of task records.
-- Reads fresh on every call rather than caching across turns: todo.txt is small
-- and a stale cache previously masked edits made in an external editor (the
-- cache was only cleared by todo_write). This keeps the in-Lua view always
-- consistent with disk.
local function set_task_id(task, id)
  task.id = id
  task.tags["id"] = tostring(id)
  task.text = task.text:gsub("%s*id:%d+%s*$", "") .. " id:" .. id
end

local function parse_tasks(content)
  local tasks = {}
  local ids = {}
  local max_id = 0
  for line in content:gmatch("[^\r\n]+") do
    local t = parse_line(line)
    if t.text ~= "" or t.done then
      if t.tags.id ~= nil and t.id == nil then
        return nil, "invalid numeric id tag in todo.txt"
      end
      if t.id ~= nil then
        if t.id < 1 or math.floor(t.id) ~= t.id then
          return nil, "invalid numeric id in todo.txt"
        end
        if ids[t.id] then
          return nil, "duplicate task id:" .. t.id .. " in todo.txt"
        end
        ids[t.id] = true
        if t.id > max_id then max_id = t.id end
      end
      table.insert(tasks, t)
    end
  end
  return tasks, max_id, ids
end

local function read_next_id(max_id)
  local result, err = zay.read_file(META_FILE, {})
  if result == nil then
    if not is_missing_error(err) then
      return nil, "could not read todo metadata: " .. tostring(err or "unknown error")
    end
    return max_id + 1
  end
  local decoded, decode_err = zay.json_decode(result.content)
  if type(decoded) ~= "table" or decoded.version ~= 1 or type(decoded.next_id) ~= "number"
    or decoded.next_id < 1 or math.floor(decoded.next_id) ~= decoded.next_id then
    return nil, "todo metadata is malformed; repair " .. META_FILE
      .. " before adding tasks"
  end
  return math.max(decoded.next_id, max_id + 1)
end

local function load_todos()
  local result, err = zay.read_file(TODOS_FILE, {})
  local content = ""
  if result == nil then
    if not is_missing_error(err) then
      return nil, "could not read todos: " .. tostring(err or "unknown error")
    end
  else
    content = result.content
  end

  local tasks, max_id, ids = parse_tasks(content)
  if tasks == nil then return nil, max_id end
  local next_id, metadata_err = read_next_id(max_id)
  if next_id == nil then return nil, metadata_err end
  for _, task in ipairs(tasks) do
    if task.id == nil then
      while ids[next_id] do next_id = next_id + 1 end
      set_task_id(task, next_id)
      ids[next_id] = true
      next_id = next_id + 1
    end
  end
  return tasks, nil, next_id
end

-- Persist a candidate task list back to disk. Returns true on success, or nil + err so
-- mutating handlers can surface a failed write instead of reporting success
-- while nothing was persisted (persist-before-cache doctrine).
local function save_todos(tasks)
  local lines = {}
  for _, t in ipairs(tasks) do
    local line = render_line(t)
    if line ~= "" then table.insert(lines, line) end
  end
  return zay.write_file(TODOS_FILE, table.concat(lines, "\n") .. "\n")
end

local function save_metadata(next_id)
  local made, mkdir_err = zay.mkdir(PLANS_DIR)
  if not made then return nil, "could not create metadata directory: " .. tostring(mkdir_err or "unknown error") end
  local json, encode_err = zay.json_encode({ version = 1, next_id = next_id }, { pretty = true })
  if json == nil then return nil, encode_err or "could not encode todo metadata" end
  return zay.write_file(META_FILE, json)
end

local function persist_todos(tasks, next_id)
  local ok, err = save_todos(tasks)
  if not ok then return nil, "Error: could not save todos: " .. tostring(err or "unknown error") end
  local meta_ok, meta_err = save_metadata(next_id)
  if not meta_ok then
    return nil, "Error: todos were saved, but metadata was not: " .. tostring(meta_err or "unknown error")
  end
  _G.todos = tasks
  return true
end

-- ── plans.json file I/O ─────────────────────────────────────────────

-- Load the plan sidecar. A missing file is an empty map; malformed existing
-- data is an error so plan mutations cannot overwrite user data with `{}`.
local function load_plans()
  local result, err = zay.read_file(PLANS_FILE, {})
  if result == nil then
    if is_missing_error(err) then return {} end
    return nil, "could not read plans: " .. tostring(err or "unknown error")
  end
  local decoded, decode_err = zay.json_decode(result.content)
  if decoded == nil then
    return nil, "plans sidecar is malformed: " .. tostring(decode_err or "invalid JSON")
  end
  if type(decoded) ~= "table" then
    return nil, "plans sidecar is malformed: expected an object"
  end
  for key, plan in pairs(decoded) do
    if type(key) ~= "string" or type(plan) ~= "table"
      or type(plan.summary) ~= "string" or type(plan.steps) ~= "table"
      or (plan.notes ~= nil and type(plan.notes) ~= "string") then
      return nil, "plans sidecar is malformed: invalid plan shape for " .. tostring(key)
    end
    for index, step in ipairs(plan.steps) do
      if type(step) ~= "table" or type(step.text) ~= "string"
        or type(step.done) ~= "boolean" then
        return nil, "plans sidecar is malformed: invalid step " .. tostring(index)
      end
    end
  end
  return decoded
end

-- Persist plans back to the sidecar with pretty indentation so a human can read
-- or hand-edit it in a text editor. Returns true on success, or nil + err.
local function save_plans(plans)
  local made, mkdir_err = zay.mkdir(PLANS_DIR)
  if not made then return nil, "could not create plans directory: " .. tostring(mkdir_err or "unknown error") end
  local json, encode_err = zay.json_encode(plans, { pretty = true })
  if json == nil then
    return nil, encode_err or "could not encode plans"
  end
  return zay.write_file(PLANS_FILE, json)
end

local function clone_plans(plans)
  local copy = {}
  for key, plan in pairs(plans) do
    local plan_copy = { summary = plan.summary, notes = plan.notes, steps = {} }
    for index, step in ipairs(plan.steps or {}) do
      plan_copy.steps[index] = { text = step.text, done = step.done }
    end
    copy[key] = plan_copy
  end
  return copy
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
  local todos, todo_err = load_todos()
  if todos == nil then return nil, todo_err end
  local plans, plans_err = load_plans()
  if plans == nil then return nil, plans_err end
  local open_count = 0
  local done_count = 0
  for _, t in ipairs(todos) do
    if t.done then done_count = done_count + 1 else open_count = open_count + 1 end
  end

  local out = {}
  table.insert(out, string.format("Todo list (%d open, %d done):", open_count, done_count))
  table.insert(out, "")

  if #todos == 0 then
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
  for i, t in ipairs(todos) do
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
zay.register_tool({
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
    local out, err = summarize(params.include_done == true)
    if out == nil then return fail(err) end
    return out
  end,
})

-- todo_add: add a new task.
zay.register_tool({
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
      return fail("task text is required")
    end
    local priority = params.priority
    if priority ~= nil and priority ~= "" then
      if type(priority) ~= "string" or #priority ~= 1 then
        return fail("priority must be a single letter A-Z or empty")
      end
      priority = priority:upper()
      local priority_code = priority:byte()
      if priority_code < string.byte("A") or priority_code > string.byte("Z") then
        return fail("priority must be a single letter A-Z or empty")
      end
    elseif priority == "" then
      priority = nil
    end
    local current, load_err, next_id = load_todos()
    if current == nil then return fail(load_err) end
    local candidate = clone_tasks(current)
    local new_id = next_id

    -- Append id:N to the text so it round-trips through todo.txt on disk.
    -- Strip only a TRAILING id tag, then append the new one — a mid-sentence
    -- `id:N` mention (e.g. "Fix id:3 reference") must be left untouched, not
    -- globally rewritten (the old gsub rewrote every ` id:N` occurrence).
    local text = (params.text:gsub("%s*id:%d+%s*$", "")) .. " id:" .. new_id

    local t = {
      done = false,
      priority = priority,
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
    table.insert(candidate, t)
    local saved, save_err = persist_todos(candidate, new_id + 1)
    if not saved then return nil, save_err end
    local out, summary_err = summarize(false)
    if out == nil then return fail(summary_err) end
    return "Added task #" .. #candidate .. " (id:" .. new_id .. "): " .. render_line(t) .. "\n\n" .. out
  end,
})

-- todo_done: mark a task complete.
zay.register_tool({
  name = "todo_done",
  description = "Mark a task as done (completed). Sets the completion date automatically. Only mark a task done AFTER the required work is actually done and verified — never based on intent. Returns the updated list.",
  parameters = {
    id = {
      type = "integer",
      description = "Task number (from todo_list) to mark complete",
    },
  },
  handler = function(params)
    local current, load_err, next_id = load_todos()
    if current == nil then return fail(load_err) end
    if not is_index(params.id, #current) then
      return fail("invalid task id (use todo_list to see valid ids)")
    end
    local candidate = clone_tasks(current)
    local t = candidate[params.id]
    if t.done then
      return "Task #" .. params.id .. " is already done."
    end
    t.done = true
    t.completed = today()
    local saved, save_err = persist_todos(candidate, next_id)
    if not saved then return nil, save_err end
    local out, summary_err = summarize(false)
    if out == nil then return fail(summary_err) end
    return "Completed task #" .. params.id .. ": " .. t.text .. "\n\n" .. out
  end,
})

-- todo_delete: remove a task permanently.
zay.register_tool({
  name = "todo_delete",
  description = "Delete a task permanently from the todo list. Use this for tasks that were added by mistake or are no longer relevant (not for completed work — use todo_done for that). Returns the updated list.",
  parameters = {
    id = {
      type = "integer",
      description = "Task number (from todo_list) to delete",
    },
  },
  handler = function(params)
    local current, load_err, next_id = load_todos()
    if current == nil then return fail(load_err) end
    if not is_index(params.id, #current) then
      return fail("invalid task id (use todo_list to see valid ids)")
    end
    local plans, plans_err = load_plans()
    if plans == nil then return fail(plans_err) end
    local candidate = clone_tasks(current)
    local removed = table.remove(candidate, params.id)
    local saved, save_err = persist_todos(candidate, next_id)
    if not saved then return nil, save_err end
    local key = task_id(removed, params.id)
    if plans[key] ~= nil then
      local pruned = clone_plans(plans)
      pruned[key] = nil
      local plans_ok, plan_err = save_plans(pruned)
      if not plans_ok then
        _G.todos = candidate
        return nil, "Error: task deleted, but plan cleanup failed: " .. tostring(plan_err or "unknown error")
      end
    end
    local out, summary_err = summarize(false)
    if out == nil then return fail(summary_err) end
    return "Deleted: " .. removed.text .. "\n\n" .. out
  end,
})

-- todo_prioritize: set or change a task's priority.
zay.register_tool({
  name = "todo_prioritize",
  description = "Set or change a task's priority (A=high through Z=low). Pass priority as a single uppercase letter. Pass empty string or nil to remove priority. Returns the updated list.",
  parameters = {
    id = {
      type = "integer",
      description = "Task number (from todo_list)",
    },
    priority = {
      type = "string",
      description = "Single letter A-Z, or empty to remove priority",
      optional = true,
    },
  },
  handler = function(params)
    local current, load_err, next_id = load_todos()
    if current == nil then return fail(load_err) end
    if not is_index(params.id, #current) then
      return fail("invalid task id (use todo_list to see valid ids)")
    end
    local candidate = clone_tasks(current)
    local t = candidate[params.id]
    local pri = params.priority
    if pri and #pri == 1 then
      pri = pri:upper()
      if pri:byte() >= 65 and pri:byte() <= 90 then
        t.priority = pri
      else
        return fail("priority must be a letter A-Z")
      end
    elseif pri and #pri == 0 then
      t.priority = nil
    else
      return fail("priority must be a single letter A-Z or empty")
    end
    local saved, save_err = persist_todos(candidate, next_id)
    if not saved then return nil, save_err end
    local out, summary_err = summarize(false)
    if out == nil then return fail(summary_err) end
    return "Set priority " .. (t.priority or "(none)") .. " on task #" .. params.id .. "\n\n" .. out
  end,
})

-- todo_write: replace the entire list in one shot (for bulk reordering).
zay.register_tool({
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
      return fail("tasks string is required")
    end
    local current, load_err, next_id = load_todos()
    if current == nil then return fail(load_err) end
    local existing_plans, plans_err = load_plans()
    if existing_plans == nil then return fail(plans_err) end
    local candidate = {}
    local ids = {}
    for line in params.tasks:gmatch("[^\r\n]+") do
      local t = parse_line(line)
      if t.text ~= "" or t.done then
        if t.tags.id ~= nil and t.id == nil then
          return fail("invalid numeric id tag in replacement")
        end
        if t.id ~= nil then
          if t.id < 1 or math.floor(t.id) ~= t.id then
            return fail("invalid numeric id in replacement")
          end
          if ids[t.id] then
            return fail("duplicate task id:" .. t.id .. " in replacement")
          end
          ids[t.id] = true
          if t.id >= next_id then next_id = t.id + 1 end
        end
        table.insert(candidate, t)
      end
    end
    -- Backfill missing ids without reusing retired ids.
    for _, t in ipairs(candidate) do
      if t.id == nil then
        while ids[next_id] do next_id = next_id + 1 end
        set_task_id(t, next_id)
        ids[next_id] = true
        next_id = next_id + 1
      end
    end
    local saved, save_err = persist_todos(candidate, next_id)
    if not saved then return nil, save_err end

    local retained = {}
    for _, task in ipairs(candidate) do retained[task_id(task, 0)] = true end
    local pruned = clone_plans(existing_plans)
    local removed_plan = false
    for key in pairs(pruned) do
      if not retained[key] then
        pruned[key] = nil
        removed_plan = true
      end
    end
    if removed_plan then
      local plans_ok, plan_err = save_plans(pruned)
      if not plans_ok then
        _G.todos = candidate
        return nil, "Error: todo list replaced, but orphan-plan cleanup failed: " .. tostring(plan_err or "unknown error")
      end
    end
    local out, summary_err = summarize(false)
    if out == nil then return fail(summary_err) end
    return "Replaced todo list with " .. #candidate .. " tasks.\n\n" .. out
  end,
})

-- ── tools: detailed plans (lazy-loaded sidecar) ─────────────────────

-- todo_get_plan: fetch the full plan for one task.
zay.register_tool({
  name = "todo_get_plan",
  description = "Get the detailed plan for a task (summary, checklist steps with done state, and notes). Call this BEFORE starting work on a task whose todo_list line showed [plan:N steps] — it shows how the work was decomposed. Returns 'No plan for task #N' if none exists; use todo_set_plan to create one.",
  parameters = {
    id = {
      type = "integer",
      description = "Task number (from todo_list) whose plan to read",
    },
  },
  handler = function(params)
    local todos, load_err = load_todos()
    if todos == nil then return fail(load_err) end
    if not is_index(params.id, #todos) then
      return fail("invalid task id (use todo_list to see valid ids)")
    end
    local t = todos[params.id]
    local key = task_id(t, params.id)
    local plans, plans_err = load_plans()
    if plans == nil then return fail(plans_err) end
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
zay.register_tool({
  name = "todo_set_plan",
  description = "Create or replace a task's detailed plan before doing multi-step work. Write a one-line summary, break the work into checklist steps (newline-separated), and optionally add free-form notes. The plan is stored separately in plans.json so todo_list stays compact — plan bodies are fetched on demand via todo_get_plan. Returns the saved plan.",
  parameters = {
    id = {
      type = "integer",
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
    local todos, load_err = load_todos()
    if todos == nil then return fail(load_err) end
    if not is_index(params.id, #todos) then
      return fail("invalid task id (use todo_list to see valid ids)")
    end
    if not params.summary or params.summary == "" then
      return fail("summary is required")
    end
    if not params.steps or params.steps == "" then
      return fail("steps is required (use newline-separated checklist; pass a single line if just one step)")
    end

    local t = todos[params.id]
    local key = task_id(t, params.id)

    -- Parse the steps string into {text, done=false} records. Blank lines are
    -- skipped so a trailing newline doesn't create an empty step.
    local step_list = {}
    for line in params.steps:gmatch("[^\r\n]+") do
      if line ~= "" then
        table.insert(step_list, { text = line, done = false })
      end
    end

    local plans, plans_err = load_plans()
    if plans == nil then return fail(plans_err) end
    plans = clone_plans(plans)
    plans[key] = {
      summary = params.summary,
      steps = step_list,
      notes = params.notes or "",
    }
    local saved, save_err = save_plans(plans)
    if not saved then return fail("could not save plans: " .. tostring(save_err or "unknown error")) end

    return string.format("Plan set for task #%d (id:%s): %s\n%d steps recorded.\n\nUse todo_get_plan to view it.",
      params.id, key, t.text, #step_list)
  end,
})

-- todo_check_step: toggle a step's completion in a plan.
zay.register_tool({
  name = "todo_check_step",
  description = "Toggle a step's completion (done <-> not done) in a task's plan checklist. Use this right after finishing a planned step to track granular progress. Returns the updated plan. Requires a plan to exist (create one with todo_set_plan first).",
  parameters = {
    id = {
      type = "integer",
      description = "Task number (from todo_list)",
    },
    step = {
      type = "integer",
      description = "Step number to toggle (1-indexed, as shown by todo_get_plan)",
    },
  },
  handler = function(params)
    local todos, load_err = load_todos()
    if todos == nil then return fail(load_err) end
    if not is_index(params.id, #todos) then
      return fail("invalid task id (use todo_list to see valid ids)")
    end
    local t = todos[params.id]
    local key = task_id(t, params.id)
    local plans, plans_err = load_plans()
    if plans == nil then return fail(plans_err) end
    local plan = plans[key]
    if not plan or not plan.steps or #plan.steps == 0 then
      return fail("no plan steps for task #" .. params.id
        .. ". Use todo_set_plan to create one first."
      )
    end
    if not is_index(params.step, #plan.steps) then
      return fail(string.format("invalid step number (1-%d). Use todo_get_plan to see steps.", #plan.steps))
    end

    plans = clone_plans(plans)
    local s = plans[key].steps[params.step]
    s.done = not s.done
    local saved, save_err = save_plans(plans)
    if not saved then return fail("could not save plans: " .. tostring(save_err or "unknown error")) end

    local state = s.done and "done" or "open"
    return string.format("Step %d marked %s for task #%d.\n\n", params.step, state, params.id)
      .. "Use todo_get_plan to view the full plan."
  end,
})
