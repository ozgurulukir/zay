# Changelog

All notable changes to Zay are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.11.7] - 2026-11-01

### Changed
- Bump `vaxis` to `5b0c724` and `uucode` to `9d55524`, incorporating OSC 7501 Program Status Protocol reports, Unicode 18.0.0, and `multi_slice` packed field bugfixes for the Zig 0.16 toolchain.
- The release workflow's `version-check` job fails when the tag lacks its changelog entry, closing tag/changelog drift.
- Docs sync: contributing guide requires behavior-carrying commits to use `fix`/`feat`/`perf` subjects (#289); building guide records the Windows baseline test-suite failure set (#291); reference docs record the 0.11.4-0.11.5 behavior contracts; safety docs describe execution-boundary classification invariants (#288) and the redirect/dot-root/Start-Process scans (#283).

### Fixed
- Windows remote plugin-store installs no longer fail with `ReadFailed`: no-follow opens are async yet mislabeled blocking on Windows, so reads now repair the file flags first, with the workaround guarded against toolchain drift; environmental install errors surface as environment faults instead of package faults (#281).
- Safety classifier: flag `rm`/`dd` root wipes inside substitution, quotes, and unspaced separators; Windows package-manager install verbs; `Remove-Item` alias spellings and forward-slash drive roots; bare separator roots and escaped `rm`/`dd` spellings; close an out-of-bounds drive-letter redirect read (#282).
- Safety classifier: flag force-clobber redirects into critical files (including unspaced and quoted targets), pwsh drive-root targets behind no-op dot components, and `Start-Process` loops as pwsh fork-bomb equivalents (#283).
- TUI: live agents re-arm when the classifier URL is saved in Settings, and classifier-url live-sync failures are contained at turn boundaries (#290).

## [0.11.6] - 2026-10-26

### Added
- MCP tools' original `inputSchema` is preserved losslessly through the pipeline: discovery serializes object-typed raw schemas into `McpTool.raw_input_schema`, registry records deep-copy it so it survives client disconnect/reconnect, and provider serialization borrows the record's copy (#199, #277).
- `rich_schema` mock-server mode serving an `inputSchema` that exercises `$defs`/`$ref`, nested objects, `items`/`prefixItems`, `allOf`/`oneOf`/`anyOf`/`not`, `pattern`/`format`, numeric and length bounds, `const`, and mixed-type enums, with regression coverage across discovery, registry, and provider serialization (#277).

### Changed
- MCP tool `parameters` serialization is dialect-aware: non-strict dialects receive the server's raw schema verbatim (nothing injected, dropped, or rewritten), while strict structured-outputs dialects get the transformed local projection, which never fabricates constraints it cannot model. The local projection remains the best-effort form for UX, coercion, and null normalization; the MCP server stays the validation authority. Builtin and plugin tools serialize exactly as before (#199, #277).

### Fixed
- Close OOM `errdefer` hazards in `McpClient` initialization and tool registration, including a latent hazard in `buildMcpTool` where a failed struct-literal `try` left key fields undefined (#277).

## [0.11.5] - 2026-10-24

### Added
- Unit tests for MCP server stdio environment variable expansion (#263).
- Unit tests for Windows console UTF-8 initialization (#266) and process tree Job Object attachment (#267).
- Error path test coverage for project configuration loading (#271).

### Changed
- Optimize plugin store tree copying: add 4KB buffered reading and unsynced staging writes, avoiding per-file fsync calls during temporary directory copy (#272).
- Optimize test execution: batch session setup and tool result storage in a single SQLite transaction in tool results test (#265).
- Modularize TUI input widget layout and drawing logic into discrete compute and assembly passes (#276).
- Evaluate shipped plugin manifests concurrently in tests with thread-safe `LockedAllocator` (#268).

### Fixed
- Preserve remote URL source identity, resolve local path separators, fix store deduplication, and enforce config memory safety in plugin store (#264).
- Preserve trailing empty lines when slicing AST code blocks in the sitting-duck plugin (#269).
- Harden project config loader: catch and record diagnostics on file stat and read errors rather than propagating unhandled I/O failures on non-regular files (#271).
- Remove unused imports in toast and lane lifecycle components (#273, #275).

## [0.11.4] - 2026-10-21

### Changed
- Optimize compacted session resume (`Session.messages`): probe active branch metadata and newest compaction summary first, transferring payload JSON only for the retained suffix. Reduces payload volume and remote roundtrip transfer for compacted histories (#163, #262).

### Fixed
- Release workflow checksum format: compute SHA-256 checksums from inside the distribution directory so that `.sha256` files record bare basenames rather than paths with `dist/` prefixes, fixing download-side verification (#261).
- Harden session message projection: guard against row-ordering anomalies by verifying `kept_index == 0` on suffix probe or falling back to full branch load; slice retained suffix strictly from `kept_index`; enforce row width and path entry count invariants; eliminate potential memory leak during summary message allocation on OOM (#262).

## [0.11.3] - 2026-10-21

### Added
- `evictHistoryImages` config setting: evict image views from compacted history.

### Changed
- The Lua shell bridge maps an unavailable shell to `ShellUnavailable` instead
  of surfacing it as a generic error.
- The MCP schema parser casts the required count to `u32` explicitly.

### Fixed
- The bash-safety classifier client now bounds its body read with a socket
  timeout (`SO_RCVTIMEO`). The previous fix wrapped the I/O only, but the
  wrapper reads that socket option and falls through when it is unset, so the
  stalled-read panic it targeted could still fire.
- The todo plugin accepts only a plain integer as a trailing `id:N` tag. The
  previous pattern also captured values such as `id:abc` or `id:1,`, which made
  the whole task file fail to load.
- The sitting-duck plugin guards the marker read on the returned values rather
  than wrapping it in `pcall`, matching the todo plugin's idiom.
- The `terminateChildTree` test no longer blocks on a 30 s child before
  reaping it (63 s → 23 ms).
- The config error-path test asserts on the recorded diagnostic, so it observes
  the failure instead of passing for a missing file.
- Documentation for the agent turn handoff, `entry.depth()`, the `isRuntimeBound`
  check, and the turn-teardown ownership.

## [0.11.2] - 2026-10-18

### Added
- MCP mock-server test coverage and HTTP transport fetch tests.
- Agent database tool tests.

### Changed
- Pre-allocate `required_set` capacity in MCP schema parsing (performance).

### Fixed
- Test code aligned with Zig 0.16 APIs (wave 2/4).
- Findings from the open-PR review batch.

## [0.11.1] and earlier

See the [GitHub releases](https://github.com/ozgurulukir/zay/releases) and git
history for prior changes. Older entries are not yet backfilled in this file
(TODO: backfill from release notes).

[Unreleased]: https://github.com/ozgurulukir/zay/compare/v0.11.7...HEAD
[0.11.7]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.7
[0.11.6]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.6
[0.11.5]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.5
[0.11.4]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.4
[0.11.3]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.3
[0.11.2]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.2
