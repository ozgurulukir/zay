Load and read the full instructions for a specialized skill from the available skills list.

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
Only `name` and optional `resource` are accepted; do not use `command` or `description`.

## Rules & Best Practices

- **Load Early:** Call `skill` as soon as you identify that a task matches a specialized skill description.
- **Context Frugality:** Only load skills that are directly relevant to the current task.
- **In-Memory Speed:** Skills are pre-loaded in memory; calling `skill` provides instant access to domain instructions without running external shell commands.
