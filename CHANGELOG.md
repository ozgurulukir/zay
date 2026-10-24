# Changelog

All notable changes to Zay are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/ozgurulukir/zay/compare/v0.11.5...HEAD
[0.11.5]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.5
[0.11.4]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.4
[0.11.3]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.3
[0.11.2]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.2
