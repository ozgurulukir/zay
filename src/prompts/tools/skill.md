Load instructions, read text resources, or run bundled scripts for a specialized skill from the available skills list.

## Calling the tool

Pass `name` naming the skill to load:

```json
{"name": "tigerstyle"}
```

To read a reference, script, or other text resource inside a discovered skill:

```json
{"name": "pr-review", "resource": "references/review-rubric.md"}
```

`resource` is relative to the registered skill directory, read-only, and limited
to 256 KiB of UTF-8 text. Absolute paths and paths escaping that directory are
rejected. Resource reads do not activate or replace the skill instructions.

To execute a script with its working directory set to the registered skill directory:

```json
{"name":"my-skill","command":"python3 scripts/check.py","timeout":120}
```

`command` uses bash on Linux/macOS or PowerShell on Windows. Use the interpreter
required by the skill, quote arguments normally, and use paths relative to the
skill directory. Global skill directories outside the workspace are supported.
`ZAY_WORKSPACE_CWD` contains the current lane/session workspace path; pass it
explicitly when a script needs project files. The agent's workspace is unchanged.
Commands use normal shell safety classification and approval, cancellation,
output limits, and a 30-second timeout by default (1–3600 seconds allowed).
Shell location changes outside the skill root are guarded, as for contained
workspace commands; this is not an OS sandbox. Script side effects need the same
care as ordinary shell commands.

`resource` and `command` are mutually exclusive. `timeout` requires `command`.
Resource reads and command results do not activate or replace retained instructions.

## Rules & Best Practices

- **Load Early:** Call `skill` as soon as you identify that a task matches a specialized skill description.
- **Context Frugality:** Only load skills that are directly relevant to the current task.
- **Instructions:** Omit `resource` and `command` to load the cached instructions. Load them before running the skill's scripts.
