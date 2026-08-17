---
description: Git inspection and commit tools — status, diff, log, branch, commit.
---

Use the `git-tools` plugin to inspect repository state and create commits.

## When to use each tool

- `lua__git-tools__git_status` — Current branch + working tree status
  (porcelain). Use this before proposing changes or a commit.
- `lua__git-tools__git_diff` — Uncommitted changes (optionally for a single
  path). Use this to review what changed.
- `lua__git-tools__git_log` — Recent commit messages. Use this to match the
  project's commit-message style.
- `lua__git-tools__git_branch` — Just the current branch name.
- `lua__git-tools__git_add` — Stage specific files before committing. Always stage only the files you intentionally modified.
- `lua__git-tools__git_commit` — Create a commit. By default, commits files already staged via `git_add`. You can also pass `files` to stage and commit in one step, or pass `stage_all: true` to stage everything.

## Guidelines — git discipline

- **Only commit, amend, push, or create PRs when the user explicitly requests
  it.** Do not commit proactively.
- **Exception — lane work.** When you are working inside a Nova lane and need to `lane merge`, commit the lane's changes yourself with a real message first. This is the one case where committing without an explicit user request is expected and required — the merge refuses a dirty lane and will not fabricate a placeholder commit.
- **Inspect before committing.** Call `git_status` and `git_diff` first so your
  commit reflects what actually changed. Stage only the intended files (`git_add` or `git_commit({ files = "..." })`) and
  never commit secrets (API keys, credentials, `.env` files).
- **Match the commit style.** Call `git_log` before writing a commit message to
  match the project's existing style (imperative mood, conventional-commit
  prefix, etc.). Do not invent a new format if the history shows a consistent
  one.
- **If a commit fails** (e.g. hooks reject it, or the message is wrong), fix
  the issue and create a **new** commit. Do not amend the failed commit.
- **Selective staging vs Stage All:** Prefer staging specific files with `git_add` or `git_commit({ files = "..." })`. Only use `stage_all = true` when you explicitly intend to stage all untracked and modified files.
- **Do not** update git config, skip hooks, use interactive `-i`, force-push,
  or create empty commits unless the user explicitly requests it.
