# Nova Architecture

## Agent Tools

Nova exposes the following tools:

- `read`
- `write_file`
- `edit_file`
- `search_codebase`
- `bash`

`read` emits content-hash anchors (`LINE+HASH|TEXT`) that `edit_file` consumes in hashline patch documents.

`search_codebase` is reserved for a future code-search implementation.

`bash` works as a plain shell executor and does not intercept Nova-specific commands.
