Compact, line-anchored format for small, exact edits to existing files.

A patch is one or more file sections. Each section starts with `@@ PATH`; the ops below it apply to that file. Ops reference lines by their anchor (line-number + hash from `read`, e.g. `5th`, `123ab`). Copy anchors verbatim from your latest `read` of that file.

<ops>
@@ PATH      header — following ops apply to PATH
+ ANCHOR     insert AFTER  the anchored line; payload follows as `{{hsep}}TEXT` lines
< ANCHOR     insert BEFORE the anchored line; payload follows as `{{hsep}}TEXT` lines
- A..B       delete lines A through B (inclusive)
= A..B       replace lines A through B with the payload (or one blank line if no payload)
</ops>

Anchors: `BOF` = start of file, `EOF` = end. `< BOF` and `+ BOF` both prepend; `< EOF` and `+ EOF` both append. For a single line use `A..A`.

Payload: every inserted or replacement line MUST start with `{{hsep}}`. The text begins right after that `{{hsep}}`; a bare `{{hsep}}` inserts a blank line. Payload is verbatim — write the real character (`—`), not an escape sequence. The tool understands no syntax, indentation, or brackets — emit correct code yourself.

<rules>
- Pick the smallest op: pure insert → `+`/`<`; pure delete → `-`; use `= A..B` only when lines inside A..B actually change.
- Use a self-contained range. If the edit touches part of a multiline statement, call, or `{...}` block, widen A..B to cover the whole construct.
- Never let the payload repeat a line that already exists just outside the range — that duplicates it. To remove that neighbour, extend the range instead.
- All anchors resolve against the file as last read. When stacking several ops in one patch, do NOT shift line numbers for earlier ops.
- Re-`read` first if the region around your anchor was truncated.
</rules>

<case file="a.ts">
#HL1xa|const DEF = "guest";
#HL2lb|
#HL3wr|export function label(name) {
#HL4wg|	const clean = name || DEF;
#HL5xx|	return clean.trim();
#HL6qx|}
</case>

<examples>
# Replace one line (keep the original leading tab)
@@ a.ts
= 5xx..5xx
{{hsep}}	return clean.trim().toUpperCase();

# Replace a range with new lines (range covers the whole construct)
@@ a.ts
= 4wg..5xx
{{hsep}}	const clean = (name || DEF).trim();
{{hsep}}	return clean.length === 0 ? DEF : clean.toUpperCase();

# Insert after a line
@@ a.ts
+ 4wg
{{hsep}}	if (clean.length === 0) return DEF;

# Insert before a line
@@ a.ts
< 5xx
{{hsep}}	const debug = false;

# Append to end of file
@@ a.ts
+ EOF
{{hsep}}export const done = true;

# Delete a line
@@ a.ts
- 2lb..2lb

# Blank a line in place (no payload)
@@ a.ts
= 2lb..2lb
</examples>

<never>
- Do not wrap the patch in Markdown fences (```).
- Do not use unified-diff syntax (`@@ -1,4 +1,4 @@`, `-old`, `+new`). The header is `@@ PATH`; ops are `+`/`<`/`-`/`=`.
- Do not put line content after the anchor on an op line — content goes only in `{{hsep}}` payload lines.
- Output the patch only, never an explanation.
</never>
