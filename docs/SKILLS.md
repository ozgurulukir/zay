# Skills

Skills are instruction files loaded at startup and injected into the system prompt; the model loads one via the `skill` tool, or the user invokes it inline with `$name`. Zay follows the agent-skills convention so a skill that works here also works in other agents (Claude, Codex, Cursor).

## Layout

- Standard form: `<name>/SKILL.md` — the directory name should match the frontmatter `name`.
- Roots: global `<home>/.agents/skills` and project `<cwd>/.agents/skills`; a project skill shadows a same-name global skill (remaining collisions: first wins, warned).
- A loose root `*.md` file also loads (the file stem becomes the name), but this is **non-standard** — other agents ignore loose files, so `zay --strict` flags them. Prefer `<name>/SKILL.md`.

## Frontmatter

| Field | Rules |
|-------|-------|
| `name` | Optional for loose files. Charset `[a-z0-9]+(-[a-z0-9]+)*` — lowercase letters, digits, single hyphens, no leading/trailing hyphen; max 64 bytes. For `SKILL.md` it should match the parent directory (case-insensitive); a mismatch loads but warns. |
| `description` | Required. Max 1024 bytes. This is what the model matches tasks against. |
| `disable-model-invocation` | `true` hides the skill from the model's prompt (user-only `$name` invocation). |

Unsupported YAML shapes are rejected: block scalars (`\|`, `>`) and quoted values whose closing quote is missing on the same physical line (they would silently truncate, so they fail loudly instead).

## Errors

An invalid skill is skipped with a log warning; it never aborts loading. Reasons: `InvalidSkillName`, `MissingDescription`, `DescriptionTooLong`, `BlockScalarUnsupported`, `FileTooBig` (256 KB cap).

## Strict scan

`zay --strict` scans both roots with the production loader, prints one line per violation plus a summary to stdout, and exits non-zero when any skill failed to load or a loose root `.md` was found. The TUI never starts, so it doubles as a CI lint for a repo's `.agents/skills` tree.

## Invocation

- `$name` in a prompt injects the skill body into that message (deduplicated, case-insensitive; a 256 KB per-turn budget applies).
- The model calls the `skill` tool with `{"name": "…"}` when the task matches a description.
- On resume, previously injected skills are re-derived from the persisted transcript.
