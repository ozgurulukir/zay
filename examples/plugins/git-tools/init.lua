-- init.lua — Git Tools
-- Registers git_status / git_diff / git_log / git_branch / git_commit. These
-- wrap Nova's git bridge functions. The behavioral guidance (when to commit,
-- what to inspect first) lives in prompt.md, not in code.

-- ── git_status ──────────────────────────────────────────────────────

nova.register_tool({
  name = "git_status",
  description = "Show the current branch and working tree status (porcelain format). Use this before proposing changes or a commit to see what is modified, staged, or untracked.",
  parameters = {},
  handler = function()
    local branch = nova.git_branch()
    local status = nova.git_status()
    if status == nil then
      return "Error: not a git repository (or git failed)"
    end
    -- git branch --show-current returns "" on a detached HEAD (and the bridge
    -- now returns nil + error outside a repo). Treat empty as a distinct case
    -- rather than printing a blank "Branch: ".
    if branch == nil or branch == "" then
      return "Error: could not determine branch (detached HEAD or not a git repository)"
    end
    local out = string.format("Branch: %s\n", branch)
    if status and #status > 0 then
      out = out .. status
    else
      out = out .. "Working tree is clean."
    end
    return out
  end,
})

-- ── git_diff ────────────────────────────────────────────────────────

nova.register_tool({
  name = "git_diff",
  description = "Show uncommitted changes (git diff). Pass a path to diff a specific file; omit for all changes. Use this to review what changed before committing.",
  parameters = {
    path = {
      type = "string",
      description = "File path to diff (optional; omit for all changes)",
      optional = true,
    },
  },
  handler = function(params)
    local diff = nova.git_diff(params.path)
    if diff == nil then
      return "Error: git diff failed"
    end
    if diff == "" then
      return "No uncommitted changes."
    end
    return diff
  end,
})

-- ── git_log ─────────────────────────────────────────────────────────

nova.register_tool({
  name = "git_log",
  description = "Show recent commit history. Use this to understand recent work and to match the project's existing commit message style before writing a new commit.",
  parameters = {
    n = {
      type = "integer",
      description = "Number of commits to show (default 10)",
      optional = true,
    },
  },
  handler = function(params)
    -- Validate n as a positive integer <= 1000; anything else defaults to 10.
    -- A fractional n (e.g. 2.5) would otherwise raise in string.format.
    local n = params.n
    if type(n) ~= "number" or n < 1 or n > 1000 or math.floor(n) ~= n then
      n = 10
    end
    local log = nova.git_log(n)
    if log == nil then
      return "Error: git log failed"
    end
    if log == "" then
      return "No commits found."
    end
    -- Count the lines actually returned instead of echoing the requested n
    -- (fixes "Last 0 commits" when n clamps to 1).
    local count = 0
    for _ in log:gmatch("[^\n]+") do count = count + 1 end
    return string.format("Last %d commits:\n\n%s", count, log)
  end,
})

-- ── git_branch ──────────────────────────────────────────────────────

nova.register_tool({
  name = "git_branch",
  description = "Show the current branch name. Lightweight; use this when you only need the branch, not the full status.",
  parameters = {},
  handler = function()
    local branch = nova.git_branch()
    if branch == nil then
      return "Error: could not determine branch (not a git repository?)"
    end
    return "Current branch: " .. branch
  end,
})

-- ── git_add ─────────────────────────────────────────────────────────

nova.register_tool({
  name = "git_add",
  description = "Stage specific file(s) for the next commit. Always stage only the intended modified files rather than staging untracked or scratch files.",
  parameters = {
    files = {
      type = "string",
      description = "File path or comma-separated list of file paths to stage (e.g. 'src/main.zig, src/tools/git.zig')",
    },
  },
  handler = function(params)
    if not params.files or params.files == "" then
      return "Error: files parameter is required"
    end
    local result = nova.git_add(params.files)
    if result == nil then
      return "Error: git add failed"
    end
    if result.success then
      return "Staged files: " .. params.files
    end
    return "Error: git add failed — " .. (result.output or "unknown error")
  end,
})

-- ── git_commit ──────────────────────────────────────────────────────

nova.register_tool({
  name = "git_commit",
  description = "Create a git commit with the given message. Can commit specific files, only staged changes, or all changes (with stage_all). IMPORTANT: only commit when the user explicitly asks, except lane work — when working in a Nova lane, commit your lane changes with a real message before `lane merge`. Before committing, inspect git_status and git_diff, stage only intended files, and never commit secrets. If a commit fails (e.g. hooks reject it), fix the issue and create a new commit — do not amend the failed commit.",
  parameters = {
    message = {
      type = "string",
      description = "Commit message",
    },
    files = {
      type = "string",
      description = "Optional file path or comma-separated list of files to stage and commit (e.g. 'src/main.zig'). If omitted, commits files already staged via git_add.",
      optional = true,
    },
    stage_all = {
      type = "boolean",
      description = "If true, stages all changes (git add -A) before committing. Default is false to prevent accidental commits of untracked or secret files.",
      optional = true,
    },
  },
  handler = function(params)
    if not params.message or params.message == "" then
      return "Error: commit message is required"
    end
    local opts = {}
    if params.files and params.files ~= "" then
      opts.files = params.files
    elseif params.stage_all then
      opts.stage_all = true
    else
      opts.staged_only = true
    end

    local result = nova.git_commit(params.message, opts)
    if result == nil then
      return "Error: git commit failed"
    end
    if result.success then
      return "Committed: " .. (result.output or params.message)
    end
    return "Error: commit failed — " .. (result.output or "unknown error") ..
      "\n\nFix the issue and create a new commit; do not amend the failed commit."
  end,
})
