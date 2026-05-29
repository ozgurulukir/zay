Search file contents by regex. Use `grep` to find code or text; use `find` to locate a file by name.

`query` is a regex (invalid regex is an error). Output is `path:line:matching-line`, one per match.

Up to 50 results per call. To get the next page, pass the returned `cursor` with the same `query`.
