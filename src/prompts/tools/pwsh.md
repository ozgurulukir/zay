Run a PowerShell command on Windows.

- Set the working directory with the `cwd` parameter (fresh shell per call). `cwd` must be within the project root.
- Pass multiline or complex values via `env: { NAME: "..." }`. Reference them as `"$env:NAME"`.
- `description` is optional; provide it when a concise title adds useful context.
- Quote every expansion: `"$env:var"`, `"$(cmd)"`. Bare `$env:var` splits on spaces and special characters.
- Default timeout is 30 seconds. Raise with `timeout` when a command needs longer; a timed-out result explains how to retry.
- Prefer targeted commands (`rg`, `Select-String`, `git diff --stat`) over dumping large files or full build logs.
- Command outputs exceeding 50 KB or 2000 lines are truncated with a `[Showing last N of M lines (X of Y bytes). Full output: /path]` footer. Inspect that path with `Get-Content` or use a narrower command; never re-run the entire command just to see the tail. When no truncation notice is present, the output is complete.

The `arguments` object's required property is `command` — put the whole
PowerShell command string there. Do NOT use `name`; `name` is not a property of
this tool (that key belongs to the `skill` tool).

## PowerShell idioms & error handling

- Non-zero exit codes are returned in the result. For multi-step commands, chain with `; if ($?) { ... }` or `&&` in pwsh 7.
- Start multi-statement scripts with `$ErrorActionPreference = 'Stop'` so cmdlet failures halt execution immediately.
- Use full-word flags (`-Force`, `-Recurse`). Grouped single-dash flags (`-la`, `-rf`) do not exist.
- Always pass `-Encoding utf8` when writing text with `Set-Content`.
- Use non-interactive flags (`-NoProfile`, redirecting `Read-Host`) so commands never hang waiting for input.
