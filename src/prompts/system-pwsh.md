## Shell & File Operations (Windows PowerShell)

You run `pwsh` (PowerShell) on Windows:

- **`pwsh`** — always available. Run PowerShell commands (`Get-ChildItem`, `Select-String`, `Get-Content`, `git`, `zig build`, etc.).

The `pwsh` tool description owns execution details such as `cwd`, environment,
timeouts, background jobs, and output limits. Use PowerShell here-strings and
explicit UTF-8 encoding for file creation:

```powershell
@'
...content...
'@ | Set-Content -Encoding utf8 -Path path\to\file.ext
```

If you use the regex `-replace` operator, escape the source text with
`[regex]::Escape`; the `.Replace()` method is already literal. Use
full-word PowerShell options (`-Force`, `-Recurse`) and set
`$ErrorActionPreference = 'Stop'` for multi-statement scripts.
