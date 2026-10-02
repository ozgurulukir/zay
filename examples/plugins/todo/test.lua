-- test.lua — Todo plugin tests
--
-- Loads the real plugin source with a mocked `zay` bridge and exercises the
-- handlers. Covers the data-integrity fixes:
--   B1  parse_line off-by-one: round-trip keeps a single space and `created`.
--   B4  todo_add must not rewrite mid-sentence `id:N` mentions.
--   B3  load_plans must tolerate scalar (non-table) JSON in plans.json.
--   B2  fractional/zero/out-of-range ids return an Error string, never raise.
--   B5  a failing write_file makes mutating tools return an error string.
--   C1  ids are monotonic across deletion and restart, with duplicate rejection.
--   C2  malformed plans fail closed and orphaned plans are pruned on replace.
local test = test_runner

-- ── Mock the zay bridge, then load the plugin ──────────────────────
local registered = {}
local todos_content = ""
local plans_content = nil
local metadata_content = nil
local write_reply = true
local last_write = nil
local last_metadata_write = nil

zay = {
  register_tool = function(tool)
    registered[tool.name] = tool
  end,
  on = function() return true end,
  read_file = function(path, opts)
    if path == ".zay/todos.txt" then
      return { content = todos_content, path = path }
    end
    if path == ".zay/todos/plans.json" then
      if plans_content == nil then return nil end
      return { content = plans_content, path = path }
    end
    if path == ".zay/todos/metadata.json" then
      if metadata_content == nil then return nil end
      return { content = metadata_content, path = path }
    end
    return nil
  end,
  write_file = function(path, content)
    if path == ".zay/todos.txt" then
      last_write = { path = path, content = content }
      todos_content = content
    elseif path == ".zay/todos/metadata.json" then
      last_metadata_write = { path = path, content = content }
      metadata_content = content
    elseif path == ".zay/todos/plans.json" then
      plans_content = content
    end
    return write_reply
  end,
  mkdir = function() return true end,
  json_decode = function(s)
    -- Decode the small JSON fixtures used in these tests (object/scalar).
    if s == "42" then return 42 end
    if s == '"x"' then return "x" end
    local next_id = s:match('"next_id"%s*:%s*(%d+)')
    if next_id then return { version = 1, next_id = tonumber(next_id) } end
    if s == '{"1": {"summary": "s", "steps": [{"text": "a", "done": false}]}}' then
      return { ["1"] = { summary = "s", steps = { { text = "a", done = false } } } }
    end
    return {}
  end,
  json_encode = function(value)
    if type(value) == "table" and value.next_id ~= nil then
      return string.format('{"version":1,"next_id":%d}', value.next_id)
    end
    return "{}"
  end,
}

local f = assert(io.open("examples/plugins/todo/init.lua", "r"))
local src = f:read("*a")
f:close()
assert(load(src, "@todo/init.lua"))()

local todo_add = registered.todo_add
local todo_done = registered.todo_done
local todo_delete = registered.todo_delete
local todo_prioritize = registered.todo_prioritize
local todo_list = registered.todo_list
local todo_get_plan = registered.todo_get_plan
local todo_set_plan = registered.todo_set_plan
local todo_check_step = registered.todo_check_step
local todo_write = registered.todo_write

-- Reset the on-disk state between tests.
local function reset(todos, plans, metadata)
  todos_content = todos or ""
  plans_content = plans
  metadata_content = metadata
  write_reply = true
  last_write = nil
  last_metadata_write = nil
end

-- ── B1: parse_line off-by-one ───────────────────────────────────────

