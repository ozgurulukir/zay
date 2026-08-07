# Nova Architecture

High-level architecture of Nova. For implementation patterns, engineering gotchas, and the type-system discipline, see [Patterns](PATTERNS.md). For configuration details, see [Configuration](CONFIG.md). For MCP internals, see [MCP](MCP.md). For plugin development, see [Plugins](plugins/README.md).

## LLM Gateway

Nova accepts any OpenAI-compatible endpoint (either `/completions` or `/responses`).

We try to normalise the request to a shape that is most compatible with the target provider.

## Agent Tools

Nova exposes the following tools:

- `bash`
- `lane`

`bash` has some middleware written for it that makes it friendlier for agent use. For example, large outputs from a `cat` command are written to a temp file and the agent is told the full is in that file if needed. See [Bash auto-review](#bash-auto-review) below.

`lane` gives the model first-class access to Nova's parallel-lane substrate: isolated git worktrees the TUI tiles side-by-side. It is a *bridge* tool — the tool runs on the lane's worker thread, so every action is posted across a `LaneBridge` (`src/tools/lane_bridge.zig`) and resolved by the UI on its tick. Two modes:

- **Workspace mode** (`lane create`/`enter`/`leave`/`merge`): the driver's `Agent.workspace` is set to the lane's worktree path, and the per-batch executor re-roots at it (`effectiveCwd`) — bash/file/python calls then run inside the lane, and the lane branch folds back with `lane merge`.
- **Orchestration mode** (`lane spawn`/`read`/`await`/`cancel`/`steer`): the driver spawns independent worker agents into fresh live lanes that run concurrently on their own worker threads; completion is delivered back to the driver (`deliverPendingLaneCompletions`) and finished workers are auto-parked (runtime freed, transcript kept).

Only the driver lane may `spawn`/`enter`/`merge` — a worker gets `list`/`read` only. The 4-lane cap applies; `validateCwd`'s containment guarantees are unchanged (lane roots are valid only because Nova owns them).

See [Parallel](#parallel) for the user-facing lane model.

### Tool schema strict mode

Builtin and MCP tool schemas are serialized with OpenAI strict-mode semantics (opt-in via `ai.Config.strict`):

- `strict: true`
- Top-level `parameters` uses `additionalProperties: false`
- Optional fields carry `nullable: true` and emit `["<type>", "null"]` union arrays
- Nested free-form objects like `env` keep `additionalProperties: true`

The full strict-mode design, its gateway-incompatibility caveats, and its persistence rules live in the [Tool schema strict-mode pattern](PATTERNS.md#tool-schema-strict-mode-pattern) in Patterns.

## Steering

Steering is done by enqueuing messages into a bounded queue. By default, the front of the queue is popped and appended to the conversation after the agent's turn is finished. You can also choose to _steer_ instead and send the queued message after the next tool call is done. If the agent stops and there are still messages in the queue we flush all the messages and append them into the conversation.

## Timeline

User's can branch off at any point in their conversation to pursue different paths and try different approaches. These are saved into the session and are resumable. When a branch occurs, we actually revert the entire project state to that point in time, not just the conversation. This is achieved via git shadow snapshots. User messages, assistant messages and even tool calls are all valid branching points. Once you're happy with a certain branch, you can `/save` it to commit to the working tree.

## Session Persistence

The session store (`sessions.sqlite`) records the active `model_provider`, `model_id`, and `reasoning_effort` on every turn and on every mid-session model switch, and resumes correctly across restarts — including cross-project resumes. The full lifecycle (schema, resume paths, custom-provider round-tripping, dynamic-provider auth resolution, restart catalog restore) is documented in the [Mid-session model persistence pattern](PATTERNS.md#mid-session-model-persistence-pattern), the [Cross-project session resume pattern](PATTERNS.md#cross-project-session-resume-pattern), and the related provider patterns in Patterns.

## Parallel

Subagent workflows are achieved by the `/parallel` command which creates a separate git worktree for your agent to work in. The TUI supports tiling so you can have multiple agents on the screen at any time. We call each tile a `lane`. The maximum number of lanes that can be active is currently 4, because that is the empirical limit for the mental load required to manage all agents effectively.

A lane starts on a random `nova/<hex>` branch. On its first prompt, the session's own model is asked (in parallel with the turn) for a descriptive branch name based on that prompt and the last few messages of the parent lane. When the answer lands, the branch is renamed in place (`nova/<name>`) and becomes the lane's label. If the request fails or the name is unusable, the hex branch simply stays.

## Bash auto-review

We have fine-tuned a ModernBERT base model on a corpus of over 3000 bash commands and classified each command as either safe or unsafe. We run this model on every bash tool call the agent makes, and if it's marked unsafe, we show a permission prompt to either approve or reject the call. Thanks to the efficient architecture of ModernBERT (i.e. Alternating Attention) and its small size the performance overhead of making these inference calls is negligible.

### Local safety fallback

When the remote classifier is unavailable (network error, service down), a local pattern matcher in `src/tools/bash_safety.zig` provides defense-in-depth. It flags obviously destructive commands:

- `rm -rf /`, `rm -rf /*`, `rm -rf --no-preserve-root /`
- Fork bombs (`:(){ :|:& };:`)
- Destructive `dd` to block devices (`of=/dev/sda`, `of=/boot/`, etc.)
- `mkfs` targeting `/dev/`
- Redirects into critical system paths (`/etc/`, `/boot/`, `/sys/`, `/proc/`, `/dev/sd*`)

The local matcher is intentionally conservative — it only catches clearly destructive patterns. The remote model is the primary classifier.

### Working directory validation

The `cwd` parameter in bash tool calls is validated against the project root in `src/tools/bash.zig` (`validateCwd`). The resolved path is normalized (resolving `..` and `.` segments) and checked to stay within the project root. This prevents the model from escaping the project via absolute paths like `/etc` or relative paths like `../../sensitive`.

### Temp file safety

Temporary log files use hex-only filenames (`nova-bash-<hex>.log` via `bytesToHex`), making path traversal impossible. The `namedTempPath` public API asserts that the provided name contains no path separators.

## Lua Plugin System

Nova supports extending its capabilities through Lua 5.4 plugins. The plugin system lives in `src/lua/` and provides a sandboxed runtime, plugin lifecycle, event bus, tool registration, config integration, bytecode caching, and TUI integration.

The full plugin development guide, API reference, and example walkthroughs live in [Plugins](plugins/README.md). The internal wiring patterns (tool dispatch, event wiring, bridge functions, two-store state) live in [Patterns](PATTERNS.md).

## Type System Discipline

Nova uses `union(enum)` instead of flat structs with optional fields wherever a value can be in one of several mutually-exclusive states. This makes illegal combinations unrepresentable at compile time.

The complete, current list of `union(enum)` types and the construction patterns live in the [Type System Discipline pattern](PATTERNS.md#type-system-discipline-pattern) in Patterns.
