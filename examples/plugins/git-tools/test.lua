-- test.lua — Git Tools plugin tests
--
-- Loads the real plugin source with a mocked `nova` bridge and exercises the
-- handlers. Covers:
--   S4  git_status reports the not-a-repo error when the bridge returns nil
--       (and when it returns "" — the empty-string case that used to lie).
--   B2  git_log validates n as a positive integer (2.5 -> default 10).
--   S4  git_commit surfaces result.output on failure.
local test = test_runner

-- ── Mock the nova bridge, then load the plugin ──────────────────────
local registered = {}
local branch_reply = "main"
local status_reply = ""
local diff_reply = ""
local log_reply = ""
local commit_reply = nil
local add_reply = nil
local last_log_n = nil
local last_commit_opts = nil
local last_add_files = nil

nova = {
  register_tool = function(tool)
    registered[tool.name] = tool
  end,
  git_branch = function() return branch_reply end,
  git_status = function() return status_reply end,
  git_diff = function() return diff_reply end,
  git_log = function(n)
    last_log_n = n
    return log_reply
  end,
  git_add = function(files)
    last_add_files = files
    return add_reply
  end,
  git_commit = function(msg, opts)
    last_commit_opts = opts
    return commit_reply
  end,
}

local f = assert(io.open("examples/plugins/git-tools/init.lua", "r"))
local src = f:read("*a")
f:close()
assert(load(src, "@git-tools/init.lua"))()

local git_status = registered.git_status
local git_diff = registered.git_diff
local git_log = registered.git_log
local git_branch = registered.git_branch
local git_add = registered.git_add
local git_commit = registered.git_commit

-- ── S4: git_status not-a-repo handling ──────────────────────────────

test.describe("git_status not-a-repo handling", function()
  test.it("reports not-a-repo when the bridge returns nil", function()
    status_reply = nil
    local out = git_status.handler({})
    test.assert.contains("not a git repository", out)
  end)

  test.it("reports clean tree when status is empty in a repo", function()
    status_reply = ""
    branch_reply = "main"
    local out = git_status.handler({})
    test.assert.contains("Working tree is clean", out)
  end)

  test.it("reports detached HEAD when branch is empty", function()
    status_reply = ""
    branch_reply = ""
    local out = git_status.handler({})
    test.assert.contains("detached HEAD", out)
  end)
end)

-- ── S4: git_diff / git_branch edge cases ────────────────────────────

test.describe("git_diff and git_branch", function()
  test.it("git_diff reports no changes on empty output", function()
    diff_reply = ""
    local out = git_diff.handler({})
    test.assert.contains("No uncommitted changes", out)
  end)

  test.it("git_branch reports an error on nil", function()
    branch_reply = nil
    local out = git_branch.handler({})
    test.assert.contains("could not determine branch", out)
  end)
end)

-- ── B2: git_log integer validation ──────────────────────────────────

test.describe("git_log integer validation", function()
  test.it("fractional n defaults to 10", function()
    log_reply = "abc123 commit one\ndef456 commit two\n"
    local out = git_log.handler({ n = 2.5 })
    test.assert.equal(10, last_log_n)
    -- Header counts the lines actually returned (2), not the requested n.
    test.assert.contains("Last 2 commits", out)
  end)

  test.it("zero n defaults to 10", function()
    log_reply = "abc123 commit one\n"
    local out = git_log.handler({ n = 0 })
    test.assert.equal(10, last_log_n)
    test.assert.contains("Last 1 commits", out)
  end)

  test.it("valid integer n is passed through", function()
    log_reply = "abc123 commit one\ndef456 commit two\n"
    local out = git_log.handler({ n = 2 })
    test.assert.equal(2, last_log_n)
    test.assert.contains("Last 2 commits", out)
  end)
end)

-- ── git_add staging ──────────────────────────────────────────────────
test.describe("git_add staging", function()
  test.it("requires files parameter", function()
    local out = git_add.handler({})
    test.assert.contains("files parameter is required", out)
  end)

  test.it("stages files and reports success", function()
    add_reply = { success = true, output = "" }
    local out = git_add.handler({ files = "src/main.zig, src/tools/git.zig" })
    test.assert.equal("src/main.zig, src/tools/git.zig", last_add_files)
    test.assert.contains("Staged files", out)
  end)

  test.it("surfaces error on add failure", function()
    add_reply = { success = false, output = "pathspec 'foo.zig' did not match any files" }
    local out = git_add.handler({ files = "foo.zig" })
    test.assert.contains("pathspec 'foo.zig' did not match any files", out)
  end)
end)

-- ── S4: git_commit failure surfacing ────────────────────────────────

test.describe("git_commit failure surfacing", function()
  test.it("requires a message", function()
    local out = git_commit.handler({})
    test.assert.contains("commit message is required", out)
  end)

  test.it("surfaces result.output on a failed commit", function()
    commit_reply = { success = false, output = "pre-commit hook failed" }
    local out = git_commit.handler({ message = "wip" })
    test.assert.contains("pre-commit hook failed", out)
  end)

  test.it("defaults to staged_only when files and stage_all are omitted", function()
    commit_reply = { success = true, output = "[main abc123] wip" }
    local out = git_commit.handler({ message = "wip" })
    test.assert.equal(true, last_commit_opts.staged_only)
    test.assert.contains("Committed", out)
  end)

  test.it("passes selective files to commit", function()
    commit_reply = { success = true, output = "[main abc123] wip" }
    local out = git_commit.handler({ message = "wip", files = "src/main.zig" })
    test.assert.equal("src/main.zig", last_commit_opts.files)
    test.assert.contains("Committed", out)
  end)

  test.it("passes stage_all when requested", function()
    commit_reply = { success = true, output = "[main abc123] wip" }
    local out = git_commit.handler({ message = "wip", stage_all = true })
    test.assert.equal(true, last_commit_opts.stage_all)
    test.assert.contains("Committed", out)
  end)
end)

test.run()
