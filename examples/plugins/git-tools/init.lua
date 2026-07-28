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
    local out = string.format("Branch: %s\n", branch or "unknown")
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
      type = "number",
      description = "Number of commits to show (default 10)",
      optional = true,
    },
  },
  handler = function(params)
    local count = params.n or 10
    local log = nova.git_log(count)
    if log == nil then
      return "Error: git log failed"
    end
    if log == "" then
      return "No commits found."
    end
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

-- ── git_commit ──────────────────────────────────────────────────────

nova.register_tool({
  name = "git_commit",
  description = "Stage all changes and create a commit with the given message. IMPORTANT: only commit when the user explicitly asks. Before committing, inspect git_status and git_diff, stage only intended files, and never commit secrets. If a commit fails (e.g. hooks reject it), fix the issue and create a new commit — do not amend the failed commit.",
  parameters = {
    message = {
      type = "string",
      description = "Commit message",
    },
  },
  handler = function(params)
    if not params.message or params.message == "" then
      return "Error: commit message is required"
    end
    local result = nova.git_commit(params.message)
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
