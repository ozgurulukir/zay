# Changelog

All notable changes to Zay are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.11.15] - 2026-11-19

### Fixed
- TUI: transcript paging — PageUp/PageDown/Home/End jump support added, and toggle-all transcript folding (#461); mouse wheel over pickers and overlays, clickable permission buttons, click-to-dismiss overlays, and the new-output jump pill (#462); rich tool approval options (approve once, session whitelist with destructive-command protection, reject, reject-with-reason feedback) (#470).
- Responsive layout: input box capped at 40% of terminal height on tall screens so large pastes cannot starve transcript panes; responsive overlay sizing and list pickers that grow on tall terminals; drawn overlay height tracked during frame draw for help scroll clamping; single-line warning surface below minimum usable dimensions (#463).
- Key bindings/hints: single source of truth for key bindings, hints, and help; width-aware hint line formatting keeps critical escape affordances visible on narrow terminals (#464); ranked fuzzy scoring (fzy) integrated into panel widgets and command/theme pickers so name hits outrank descriptions (#465).
- Markdown/theming: OSC 8 URI sanitization for markdown links and bare URLs; code tokenizer fix and schema corrections; builtin light themes (Catppuccin Latte, Tokyo Night Day) with WCAG contrast >= 4.5:1; luminance classification; terminal background color query via OSC; auto theme adjusts dynamically via color_scheme and color_report events (#466, #467).
- Terminal title/status bar: owned terminal title stored before setTitle; title control bytes sanitized; segment gap_before honored; prioritized status bar segments (critical/high/medium/low) with progressive layout pruning; dynamic window title `zay — <session> [lane n/m] (<state>)` with debounced OSC setTitle; terminal focus tracking with focus_in/focus_out and system notifications when turns complete or require approval while unfocused (#468, #469).
- Config/render: settings dirty tracking fixed; notice/success row metrics corrected; animations schema added with AnimationsMode (full/reduced/off); monochrome/colourblind non-color status markers; periodic redraw ticks suspended when idle (#463 settings/config portion).
## [0.11.14] - 2026-11-19

### Fixed
- Config: `strict_outputs` is no longer dropped when a layer also carries a hand-built `model_selection` (#447); an exported-but-empty `OPENAI_BASE_URL`/`OPENAI_API_KEY` stays absent instead of clobbering file-configured values, and an unrecognized `ZAY_*` boolean reports a diagnostic instead of silently flipping a config-set field (#447); MCP and plugin overlays honor an explicitly disabled entry and a lower layer's `request_timeout_ms` instead of letting parse defaults overwrite them (#447); `TuiSettings` and `CompactionSettings` knobs set to their default value survive a save-and-reload round trip (#447); global and project config writes retry on a concurrent rewrite and fail with `ConfigChangedOnDisk` rather than clobbering, and a config path that is not a regular file records a diagnostic (#447).
- DB: the D1 and service backends no longer send the bearer token to a non-loopback plain-`http` endpoint or to a URL carrying embedded credentials (#445); a remote-controlled `changes` integer outside `i32` fails with `InvalidResponse` instead of panicking in `@intCast`, and non-finite floats are rejected instead of serializing literal `nan`/`inf` into JSON (#445); session branch walks carry a depth cap and report `CycleDetected` instead of recursing forever on a parent cycle (#446); local entry inserts, leaf updates, and `deleteSession` share one transaction so a mid-write failure cannot split them (#446); `list`/`findLatest` fall back to the project's normalized cwd so sessions match across cwd spellings (#446).
- MCP: the stdio read deadline now covers the whole JSON line, so a server that writes a partial line and stalls no longer wedges the request — and every request queued behind it (#450); response ids are checked on stdio and HTTP-JSON bodies, so a server-initiated request is answered with `method not found` and a late response for an earlier timed-out call is dropped instead of misattributed (#450); `listTools` follows `nextCursor` and concatenates pages (capped at 100) instead of returning only the first page (#450); non-matching SSE notifications are bounded in aggregate, failing with `McpStreamTooLarge` instead of accumulating without limit (#450); `stop()` takes the lifecycle lock before reading the child, ending an unsynchronized union-tag read and a double reap that panicked in std (#450); `releaseClient` closes pipes parked in `pending_close`, and a failed stdio stop escalates SIGTERM to SIGKILL on a bounded schedule instead of waiting indefinitely (#450); float and bool enum entries in a tool schema now reach `enum_values` instead of nulling the whole hint (#450).
- Tools: the contained-workspace `cd` guard now sees through quoted and backslash-escaped builtin spellings such as `'builtin'`, `"builtin"`, and `\builtin` (#439); module-qualified PowerShell `Set-Location`/`Push-Location`/`Pop-Location` match on either path separator, case-insensitively, and through backtick escapes (#439); a child that closes both pipes but keeps running no longer parks the shell pipeline forever — the post-EOF wait is deadline-bounded and still leaves the reap in one place (#440); the login-env cache is mutex-guarded so concurrent first callers converge on one login shell instead of each spawning one (#440); shell spill logs and pwsh script temp files are created `0600` (#440).
- Lua/Skills: `require` and the plugin entrypoint load in text mode, so a precompiled bytecode chunk in a plugin directory fails the load instead of executing attacker-chosen bytecode, and `requireModule` re-probes the resolved realpath against the plugin dir to deny a symlink escape (#448); search walks and `list_dir` consult the dispatch budget so a large tree cannot run past it, and `list_dir` reports iteration errors instead of passing a partial listing off as complete (#448); a new enforced `allow_env` permission limits `zay.get_env` to a fixed safe set unless granted (#448); remote catalog entries must carry `sha256` and `size` at parse time and are re-verified before load (#448); a circular `zay.require` returns `nil` plus a message instead of leaking the boolean sentinel as the module value (#449); `formatForPrompt` omits only the plugin that does not fit rather than pinning the cumulative budget to the 64 KB cap (#449); `search_files`/`find_files` set `truncated` on their error paths, and `callToolHandler` rejects an out-of-range `handler_ref` instead of panicking in `@intCast` (#449).
- TUI: abandoning the focused lane now re-points the app thread at a surviving neighbor before the removal, closing a deterministic use-after-free on the next `liveRuntime()` deref, and pins vxfw focus to root when the survivor is runtime-less (#444); `/clear`, `/new`, and `/resume` free the retired transcript rows in place instead of growing an unread append-only list until exit (#444); one failing agent event no longer leaks the rest of the batch, and a refused tick cannot wedge the drain loop (#444).
- AI/Auth: the Responses request omits `tool_choice` when `tools_json` is empty, matching the chat-completions gate (#441); the models probe, models.dev registry fetch, and codex token exchange now apply a socket timeout, and the codex token response body is capped at 1 MiB (#441); `codex_responses.Client.init` reports `MissingAccountId`/`MissingSessionId`/`MissingSystemPrompt` instead of relying on ReleaseFast no-op asserts (#441); `auth.json` is written via a unique temp sibling plus fsync and rename, so a crash mid-write cannot destroy the only credential store, and every save narrows an older build's wider mode to `0600` (#442); a failed keyring save deletes the stale keychain entry before falling back to the file so it cannot shadow the fresh bytes (#442).
- Runtime: a background `Job` is pinned for the duration of its out-of-mutex kill, so a reaper cannot free it while a killer holds the raw pointer, and a spawn arriving after teardown began is refused with `error.ShuttingDown` and cleaned up (#438); the executor keeps a UTF-8-safe truncated prefix of the retrieval footer when the footer alone exceeds the tool-output cap (#443); `injectRecoveredToolCalls` frees the recovered strings when the content-block realloc fails (#443).
- Build/Release: `install.sh` resolves the checksum tool up front and fails closed when verification is impossible or fails (`ZAY_SKIP_CHECKSUM=1` is the explicit opt-out) instead of printing "Checksum verified." after skipping the check (#451); `install.ps1` no longer swallows a checksum mismatch as "verification skipped" and still installs the binary (#451); the offline registry seed `api.json` is published as a release asset and installed to `<install-root>/share/zay/api.json`, so offline first runs can resolve models (#451); the CI fmt gate now covers `lib/`, `tools/`, and `bench/` (#451).

## [0.11.13] - 2026-11-17

### Added
- Config: `database.timeoutSeconds` (default 30s, accepted 1..300s) lets remote session stores (`zay_service`, `turso_http`, `d1_http`) use a configurable request timeout for startup migrations and session operations instead of a fixed one.
- Config: `context.maxRetries` (0..10) and `context.retryBaseDelayMs` (0..8000) expose the transient 429/5xx retry policy, and `request_timeout_seconds` / `max_retries` / `retry_base_delay_ms` now reach every adapter (`.chat`, `.responses`, `.codex`), so Responses and Codex honor `ContextSettings` like the chat path.

### Fixed
- Config: MCP SSE header names and values are validated, `{env:VAR}` expansions included, rejecting CR/LF header injection (#405); `config.json` is written `0600` so plaintext `database.authToken` values are not world-readable (#406); malformed MCP transports, `responsePolicy` blocks, and wrong-typed section keys become per-entry diagnostics instead of discarding the whole config layer (#407).
- DB: authenticated GETs no longer follow redirects, so `Authorization: Bearer ...` cannot leak to cross-domain or downgraded targets (#408); the loopback check parses IPv4, so `127.<attacker-domain>` no longer passes as loopback and sends the token in cleartext (#409).
- MCP: client-list access is synchronized and in-flight requests are counted under lock, closing a retire use-after-free (#410); SSE and stdio line buffers are bounded, failing with `McpStreamTooLarge` (#412); crashed or expired sessions transition to `failed` and re-`initialize` once instead of staying wedged as connected (#411); a transport or timeout edit retires and recreates the client, correlated by a generation counter so a stale connect cannot install into a recreated client (#413); an image `mimeType` that overflows its label buffer falls back to `[Image content]` instead of aborting the tool call (#414).
- Lua/Skills: `sanitizePath` walks up to the deepest existing ancestor, so a symlink escape cannot be reached through a nonexistent leaf (#415); Lua-supplied `i64` values are clamped to `u32` before `@intCast` in the file, git, shell, and search bridges (#416); `plugin.get_config`, `os.remove`, and `os.rename` register as guarded functions, and skill recursion is bounded by depth (#417).
- Tools: `builtin`/`command`-prefixed `cd`/`pushd`/`popd` and module-qualified PowerShell `Set-Location`/`Push-Location`/`Pop-Location` are rejected at the containment boundary (#418, #421); the bash safety classifier unescapes backslashes, matches `rm` force flags case-insensitively, and stream-scans instead of truncating at 4096 bytes (#419); the shell result cache key includes `cwd` and canonicalized `env`, so identical commands in different directories no longer collide (#420).
- AI/Auth/Models: the SSE line reader is bounded during reads instead of after buffering an unterminated line (#422); pruned API key bytes are zeroed before free, `limit.context` is clamped before `@intCast`, and OpenRouter `effort` resolves through the shared effort-label map (#423); Responses-endpoint attach resolves the stored `auth.json` key like the chat path (#427).
- Runtime/TUI: the tool-result quota fast path sums `byte_length` instead of `created_at_ms`, so pruning stays under quota (#424); `emitToolDelta` frees owned name and arguments on OOM without a double-free, and the dead `Job.reported` flag is gone (#425); lane context capture is deferred to the paths that need it, ending duplicate transcript churn on async-worktree poll ticks (#426); PNG and JPEG dimensions are validated in `u64` against a 100 MP cap (#428); `RequestLimiter` wakes newly available waiters when permits increase (#429); the release workflow passes `github.ref_name` through an env var and pins all actions to commit SHAs (#429).

## [0.11.12] - 2026-11-16

### Changed
- Lua: replace the threadlocal dispatch slots with a typed `DispatchCtx` plumbed to the bridge (#404).
- Agent: drop tool-batch binding reflection in favor of explicit assertions (#403).

### Fixed
- Executor/agent/TUI: prevent stalls in tool execution and task continuation — concurrent worker races on the tool-batch produce path, `ResultFooterTooLarge` aborts on oversized preview footers, partial-allocation double-free in `emitToolCallFinished`, a missing assistant message when continuing on length cuts with no wire prose, and lane await now resurfaces stall warnings on subsequent stall windows (#402).

## [0.11.11] - 2026-11-15

### Changed
- Agent/MCP decomposition (#367): Agent and McpClient spokes are extracted behind stable seams — workspace scoping (#381), per-turn continuation policy (`turn_budget.zig`) (#383), MCP discovery cache (#387), agent wire-stream context (#388), runtime connection/attach (#389), MCP stdio and HTTP wire families (`mcp/wire.zig`) (#391, #392), the tool-batch seam (#393), queue operations (#394), text tool-call recovery (#395), skill-context ops (#396), MCP client lifecycle (#397), MCP session protocol (#398), runtime session init and prompt refresh (#399), the agent run loop (#400), and message/compaction ops (#401).
- Lua: route sandboxed-state teardown through `destroySandboxedState` (#360) and own the teardown path plus the budget API boundary (#356); rename `freeHookData` to `capFinalizerDeadline` to say what it does (#351).
- Executor: own the ToolResult history move/free split (#359).
- TUI: dedupe settings pending-state helpers into `settings_lifecycle` (#358); centralize the mode text-input activation predicate (#354); dedupe single-line form editors into `FormField` (#353).
- Config: extract database backend vocabulary into a leaf module (#355); map `parse.zig`'s production/test regions with banners (#377) and put production code before tests (#382).
- Tools: funnel plugin record release through `freePluginRecord` (#352).
- Docs: resolve the App facade discussion — extraction over facade (#380).

### Fixed
- MCP: stop-first disable transitions and replace-not-append rediscovery; re-arm the consumed refresh flag on dedup, defer retired-client teardown, unblock UI-tick re-discovery, and guard transport lifetime (#385, #386).
- Storage: persisted state is safe to write and migrate (#375).
- TUI: commit the settings text edit on Enter; `submitMode` now owns every Enter press (#357).

### Tests
- Cover the ten production files that had no inline tests (#378); fail the suite when a test-bearing file is unreachable from the root test walk (#376).
- CI: enforce the docs verification gate; repair changelog and doc routing (#374).

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

[Unreleased]: https://github.com/ozgurulukir/zay/compare/v0.11.15...HEAD
[0.11.15]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.15
[0.11.14]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.14
[0.11.13]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.13
[0.11.12]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.12
[0.11.11]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.11
[0.11.10]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.10
[0.11.9]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.9
[0.11.8]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.8
[0.11.7]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.7
[0.11.6]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.6
[0.11.5]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.5
[0.11.4]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.4
[0.11.3]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.3
[0.11.2]: https://github.com/ozgurulukir/zay/releases/tag/v0.11.2
