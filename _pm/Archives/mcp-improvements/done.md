# done — mcp-improvements

## #6 — Transport test coverage (commit `07124aa`)
- 9 test: parseMessage roundtrip (formatRequest + formatNotification), nested JSON,
  null params, malformed (5 variants), empty/whitespace, trailing newline, >2KB params.
- transport.zig: 3 → 12 tests.

## #2 — syncFromConfigEx reconciliation (commit `9ad2fa7`)
- Stale client removal: servers removed from config are now deinit'd + removed.
- syncFromConfig gains `io` param (needed for subprocess kill on removal).
- syncFromConfigEx simplified: calls syncFromConfig, then connects .connecting clients.
- findClient helper eliminates duplicated linear scans.
- 2 new tests: stale removal, no-reconnect for connected clients.

## #3 — callTool refactor (commit `f01f301`)
- tool_name now escaped via std.json.Stringify.value (was raw concat).
- Single Writer.Allocating instead of 7 appendSlice calls.
- isError: true returns server's error text instead of generic error (MCP spec).
- extractContentText helper: image → [Image content (mime)], resource → [Content type: X].

## #8 — Manager validation (commit `d82f093`)
- command == null AND url == null → .failed with "No command or url configured".
- Duplicate server name in config → skipped with warning.
- 2 new tests: misconfigured server, duplicate name.

## #1 — sendRequest hardening (commit `a428b18`)
- request_mutex (std.Io.Mutex) serializes concurrent requests.
- read_timeout_ms field replaces hardcoded 30_000.
- error.ProcessExited → error.McpServerCrashed (poll HUP path).
- streamDelimiterEnding error.ReadFailed → error.McpServerCrashed.

## #4 — Schema edge cases (commit `f1626e9`)
- New Kind variants: array, number.
- Array serializes with "items":{} in tool definitions.
- enum values appended to description: "Color [enum: red, green, blue]".
- $ref / oneOf / anyOf → string fallback + warning log.
- Both AI adapters updated for new kinds.
- 3 new tests.

## #5 — RAII / ownership (commit `6f9b91c`)
- errdefer c.deinit(io) prevents McpClient leak on append failure.
- ScopedMcp wrapper evaluated and skipped (YAGNI — defer is idiomatic).

## #7 — Error message standardization (commit `42bb4e6`)
- callTool returns JSON-RPC error message as text (not Zig error).
- errorDescription() helper maps Zig errors → human-readable strings.
- Model now reads server error messages instead of cryptic error names.

## #9 — Token cost / collision detection (commit `8a13f60`)
- buildMcpToolSchemas deduplicates by full_name (first writer wins + warning).
- serverSummary() method for system prompt context.

## #10 — Graceful shutdown (commit `b857e07`)
- stop() sends SIGTERM before SIGKILL.
- McpManager.disconnectClient: stop + clear tools + disabled.
- TUI /mcp 'd' key binding for disconnect.
- Bug fix: poll POLLIN+HUP race — don't crash when buffered data exists.
