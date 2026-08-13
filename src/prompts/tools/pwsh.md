Run a PowerShell command on Windows.

- Set the working directory with the `cwd` param, not `Set-Location dir; ...` because each call starts a fresh shell. The `cwd` must be within the project root.
- Pass values via `env: { NAME: "..." }` for multiline or complex values. Reference them as `"$env:NAME"`.
- Provide a `description` for every command — a human-readable single-sentence explanation of what it does.
- Quote every expansion: `"$env:var"`, `"$(cmd)"`. Bare `$env:var` splits on spaces and special characters.
- Default timeout is 30 seconds. Raise it with the `timeout` parameter when a command needs longer; a timed-out result tells you how to retry.
- Prefer targeted commands (`rg`, `Select-String`, `git diff --stat`, `Get-Content -Head`, `Get-Content -Tail`) over dumping large files or full build logs.
- Each result echoes the command you ran, then its full output. A result is complete unless it ends with a truncation notice — `[Showing last N of M lines (X of Y bytes). Full output: /path]` — which appears only when output exceeded 50 KB or 2000 lines. No notice means you have the entire output: trust it, do not assume truncation, and do not re-read the same content. If a notice is present, follow the full-output path to read the rest or rerun with a narrower command.

## Reading files (sliding window)

Never dump a whole file into the transcript. Locate, then read a bounded window, then slide:

- Locate first: `Select-String -Path path -Pattern "pattern"` gives exact line numbers — never guess with a blind `Get-Content`.
- Read a bounded window: `Get-Content path | Select-Object -First 80` for the top, `Get-Content path | Select-Object -Last 80` for the tail.
- Slide as needed: `Get-Content path | Select-Object -Skip 80 -First 80` continues; use `-Skip` to look above where you were.
- Full read only when the whole file matters: `Get-Content path` (line numbers keep later windows addressable — `Get-Content path | ForEach-Object { "{0}: {1}" -f $i++, $_ }`). Use `-Head`/`-Tail` for boundary checks.

Bounded reads keep the transcript small and leave more context for reasoning.

## Long-running commands

- For commands that take a long time or never return on their own — builds, dev servers, watchers, `Get-Content -Tail -Wait` — set `run_in_background: true`. The call returns immediately with a job id, pid, and a log file path instead of blocking.
- The command keeps running after the call returns. Its eventual exit is delivered to you as a message; do not poll in a busy loop waiting for it.
- To check on a background job meanwhile, read its log file (e.g. `Get-Content -Tail 50 <path>`) or use `Get-Process`/`Stop-Process` with the reported pid. The log path stays valid for the life of the job.
- `timeout` is ignored for background commands. Use a normal (foreground) call for anything you need the output of right away.

## Error handling

- A non-zero exit code is returned in the result. For multi-step commands, chain with `;` and check `$?`/`$LASTEXITCODE`, or use `try`/`catch` around a failing statement.
- Start multi-statement scripts with `$ErrorActionPreference = 'Stop'` so a cmdlet failure stops the run instead of continuing silently.
- `&&` / `||` chaining works only in PowerShell 7 (`pwsh`); on Windows PowerShell 5.1 (`powershell.exe`) use `if ($?) { }` or `try { } catch { }`.
- Prefer non-interactive flags (`-y`, `-NoProfile`, redirecting `Read-Host`) so a command never blocks waiting for a prompt — a hanging prompt stalls the turn until the timeout.
- Note: `-and` is a boolean operator, not a command chaining operator, and `-or-continue` does not exist.

## Useful patterns

```powershell
# Sequential steps. Stop on first failure (pwsh 7).
npm run lint; if ($?) { npm test }

# Inspect a file or directory without dumping too much text.
Get-ChildItem -Recurse src | Select-Object -First 40

# Search text with Select-String.
Select-String -Path src -Pattern "TODO" -Recurse

# Locate paths with fd when available, or Get-ChildItem -Recurse for simple cases.
fd main src

# Summarize repository changes.
git diff --stat; if ($?) { git status --short }

# Create or replace a file (here-string heredoc).
@'
const users = getUsers();
console.log(users);
'@ | Set-Content -Path main.ts

# Edit a file or run any Python — always through uv.
uv run --project .nova python -c "from nova import edit; edit('src/main.ts', 'old', 'new')"
```

## Pitfalls

- Bare `$env:var` split on spaces and special characters. Use `"$env:var"`.
- `Get-ChildItem` without `-Filter` recursing the whole tree is slow on large repos; pass a `-Filter` or narrow the path.
- `cd`/`Set-Location` resets next call. Use the `cwd` param.
- A `Write-Error` inside a command fails the call even if the process exit code would be 0; that is intentional — any error is treated as a failure.
- `Get-Content` treats a path with spaces fine when quoted: `Get-Content "my file.txt"`.