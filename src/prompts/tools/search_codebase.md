Search the codebase for file contents, file paths, or directory paths.

<instructions>
Modes (required): 
- `file_content`: grep-like content search. `query` is a regex pattern searched inside files. Output is `path:line:matching line`. Use this for definitions, usages, and code text.
- `file_names`: fuzzy search over file paths/names. `query` is fuzzy text, not a regex. Use this to find a file by topic or name.
- `directories`: fuzzy search over directory paths/names. `query` is fuzzy text, not a regex. Use this to find where an area/module lives.
</instructions>

<rules>
- Do not use `file_content` to find a file path; use `file_names`.
- Results are limited to 50.
- If output says to pass a `cursor`, call the tool again with the same `mode` and `query` and that exact `cursor`.
- Invalid regex in `file_content` is an error.
- When the search index is still starting or unavailable, the tool uses shell fallback and pagination is unavailable.
</rules>

<examples>
- `{ "mode": "file_content", "query": "pub fn runTool" }`
- `{ "mode": "file_names", "query": "search codebase" }`
- `{ "mode": "directories", "query": "tools hashline" }`
</examples>
