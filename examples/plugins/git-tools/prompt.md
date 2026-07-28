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
- `lua__git-tools__git_commit` — Stage all changes and commit. Use this only
  when the user explicitly asks to commit.

## Guidelines — git discipline

- **Only commit, amend, push, or create PRs when the user explicitly requests
  it.** Do not commit proactively.
- **Inspect before committing.** Call `git_status` and `git_diff` first so your
  commit reflects what actually changed. Stage only the intended files and
  never commit secrets (API keys, credentials, `.env` files).
- **Match the commit style.** Call `git_log` before writing a commit message to
  match the project's existing style (imperative mood, conventional-commit
  prefix, etc.). Do not invent a new format if the history shows a consistent
  one.
- **If a commit fails** (e.g. hooks reject it, or the message is wrong), fix
  the issue and create a **new** commit. Do not amend the failed commit.
- **`git_commit` stages everything** (`git add -A`). There is no selective
  staging API — if you need to stage only specific files, use `bash git add
  <files>` first, then call `git_commit`.
- **Do not** update git config, skip hooks, use interactive `-i`, force-push,
  or create empty commits unless the user explicitly requests it.
