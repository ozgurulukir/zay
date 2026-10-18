# Changelog

All notable changes to Zay are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/ozgurulukir/zay/compare/v0.11.2...HEAD
[0.11.2]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.2