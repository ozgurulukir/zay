# Layered preferences with project-local override

Nova resolves its `Config` by field-merging four layered sources — built-in defaults, global `~/.nova/config.json`, project-local `./.nova/config.json`, then env vars — with later layers overriding earlier. The TUI's provider/model picker writes only to the global file (commit-only, inline atomic write); the project-local file is read-only from Nova's perspective, so a `.nova/config.json` checked into a repo pins team-wide defaults that survive interactive edits. `model` is field-merged as an indivisible unit because `reasoningEffort` is meaningful only relative to a specific model id, and `api_key` is excluded from the schema so committed project files never carry secrets.

## Considered Options

- Whole-file replacement when a higher layer is present (rejected — forces every project file to restate global fields).
- Field-merge including inside the `model` block (rejected — `reasoningEffort` set globally would silently apply to a different `model.id` pinned locally).
- TUI writes to whichever file was loaded as the active layer (rejected — would clobber the committed project file in a teammate's checkout).
- Include `api_key` in `config.json` (rejected — defeats the "safe to commit" property of project-local files).

## Consequences

Project files cannot be edited through the TUI; users wanting to change a pinned project default edit the file directly. A user whose change in the TUI is shadowed by a project pin will see their global write succeed but the effective value not change — accepted as the price of immutable team-committed config. Power users still have full coverage via env vars, which override every layer.
