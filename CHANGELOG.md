# Changelog

All notable changes to Zay are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- Lua: route sandboxed-state teardown through `destroySandboxedState` (#360) and own the teardown path plus the budget API boundary (#356); rename `freeHookData` to `capFinalizerDeadline` to say what it does (#351).
- Executor: own the ToolResult history move/free split (#359).
- TUI: dedupe settings pending-state helpers into `settings_lifecycle` (#358); centralize the mode text-input activation predicate (#354); dedupe single-line form editors into `FormField` (#353).
- Config: extract database backend vocabulary into a leaf module (#355).
- Tools: funnel plugin record release through `freePluginRecord` (#352).

### Fixed
- TUI: commit the settings text edit on Enter; `submitMode` now owns every Enter press (#357).

## [0.11.10] - 2026-11-08

### Changed
- Agent: centralize tool-batch executor wiring in Agent.toolExecutor (#348); extract the turn-finalization decision table from Agent.run (#345); retry once when finish_reason=tool_calls arrives with no tool call (#329).
- Context: split assembly.zig into rules and prune modules (#349).
- Config: plant resumed model slices in the App config arena (#347); hand the loader arena to the App and stop cloning cached config (#346).
- Tools: table-drive the local shell-safety rules (#350); make todo_prioritize.priority required to match the documented contract; correct plugin tool teaching descriptions and schemas (#338).
- AI: re-home tool-call argument hygiene into a cross-dialect leaf (#342); harden the tool-call lifecycle across wire schemas, streaming, and recovery (#332); recover the <function=NAME> text tool-call variant (#330).
- Lua: derive event-name validity from the Event tag set and delete the dead Plugin module (#343); harden the plugin bridge architecture against stack corruption and data races (#339).
- Executor: check cancelation in batch runAll and unify tool display lookup (#331).

## [0.11.9] - 2026-11-05

### Fixed
- Auth/config: dynamic-provider API keys survive config re-apply, custom `baseUrl` and the fallback system prompt serialize from model selection, and the cold-start system prompt is restored (#323).
- Runtime/config: the agent database arms from the canonical config, and the fail-soft config loader hardens its fallback paths (#324).
- Config memory safety: partial-clone leaks and double-free hazards eliminated across providers and transports; MCP transport leaks plugged and slice reallocations secured; validation-diagnostic leaks on append failure fixed and the full schema check completed (#325).
- Config load: the merge phase runs on a `LoadResult`-owned arena, releasing the whole merged tree in one shot and structurally removing the clone-before-free ordering hazards the last six patches patched one by one (#326).

### Changed
- Lua: the no-op `rebindPluginToolKey` shim is deleted; the manager indirection it marked no longer exists and it had zero callers (#327).

## [0.11.8] - 2026-11-04

### Changed
- Mode transitions route through a single `App.setMode` entry with explicit follow-up duties: focus resync when a per-mode key handler closes its mode, draft retention, and drain hand-off; the ConPTY smoke harness is promoted into repo tooling with focus scenarios (#292, #317).
- Architecture-review sync: shared subsystems arm through one agent attach seam and the reasoning-effort vocabulary moves to an `ai` leaf module (#299, #300); diff-key routing relocates with the lane-birth tail unified (#293); the mode runtime boundary gets a single classifier home (#292); the classify-before-run shell contract is enforced in code (#295); the mid-level session writer constructor is published with single-sourced store mapping (#297); plugin manifests load through one reader pinning the id/name law (#294); Win32 Job-Object FFI declarations consolidate in `os.zig` (#296); slop-audit leftovers swept (dead symbols, a substring counter, honest test names) (#305).
- Plugin Lua shell bridge: classify and spawn fuse into one path (#315).
- Docs sync: TUI field-privacy facade premise corrected (#298); patterns docs corrected from review (#301, #302); session docs name the de-duplicated backend-mapping sites.

### Fixed
- Windows: DB connect refusals surface as `ConnectionRefused` in `http_transport` instead of the raw Windows NTSTATUS `error.Unexpected`, normalizing remote-session connect errors across platforms (#322).
- Config: unknown reasoning-effort values warn instead of silently degrading (#304); config-apply failures surface instead of being swallowed (#303); the reasoning-effort cross-check names the drifted schema key (#302).
- TUI: manual MCP-sync toasts no longer double into the warn sink (#316); blocked-shell warnings read as toast copy (#315); focus lands on the primary input when the diff viewer closes.
- Safety: the skill command path is gated in code, not prose (#305).
- Tests: the Windows baseline failure set is cleared; the suite runs with zero expected failures (#287, #321).

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

[Unreleased]: https://github.com/ozgurulukir/zay/compare/v0.11.10...HEAD
[0.11.10]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.10
[0.11.9]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.9
[0.11.8]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.8
[0.11.7]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.7
[0.11.6]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.6
[0.11.5]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.5
[0.11.4]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.4
[0.11.3]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.3
[0.11.2]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.2
