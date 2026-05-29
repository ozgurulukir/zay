Find files and directories by fuzzy path match. Use `find` to locate something by name; use `grep` to search file contents.

`query` is fuzzy text, not a regex. Output is one path per line; directories end with `/`.

Up to 50 results per call. To get the next page, pass the returned `cursor` with the same `query`.
