# Nova Architecture

## LLM Gateway

Nova accepts any OpenAI-compatible endpoint (either `/completions` or `/responses`).

We try to normalise the request to a shape that is most compatible with the target provider.

## Agent Tools

Nova exposes the following tools:

- `bash`

`bash` has some middleware written for it that makes it friendlier for agent use. For example, large outputs from a `cat` command are written to a temp file and the agent is told the full is in that file if needed.

## Steering

Steering is done by enqueuing messages into a bounded queue. By default, the front of the queue is popped and appended to the conversation after the agent's turn is finished. You can also choose to _steer_ instead and send the queued message after the next tool call is done. If the agent stops and there are still messages in the queue we flush all the messages and append them into the conversation.

## Timeline

User's can branch off at any point in their conversation to pursue different paths and try different approaches. These are saved into the session and are resumable. When a branch occurs, we actually revert the entire project state to that point in time, not just the conversation. This is achieved via git shadow snapshots. User messages, assistant messages and even tool calls are all valid branching points. Once you're happy with a certain branch, you can `/save` it to commit to the working tree.

## Session Persistence

The session store (`sessions.sqlite`) records the active `model_provider` and `model_id` on every turn. On resume, Nova resolves the provider through two paths:

1. **Builtin providers**: resolved by enum label (`openai`, `openrouter`, etc.)
2. **Custom providers**: resolved by name from the `providers[]` config map, with `baseURL` pulled from the same entry

This means custom providers (e.g., `"qwen-cloud"` pointing to a DashScope endpoint) round-trip correctly across restarts, and the `provider` field in `config.json` preserves the user-chosen name rather than the internal enum label.

### Empty `base_url` resolution

When `model_selection.base_url` is synthesized from session metadata or legacy fields, it may be an empty string. Two guards prevent this from crashing the model catalogue loader:

1. `collectConfiguredProviders` resolves an empty `base_url` through `provider.defaultBaseUrl()` before appending to the catalog job.
2. `loadConfigured` falls back to `provider.defaultBaseUrl()` if `configured.base_url` is empty, skipping the provider entirely if no default exists.

This ensures `listModels` never receives an empty URL, avoiding the `assert(base_url.len > 0)` panic on startup.

### Dynamic provider auth key resolution

Dynamic providers selected from models.dev store their API key in `auth.json` under the provider ID (e.g., `"stepfun-ai"`), not the enum label (`"openai_compatible"`). Two fields track the identity at runtime:

- `dynamic_provider_name`: human-readable display name (e.g., `"StepFun AI"`), used by the status bar
- `dynamic_provider_id`: the auth.json key (e.g., `"stepfun-ai"`), used for session resume and API key lookup

`updateCachedProviderConnection` mirrors `dynamic_provider_id` into `model_selection.provider_name` on selection, so `tryAttachOpenAiCompatibleFromConfig` looks up the correct auth.json entry on resume. `compatibleApiKey` also uses `dynamic_provider_id` directly for the lookup, avoiding the fragile stash fallback.

## Parallel

Subagent workflows are achieved by the `/parallel` command which creates a separate git worktree for your agent to work in. The TUI supports tiling so you can have multiple agents on the screen at any time. We call each tile a `lane`. The maximum number of lanes that can be active is currently 4, because that is the empirical limit for the mental load required to manage all agents effectively.

A lane starts on a random `nova/<hex>` branch. On its first prompt, the session's own model is asked (in parallel with the turn) for a descriptive branch name based on that prompt and the last few messages of the parent lane. When the answer lands, the branch is renamed in place (`nova/<name>`) and becomes the lane's label. If the request fails or the name is unusable, the hex branch simply stays.

## Bash auto-review

We have fine-tuned a ModernBERT base model on a corpus of over 3000 bash commands and classified each command as either safe or unsafe. We run this model on every bash tool call the agent makes, and if it's marked unsafe, we show a permission prompt to either approve or reject the call. Thanks to the efficient architecture of ModernBERT (i.e. Alternating Attention) and its small size the performance overhead of making these inference calls is negligible.

## Type System Discipline

Nova uses `union(enum)` instead of flat structs with optional fields wherever a value can be in one of several mutually-exclusive states. This makes illegal combinations unrepresentable at compile time — the compiler tells the next developer where to add a case when a new variant is introduced.

Key types following this pattern:

- `ai.ChatMessage` — `union(enum) { system, user, assistant, tool }` (tool carries non-optional `call_id`)
- `transcript.Message` — `union(enum)` with 10 variants + `Basic`/`ToolView` payload structs
- `config.McpServerConfig.transport` — `union(enum) { stdio, sse }`
- `mcp.McpClient` — `transport` + `lifecycle` unions for static config and runtime state
- `config.Config.model_selection: ?ModelSelection` — typed view replacing 9 loose optional fields
- `agent.Listener(Ctx)` / `executor.ToolCallObserver(Ctx)` — generic typed callbacks replacing `*anyopaque` vtables

See `AGENTS.md` "Type System Discipline pattern" for the full list and construction patterns.
