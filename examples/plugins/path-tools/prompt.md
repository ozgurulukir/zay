---
description: Create directories and copy/move/delete paths — sandboxed alternatives to bash cp/mv/rm/mkdir.
---

Use the `path-tools` plugin for directory creation and file/directory
copy/move/delete. These tools are **sandboxed**: every path is validated
against the project root, so traversal outside it is rejected. Prefer them over
`bash cp/mv/rm/mkdir` — those run unclassified in the plugin sandbox and are
not guarded.

## When to use each tool

- `lua__path-tools__create_directory` — Create a directory (and any missing
  parents). Use this before writing files into a new directory.
- `lua__path-tools__copy_path` — Copy a single file. Use this to duplicate a
  file within the project.
- `lua__path-tools__move_path` — Move or rename a file or directory. Doubles
  as rename when only the basename changes.
- `lua__path-tools__delete_path` — Delete a file or directory. Pass
  `recursive=true` to remove a directory tree.

## Guidelines

- **Prefer these over bash.** `cp`, `mv`, `rm`, `mkdir` via bash are not
  classified or guarded in the plugin sandbox. The dedicated tools enforce the
  project-root boundary on every path.
- **Deletion is irreversible.** Before `delete_path`, confirm the target is
  what you intend. Use `read` or `list_directory` to verify. Only pass
  `recursive=true` when you genuinely need to remove a whole tree.
- **Directory copy.** `copy_path` handles single files only. To copy a
  directory tree, use `bash cp -r` (it is a copy, not a destructive op).
- **Create before write.** If you are writing a file into a path whose parent
  directory does not exist, call `create_directory` first — `write_file` does
  not create parent directories.
