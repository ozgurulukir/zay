---
name: python-helpers
description: Targeted exact-match string replacement, multi-edit validation, and search helpers for Python environments.
---

# Python Helpers Skill

This skill provides robust Python-based file editing and search routines. When Python is available on the system, you can use these snippets for exact multi-line replacement, validation before write, and visual TUI diff rendering.

---

## 1. Exact-Match File Editor (`edit`)

The `edit` routine reads the target file, verifies that `old_text` exists uniquely (or validates multiple sequential replacements), applies the changes, outputs a unified visual diff using Nova's display sentinels (`\x1enova:diff`), and writes atomically.

### Python Function Definition:

```python
import difflib
import os
import sys

def emit_diff(path: str, old: str, new: str) -> None:
    lines_old = old.splitlines(keepends=True)
    lines_new = new.splitlines(keepends=True)
    diff = difflib.unified_diff(lines_old, lines_new, fromfile=f"a/{path}", tofile=f"b/{path}")
    diff_text = "".join(diff)
    if diff_text:
        # Nova visual diff sentinel (routed to TUI diff panel)
        sys.stdout.write(f"\x1enova:diff\n{diff_text}\x1enova:end\n")
        sys.stdout.flush()

def edit(path: str, old_text: str = None, new_text: str = None, edits: list = None) -> None:
    if not os.path.exists(path):
        raise FileNotFoundError(f"File '{path}' does not exist.")
    
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    operations = edits if edits else [(old_text, new_text)]
    new_content = content

    for old, new in operations:
        count = new_content.count(old)
        if count == 0:
            raise ValueError(f"Target string not found in '{path}':\n{old[:100]}...")
        if count > 1:
            raise ValueError(f"Target string found {count} times in '{path}' (must be unique):\n{old[:100]}...")
        new_content = new_content.replace(old, new, 1)

    emit_diff(path, content, new_content)

    with open(path, "w", encoding="utf-8") as f:
        f.write(new_content)
    print(f"Successfully updated {path}")
```

---

## 2. Invocations

### A. One-Liner Replacement (Linux/macOS Bash)
```bash
python3 -c '
import sys
path, old, new = "src/main.ts", "const x = 1;", "const x = 2;"
with open(path, "r") as f: c = f.read()
if c.count(old) != 1: sys.exit(f"Target text not unique in {path}")
with open(path, "w") as f: f.write(c.replace(old, new, 1))
print(f"Updated {path}")
'
```

### B. One-Liner Replacement (Windows PowerShell)
```powershell
python -c "
import sys
path, old, new = 'src/main.ts', 'const x = 1;', 'const x = 2;'
with open(path, 'r', encoding='utf-8') as f: c = f.read()
if c.count(old) != 1: sys.exit(f'Target text not unique in {path}')
with open(path, 'w', encoding='utf-8') as f: f.write(c.replace(old, new, 1))
print(f'Updated {path}')
"
```

### C. Multi-Edit Temp Script (Complex Refactoring)
For multi-line edits with indentation, write a temporary `.py` script, execute it, and clean up.
