Run a shell command.

- Set the working directory with the `cwd` param, not `cd dir && ...` because each call starts a fresh shell. The `cwd` must be within the project root.
- Pass values via `env: { NAME: "..." }` for multiline or complex values. Reference them as `"$NAME"`.
- Provide a `description` for every command — a human-readable single-sentence explanation of what it does.
- Quote every expansion: `"$var"`, `"$(cmd)"`, `"${arr[@]}"`.
- Default timeout is 30 seconds. Raise it with the `timeout` parameter when a command needs longer; a timed-out result tells you how to retry.
- Prefer targeted commands (`rg`, `find`, `git diff --stat`, `head`, `tail`) over dumping large files or full build logs.
- Each result echoes the command you ran, then its full output. A result is complete unless it ends with a truncation notice — `[Showing last N of M lines (X of Y bytes). Full output: /path]` — which appears only when output exceeded 50 KB or 2000 lines. No notice means you have the entire output: trust it, do not assume truncation, and do not re-read the same content. If a notice is present, follow the full-output path to read the rest or rerun with a narrower command.

## Reading files (sliding window)

Never dump a whole file into the transcript. Locate, then read a bounded window, then slide:

- Locate first: `rg -n "pattern" path` gives exact line numbers — never guess with a blind `cat`.
- Read a bounded window: `sed -n 'START,ENDp' path`, or `rg -C 5 "pattern"` for context around each match.
- Slide as needed: `sed -n 'END,NEW_ENDp'` continues below; `sed -n 'NEW_START,STARTp'` looks above.
- Full read only when the whole file matters: `cat -n path` (line numbers keep later windows addressable). Use `head`/`tail` for boundary checks.

Bounded reads keep the transcript small and leave more context for reasoning.

## Long-running commands

- For commands that take a long time or never return on their own — builds, dev servers, watchers, `tail -f` — set `run_in_background: true`. The call returns immediately with a job id, pid, and a log file path instead of blocking.
- The command keeps running after the call returns. Its eventual exit is delivered to you as a message; do not poll in a busy loop waiting for it.
- To check on or cancel a background job meanwhile, use the `background` tool (`background { command: "status", id: <id> }`, `background { command: "tail", id: <id> }`, or `background { command: "cancel", id: <id> }`). The log path stays valid for the life of the job.
- `timeout` is ignored for background commands. Use a normal (foreground) call for anything you need the output of right away.

## Error handling

- A non-zero exit code is returned in the result. For multi-step commands, chain with `&&` or start scripts with `set -euo pipefail`.
- Prefer non-interactive flags (`-y`, `--no-input`, `< /dev/null`) so a command never blocks waiting for a prompt — a hanging prompt stalls the turn until the timeout.
- Commands that may legitimately fail should end with `|| true` so later steps still run.

## Useful patterns

```bash
# Sequential steps. Stop on first failure.
npm run lint && npm test

# Inspect a file or directory without dumping too much text.
ls -la src && head -80 src/main.ts

# Search text with ripgrep.
rg -n "TODO" src

# Locate paths with fd when available, or shell globs for simple cases.
fd main src

# Summarize repository changes.
git diff --stat && git status --short

# Create or replace a file.
cat <<'EOF' > main.ts
const users = getUsers();
console.log(users);
EOF

# Edit a file or run any Python — always through uv, always a quoted heredoc.
uv run --project .nova python - <<'PY'
from nova import edit
edit("src/main.ts", "const users = getUsers();", "const users = await getUsers();")
PY
```

## Pitfalls

- `$var` unquoted splits on spaces and glob characters. Use `"$var"`.
- `if [ -n $var ]` breaks when `$var` is empty. Use `if [ -n "$var" ]`.
- `for f in $(ls *.rs)` breaks on spaces and newlines. Use shell globs or a small Python script.
- `cd dir && cmd` resets next call. Use the `cwd` param.
- `cmd 2>&1 > file` only sends stdout to the file. Use `cmd > file 2>&1`.
