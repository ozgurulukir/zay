Regex search across file contents.

<parameters>
- `query` — required. Regex pattern matched inside files.
- `cursor` — optional. Continuation token from a prior `grep` result. Reuse only with the same `query`.
</parameters>

<rules>
- Use `grep` to find definitions, usages, or code text. Use `find` to locate a file by name.
- Output is `path:line:matching line`, one per match.
- Results are limited to 50 per call; pass `cursor` to page.
- Invalid regex is an error.
- When the search index is still starting or unavailable, the tool uses shell fallback and pagination is unavailable.
</rules>

<examples>
- `{ "query": "pub fn runTool" }`
- `{ "query": "TODO\\(.*\\)" }`
</examples>
