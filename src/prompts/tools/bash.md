Run a shell command.

- Set the working directory with the `cwd` param, not `cd dir && ...` because each call starts a fresh shell.
- Pass values via `env: { NAME: "..." }` for multiline or complex values. Reference them as `"$NAME"`.
- Quote every expansion: `"$var"`, `"$(cmd)"`, `"${arr[@]}"`.
- Default timeout is 10 seconds. Raise it with the `timeout` parameter when a command needs longer.
- Prefer targeted commands (`rg`, `find`, `git diff --stat`, `head`, `tail`) over dumping large files or full build logs.
- Bash output may be truncated. If output is truncated, use the reported full-output path to read the rest or rerun with a narrower command.

## Error handling

- A non-zero exit code is returned in the result. For multi-step commands, chain with `&&` or start scripts with `set -euo pipefail`.
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

# Patch a small section of a file.
python3 - <<'PY'
from pathlib import Path
path = Path('src/main.ts')
text = path.read_text()
path.write_text(text.replace('old', 'new', 1))
PY
```

## Pitfalls

- `$var` unquoted splits on spaces and glob characters. Use `"$var"`.
- `if [ -n $var ]` breaks when `$var` is empty. Use `if [ -n "$var" ]`.
- `for f in $(ls *.rs)` breaks on spaces and newlines. Use shell globs or a small Python script.
- `cd dir && cmd` resets next call. Use the `cwd` param.
- `cmd 2>&1 > file` only sends stdout to the file. Use `cmd > file 2>&1`.
