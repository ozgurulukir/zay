Load and read the full instructions for a specialized skill from the available skills list.

## Calling the tool

Pass `name` naming the skill to load:

```json
{"name": "tigerstyle"}
```

The `arguments` object must contain exactly one property: `name`. Do NOT use
`command`, `description`, or any other key — the tool rejects them.

## Rules & Best Practices

- **Load Early:** Call `skill` as soon as you identify that a task matches a specialized skill description.
- **Context Frugality:** Only load skills that are directly relevant to the current task.
- **In-Memory Speed:** Skills are pre-loaded in memory; calling `skill` provides instant access to domain instructions without running external shell commands.
