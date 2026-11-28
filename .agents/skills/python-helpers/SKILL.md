---
name: python-helpers
description: Use when editing files via Python in shell commands and you need unique-target validation, atomic writes, and Zay visual diff sentinels.
---

# Python Helpers

Use these Python snippets when editing files through shell commands: they verify that each target string matches uniquely before writing, emit Zay visual diff sentinels (`\x1ezay:diff` / `\x1ezay:end`), and write atomically via a temporary file in the target directory.

## 1. Atomic exact-match editor (`edit`)

```python
import difflib
import os
import sys
import tempfile

def emit_diff(path: str, old: str, new: str) -> None:
    diff_text = "".join(
        difflib.unified_diff(
            old.splitlines(keepends=True),
            new.splitlines(keepends=True),
            fromfile=f"a/{path}",
            tofile=f"b/{path}",
        )
    )
    if diff_text:
        sys.stdout.write(f"\x1ezay:diff\n{diff_text}\x1ezay:end\n")
        sys.stdout.flush()

def atomic_write(path: str, content: str) -> None:
    abs_path = os.path.abspath(path)
    parent = os.path.dirname(abs_path)
    mode = os.stat(abs_path).st_mode & 0o777
    fd, tmp_path = tempfile.mkstemp(dir=parent, prefix=".edit-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(tmp_path, mode)
        os.replace(tmp_path, abs_path)
    except BaseException:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise

def edit(path: str, old_text: str | None = None, new_text: str | None = None, edits: list[tuple[str, str]] | None = None) -> None:
    if not os.path.exists(path):
        raise FileNotFoundError(f"File '{path}' does not exist.")
    if edits is None:
        if old_text is None or new_text is None:
            raise ValueError("Provide either (old_text, new_text) or edits.")
        operations = [(old_text, new_text)]
    else:
        operations = edits

    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    new_content = content
    for old, new in operations:
        count = new_content.count(old)
        if count == 0:
            raise ValueError(f"Target string not found in '{path}':\n{old[:100]}...")
        if count > 1:
            raise ValueError(f"Target string found {count} times in '{path}' (must be unique):\n{old[:100]}...")
        new_content = new_content.replace(old, new, 1)

    emit_diff(path, content, new_content)
    atomic_write(path, new_content)
    print(f"Successfully updated {path}")
```

## 2. Quick one-liners

### POSIX Bash

```bash
python3 -c '
import sys
path, old, new = "src/main.zig", "old_line", "new_line"
with open(path, "r", encoding="utf-8") as f: c = f.read()
if c.count(old) != 1: sys.exit(f"Target text not unique in {path}")
with open(path, "w", encoding="utf-8") as f: f.write(c.replace(old, new, 1))
print(f"Updated {path}")
'
```

### Windows PowerShell

```powershell
python -c "
import sys
path, old, new = 'src/main.zig', 'old_line', 'new_line'
with open(path, 'r', encoding='utf-8') as f: c = f.read()
if c.count(old) != 1: sys.exit(f'Target text not unique in {path}')
with open(path, 'w', encoding='utf-8') as f: f.write(c.replace(old, new, 1))
print(f'Updated {path}')
"
```

For multi-line indented edits, write a temporary `.py` script, execute it, and delete the script after verification.
