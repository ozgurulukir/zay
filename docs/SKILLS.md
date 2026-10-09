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

- `$name` injects the skill body on its first activation in the active conversation branch (case-insensitive; a 256 KB per-turn inline budget applies). Later mentions keep the user prompt without injecting the body again.
- The model calls the `skill` tool with `{"name": "…"}` when the task matches a description.
- References and other text resources can be read with `{"name":"…","resource":"references/rubric.md"}`.
  The path is relative to that discovered skill's directory, including global
  skills outside the workspace. Reads accept regular files and are limited to
  256 KiB of UTF-8 text;
  absolute paths, parent traversal, and symlinks escaping the skill directory
  are rejected. Resource reads do not activate or replace retained instructions.
- Bundled scripts run with `{"name":"…","command":"python3 scripts/check.py","timeout":120}`.
  Commands start in the registered skill directory, including global skills outside
  the workspace, using bash on POSIX and PowerShell on Windows. `ZAY_WORKSPACE_CWD`
  exposes the current lane/session workspace without changing the agent's cwd.
  Normal shell safety classification/approval, cancellation, capture limits, and
  timeout handling apply (default 30 seconds, range 1–3600). Shell location changes
  are guarded against leaving the skill root; this is defense in depth, not an OS
  sandbox. Commands may read/write files just as ordinary shell commands do.
  `command` and `resource` are mutually exclusive; `timeout` requires `command`.
  Command results never activate skills or replace retained instructions.
- Successful model `skill` calls register the same activation. Repeated calls still receive a protocol result, with a short already-loaded notice.
- Full activated instructions survive ordinary tool-result pruning, compaction, branch reload, and resume, even when the original skill file is missing. The first admitted body wins; changing a file does not replace an active body.
- Branch-scoped `skill_context` session entries store owned bodies. Old sessions recover complete generated inline blocks and successful results correlated with explicit `skill` calls; ambiguous or incomplete history is ignored.
- Each branch can retain at most 256 skills and 1 MiB of instruction bytes, with a 256 KiB per-body limit. Capacity errors reject new activation without evicting existing instructions.
