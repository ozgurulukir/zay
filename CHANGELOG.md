# Changelog

All notable changes to Zay are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/ozgurulukir/zay/compare/v0.11.3...HEAD
[0.11.3]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.3
[0.11.2]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.2