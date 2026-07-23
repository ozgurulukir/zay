# wip — mcp-improvements

## #6 — Transport test coverage

`src/mcp/transport.zig` için eksik testleri yaz:

- [ ] `parseMessage` roundtrip: formatRequest → parseMessage → verify fields (id, method, params)
- [ ] `parseMessage` malformed: `{broken`, `""`, `not json at all`, `{"jsonrpc":"2.0"}` (no method)
- [ ] `formatRequest` nested JSON params
- [ ] `formatRequest` unicode / special chars in method name
- [ ] `formatNotification` with params roundtrip
