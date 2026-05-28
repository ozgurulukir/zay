Fuzzy search for files and directories by path.

<parameters>
- `query` — required. Fuzzy text matched against paths. Not a regex.
- `cursor` — optional. Continuation token from a prior `find` result. Reuse only with the same `query`.
</parameters>

<rules>
- Use `find` to locate a file or area by name or topic. Use `grep` for content searches.
- Output is one path per line. Directories end with `/`.
- Results are limited to 50 per call; pass `cursor` to page.
- When the search index is still starting or unavailable, the tool uses shell fallback and pagination is unavailable.
</rules>

<examples>
- `{ "query": "search codebase" }`
- `{ "query": "tools hashline" }`
</examples>