test.describe("todo parse_line round-trip", function()
  test.it("prioritized task round-trips with a single space and created intact", function()
    reset("(A) 2026-08-01 urgent thing\n")
    -- Trigger a save to round-trip through parse_line + render_line. The bug
    -- produced "(A)  2026-08-01 ..." (double space) and dropped `created`, so
    -- the date leaked into the text instead of round-tripping as a field.
    todo_prioritize.handler({ id = 1, priority = "A" })
    test.assert.contains("(A) 2026-08-01 urgent thing", last_write.content)
    test.assert.is_false(last_write.content:find("(A)  ", 1, true) ~= nil, "no double space")
  end)

  test.it("done line keeps completed and created dates", function()
    reset("x 2026-08-03 2026-08-01 done thing\n")
    -- Trigger a save via a mutator and verify both dates survive the round-trip.
    todo_prioritize.handler({ id = 1, priority = "A" })
    -- render_line emits: x <completed> (<pri>) <created> <text>
    test.assert.contains("x 2026-08-03 (A) 2026-08-01 done thing", last_write.content)
  end)

  test.it("two-space input normalizes to one on save", function()
    reset("(A)  2026-08-01 messy\n")
    todo_done.handler({ id = 1 })
    test.assert.is_false(last_write.content:find("(A)  ", 1, true) ~= nil, "single space after save")
  end)

  test.it("completed task with a date at end-of-line keeps it as completed", function()
    -- A date with no trailing text must parse as the COMPLETION date, not the
    -- creation date (the old first-date match required a trailing space, so
    -- the line fell through to the second-date site and landed in `created`).
    reset("x 2026-08-03\n")
    todo_prioritize.handler({ id = 1, priority = "A" })
    -- render_line emits: x <completed> (<pri>) <text>. Mis-parsed as created,
    -- the line would render "x (A) 2026-08-03" instead.
    test.assert.contains("x 2026-08-03 (A)", last_write.content)
  end)

  test.it("open tasks sort by priority, then by creation date", function()
    reset("(A) 2026-08-05 newer task\n(A) 2026-08-01 older task\n(B) 2026-07-01 low pri task\n")
    local out = todo_list.handler({})
    local pos_older = out:find("older task", 1, true)
    local pos_newer = out:find("newer task", 1, true)
    local pos_low = out:find("low pri task", 1, true)
    test.assert.is_true(pos_older ~= nil and pos_newer ~= nil and pos_low ~= nil, "all tasks listed")
    -- Same priority (A): earlier creation date sorts first.
    test.assert.is_true(pos_older < pos_newer, "earlier date sorts first within priority A")
    -- Priority beats date: (A) tasks precede the older-dated (B) task.
    test.assert.is_true(pos_newer < pos_low, "priority beats date")
  end)
end)

-- ── B4: todo_add id anchoring ───────────────────────────────────────

test.describe("todo_add id handling", function()
  test.it("rejects an invalid priority without writing", function()
    reset("")
    local out, err = todo_add.handler({ text = "task", priority = "AA" })
    test.assert.is_true(out == nil)
    test.assert.contains("priority must be a single letter A-Z or empty", err)
    test.assert.is_true(last_write == nil)
  end)

  test.it("normalizes lowercase priorities", function()
    reset("")
    local out, err = todo_add.handler({ text = "task", priority = "a" })
    test.assert.is_true(out ~= nil, err)
    test.assert.contains("(A) ", last_write.content)
    test.assert.contains("task", last_write.content)
  end)

  test.it("preserves mid-sentence id:N mentions and appends one new id", function()
    reset("")
    local out = todo_add.handler({ text = "Fix id:3 reference and link id:7 later" })
    -- Both mid-text mentions survive; a single new id is appended.
    test.assert.contains("id:3", last_write.content)
    test.assert.contains("id:7", last_write.content)
    test.assert.contains(" id:1", last_write.content)
    test.assert.is_false(out:find("Lua tool error", 1, true) ~= nil)
  end)

  test.it("replaces a trailing user-supplied id", function()
    reset("")
    todo_add.handler({ text = "task id:5" })
    test.assert.contains(" id:1", last_write.content)
    test.assert.is_false(last_write.content:find("id:5", 1, true) ~= nil, "trailing id replaced")
  end)

  test.it("appends id once when no trailing id present", function()
    reset("")
    todo_add.handler({ text = "plain task" })
    local _, count = last_write.content:gsub("id:1", "")
    test.assert.equal(1, count)
  end)
end)

-- ── C1/C2: durable ids and plan sidecar integrity ─────────────────

test.describe("todo durable ids", function()
  test.it("rejects duplicate ids without writing a replacement", function()
    reset("")
    local _, err = todo_write.handler({ tasks = "first id:4\nsecond id:4\n" })
    test.assert.contains("duplicate task id:4", err)
    test.assert.is_true(last_write == nil)
  end)

  test.it("does not reuse the highest id after delete", function()
    reset("first id:4\n")
    local deleted = todo_delete.handler({ id = 1 })
    test.assert.contains("Deleted", deleted)
    local saved_todos = todos_content
    local saved_metadata = metadata_content

    reset(saved_todos, nil, saved_metadata)
    local added = todo_add.handler({ text = "new task" })
    test.assert.contains("id:5", added)
    test.assert.contains("id:5", last_write.content)
  end)

  test.it("continues the id sequence after a plugin restart", function()
    reset("")
    todo_add.handler({ text = "first task" })
    local saved_todos = todos_content
    local saved_metadata = metadata_content

    reset(saved_todos, nil, saved_metadata)
    todo_add.handler({ text = "second task" })
    test.assert.contains("first task id:1", last_write.content)
    test.assert.contains("second task id:2", last_write.content)
  end)

  test.it("refuses malformed metadata instead of guessing an id", function()
    reset("task id:3\n", nil, "{}")
    local _, err = todo_add.handler({ text = "new task" })
    test.assert.contains("metadata is malformed", err)
    test.assert.is_true(last_write == nil)
  end)

  test.it("todo_write preserves ids and assigns fresh ids to replacements", function()
    reset("old id:1\n")
    local out = todo_write.handler({ tasks = "replacement id:1\nfresh replacement\n" })
    test.assert.contains("Replaced todo list", out)
    test.assert.contains("replacement id:1", last_write.content)
    test.assert.contains("fresh replacement id:2", last_write.content)
  end)
end)

