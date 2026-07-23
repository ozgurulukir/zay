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
