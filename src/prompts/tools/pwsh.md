Run a PowerShell command in the active workspace.

- `command` is required. `cwd` starts a fresh shell and must stay within the
  allowed project or lane root.
- Pass multiline or complex values through `env: { NAME: "value" }` and use
  `"$env:NAME"` for environment values. Quote expansions.
- Set `timeout` explicitly when 30 seconds is not enough. Use
  `run_in_background: true` for long-running or continuous commands; completion
  is delivered automatically, so do not poll in a loop.
- Prefer targeted reads (`rg`, `Select-String`, `Get-ChildItem`, `Get-Content`)
  over dumping whole files or logs. Use `$ErrorActionPreference = 'Stop'` for
  multi-step scripts, full-word flags, `-Encoding utf8` when writing text, and
  non-interactive options so commands do not wait for input.
- Non-zero exit codes are returned in the result. Report them as failures unless
  the command was intentionally allowed to fail.
- Results over 50 KB or 2000 lines receive a bounded preview and a full-output
  path. Inspect that path or narrow the command; do not rerun the whole output.
  The executor may also save oversized results. If it provides a `result_id`, use
  the `database` tool's `search_tool_result` or `read_tool_result` operation.

The required argument is `command`, not `name`.
