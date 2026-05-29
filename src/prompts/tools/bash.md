Run a shell command.

- Set the working directory with the `cwd` param, not `cd dir && …`.
- Pass values via `env: { NAME: "…" }` (best for multiline or quoted values) and reference them as `$NAME`. Quote expansions like `"$NAME"`.
- Default timeout is 10s; raise it with the `timeout` param (seconds).

Do not inspect or search files with bash — use the dedicated tools instead:
- to read files or list directories: the `read` tool, not shell `cat`/`head`/`tail`/`ls`/`sed`/`awk`.
- to locate files by name: the `find` tool, not shell `find`/`fd`.
- to search file contents: the `grep` tool, not shell `grep`/`rg`.