-- ── B3: load_plans type guard ───────────────────────────────────────

test.describe("todo load_plans type guard", function()
  test.it("scalar JSON in plans.json fails closed in todo_list", function()
    reset("(A) 2026-08-01 task\n", "42")
    local _, out = todo_list.handler({})
    test.assert.contains("plans sidecar is malformed", out)
  end)

  test.it("string JSON in plans.json fails closed in todo_get_plan", function()
    reset("(A) 2026-08-01 task\n", '"x"')
    local _, out = todo_get_plan.handler({ id = 1 })
    test.assert.contains("plans sidecar is malformed", out)
  end)

  test.it("malformed plans block plan writes and todo replacement", function()
    reset("(A) 2026-08-01 task\n", "42")
    local _, plan_err = todo_set_plan.handler({ id = 1, summary = "s", steps = "a" })
    test.assert.contains("plans sidecar is malformed", plan_err)
    test.assert.is_true(last_write == nil)

    reset("(A) 2026-08-01 task\n", "42")
    local _, replace_err = todo_write.handler({ tasks = "replacement" })
    test.assert.contains("plans sidecar is malformed", replace_err)
    test.assert.is_true(last_write == nil)
  end)

  test.it("todo_write prunes plans for tasks removed by replacement", function()
    reset("old id:1\n", '{"1": {"summary": "s", "steps": [{"text": "a", "done": false}]}}')
    local out = todo_write.handler({ tasks = "new task" })
    test.assert.contains("Replaced todo list", out)
    test.assert.equal("{}", plans_content)
  end)
end)

-- ── B2: fractional/zero/out-of-range ids ────────────────────────────

test.describe("todo numeric param validation", function()
  test.it("fractional id returns an Error string, never raises", function()
    reset("(A) 2026-08-01 task one\n(B) 2026-08-02 task two\n")
    -- 1.5 is in range (1 <= 1.5 <= 2) but not an integer; the old code indexed
    -- _G.todos[1.5] -> nil -> .done raised a Lua tool error.
    local _, out = todo_done.handler({ id = 1.5 })
    test.assert.contains("Error:", out)
  end)

  test.it("zero id returns an Error string", function()
    reset("(A) 2026-08-01 task\n")
    local _, out = todo_delete.handler({ id = 0 })
    test.assert.contains("Error:", out)
  end)

  test.it("negative id returns an Error string", function()
    reset("(A) 2026-08-01 task\n")
    local _, out = todo_prioritize.handler({ id = -3, priority = "A" })
    test.assert.contains("Error:", out)
  end)

  test.it("fractional step returns an Error string", function()
    reset("(A) 2026-08-01 task\n", '{"1": {"summary": "s", "steps": [{"text": "a", "done": false}]}}')
    local _, out = todo_check_step.handler({ id = 1, step = 1.5 })
    test.assert.contains("Error:", out)
  end)
end)

-- ── B5: save failures surfaced ──────────────────────────────────────

test.describe("todo save failure surfacing", function()
  test.it("todo_add returns an error when write_file fails", function()
    reset("")
    write_reply = nil
    local _, out = todo_add.handler({ text = "task" })
    test.assert.contains("Error:", out)
    test.assert.contains("could not save", out)
  end)

  test.it("todo_done returns an error when write_file fails", function()
    reset("(A) 2026-08-01 task\n")
    _G.todos = { { done = false, text = "published state" } }
    write_reply = nil
    local _, out = todo_done.handler({ id = 1 })
    test.assert.contains("Error:", out)
    test.assert.is_false(_G.todos[1].done, "failed persistence does not publish candidate")
  end)
end)

test.run()
