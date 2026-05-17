# Nova Agent

Nova Agent is a coding agent harness.

## Language

### Rendering

**Display body**:
The human-facing rendered body of a tool result, separate from the LLM-visible `stdout`. Some tools emit one alongside their stdout — the LLM sees the terse stdout, the user sees the display body.
_Avoid_: "tool output" (ambiguous between stdout, stderr, and display body).

**Diff view**:
The display body emitted by `edit_file`. Line-numbered prefix-tagged lines (`+N`, `-N`, ` N`, `    ...`) rendered from the hashline patch and the original file content. Not a `git diff` and not produced by Myers — derived structurally from the patch's edit operations.
_Avoid_: "patch view" (we use "patch" for the hashline document itself).

**Color rule**:
Green is reserved for two surfaces only: (1) the `$ <Display label>` line at the top of a tool message, and (2) `+N` addition lines inside a **Diff view**. Every other tool body — bash output, file reads, search results, the verbatim content emitted by `write_file` — is muted gray. Failure overrides everything to red.
_Avoid_: "tool-green" (the older sense where `.plain` rendering meant a green body — no longer true).

**Render**:
The TUI's per-message rendering policy — `enum { plain, diff }`. `.plain` paints the body in a single muted gray. `.diff` paints per-line: `+N` green, `-N` red, others gray. Lives in `tui.zig` and is looked up by `policyFor(name)` against the **Tool registry** at apply-time; the tool layer does not know rendering exists.
_Avoid_: ".content" (older third variant that meant the same gray as `.plain` — collapsed in by the **Color rule**).

**Expand-by-default tool**:
A tool whose finished result is rendered with its body visible immediately. Currently `edit_file` and `write_file`. Other tools' bodies stay collapsed until the user toggles them. Streaming-time stays collapsed for all tools regardless. Display policy — lives TUI-side, not in the tool layer.

**Display label**:
The short human-facing label shown for a tool call — e.g. `pwd` (for `bash`), `write_file foo.zig`, `edit_file a.zig (+2 more)`. Produced by the tool itself from its argument JSON, because picking a meaningful summary requires arg-shape knowledge. Must degrade gracefully on partial JSON (stream-time deltas arrive before the JSON is closed) — typically falls back to the bare tool name. Distinct from the **Display body**: the label sits at the top of a thread message, the body sits inside it.
_Avoid_: "title" (overloaded — `thread.zig` uses `title` as the storage field, but the *concept* is the display label).

### Modules and types

**LanguageModel**:
The tagged union the agent holds to do inference — `union(enum) { openai: *openai.Client, ... }`. Exposes `prompt(messages, tokens: StreamObserver) -> Turn`, which dispatches to the active adapter. Each adapter (currently OpenAI; more planned) owns request-body construction, SSE parsing, tool_call id minting, and calling back into the agent via the **StreamObserver** as inference progresses. The agent never sees protocol vocabulary, and the TUI never sees `LanguageModel`.
_Avoid_: "AIClient" (old name for this same union — renamed because it duplicated the LanguageModel concept), "Prompter" (rejected — less precise about what the module is).

**StreamObserver**:
The narrow private callback interface **LanguageModel** uses to report inference progress back to the agent — `{ on_content, on_reasoning, on_tool_delta }`. Each callback is invoked by the adapter as deltas arrive. The agent is the only consumer; it bridges these callbacks into **Agent.Event**s on its **Agent.Listener**. Implementation detail of the agent/LM seam, not part of the public surface. Continuity name — `ai.StreamObserver` already exists in `src/ai.zig` today; this refactor changes its *shape* (drop optionals, replace indexed `tool_delta` tuple with a typed **ToolDelta** payload) but keeps the name.

**openai.Client**:
The concrete adapter struct inside `src/ai/openai.zig`. One variant of **LanguageModel**. Owns the HTTP client, the OpenAI-shaped JSON request body, the SSE parser, and the tool_call id minting fallback. Not the seam — the implementation behind it.

**ExecutorService**:
The module that runs a batch of **ToolCall**s. `runAll(calls, tools: ToolCallObserver) -> []ToolResult` dispatches via the **Tool registry**, builds each tool's **Display body** and **Display label**, formats the LLM-facing observation from stdout/stderr, calls back into the agent via the **ToolCallObserver** as each tool starts and finishes, and returns one **ToolResult** per call. Owns the two-channel split from ADR-0002. The TUI never sees `ExecutorService`.
_Avoid_: "tool runner", "tools.run" (the bare dispatch, not the service).

**ToolCallObserver**:
The narrow private callback interface **ExecutorService** uses to report **ToolCall** lifecycle back to the agent — `{ on_started(ToolCall), on_finished(*const ToolResult) }`. `on_finished` takes a pointer into the executor's already-allocated result slot — no projection allocation, no separate "finish" type. The agent is the only consumer; it bridges these callbacks into `tool_call_started` / `tool_call_finished` **Agent.Event**s on its **Agent.Listener**. Implementation detail of the agent/executor seam, not part of the public surface. Named after **ToolCall** (the value it observes), parallel to **StreamObserver** (named after the stream of deltas it observes).

**Tool**:
A typed record describing one capability — `{ name, description, schema, run, displayLabel }`. `run` is a plain function pointer `fn(gpa, io, cwd, args) -> ToolOutput`; `displayLabel` is `fn(gpa, args) -> []u8` and produces the **Display label** from the tool's argument JSON. The record does **not** carry display policy (Expand-by-default, render mode) — those live TUI-side.
_Avoid_: "tool definition" (overloaded with the OpenAI-side `ToolDefinition` JSON struct that used to live in `tools.zig`).

**Tool registry**:
A single `pub const registry: []const Tool` slice in `src/tools.zig` that enumerates every tool. The protocol-neutral source of truth — consumed by **ExecutorService** (for dispatch) and by each **LanguageModel** adapter (for building its provider-specific tools schema). Adding a tool is one line in this slice plus the tool's own file exporting `pub const tool: Tool = .{ ... }`.

**search_codebase**:
The agent-facing search tool for discovering files and matching content inside files from the current codebase.
_Avoid_: code_search

**SessionManager**:
The service that creates, resumes, branches, and persists durable agent sessions.
_Avoid_: ThreadManager

**Command**:
A TUI-only command entered at the prompt with `:` as the first byte, used for local interaction such as creating or resuming sessions rather than sending a message to the model.
_Avoid_: Slash command

**Schema**:
The per-tool argument shape carried inside a **Tool** — `{ properties: []Property }` where each `Property = { name, kind, description, required }`. Generic over the union of property names across all tools (no hard-coded `command` / `path` / `content` / `input` / `query` fields as in the old `JsonSchemaProperties` struct). Each adapter translates `Schema` into its provider's tools-JSON shape inside the adapter, not in `tools.zig`.
_Avoid_: "JSON schema" (the Schema is provider-neutral; what each adapter emits is the provider's tool-schema JSON).

**Agent.Event**:
The tagged union the agent — and *only* the agent — emits to describe what is happening. Variants: `turn_started`, `thinking_delta`, `response_delta`, `tool_call_started`, `tool_call_finished`, `turn_finished`, `turn_failed`. Payloads are designed to flatten cleanly through a C ABI later (single-level union, flat fields, no nested slices, no Zig-only types) — see the **C-flattenable** convention. Slices inside a posted Event are *borrowed* for the duration of the listener call; consumers that need durable ownership copy.
_Avoid_: "StreamPart" (old name — events were thought of as channel-pushed; the agent-emits-events framing replaces it), "StreamEvent", "UI event" (the consumer is not necessarily a UI).

**Agent.Listener**:
The typed seam consumers attach to receive **Agent.Event**s — `{ ptr: *anyopaque, on_event: *const fn(*anyopaque, Event) anyerror!void }`. The TUI implements one; future consumers (test harness, headless mode, FFI shim) implement their own. `Agent.run(listener)` attaches the listener for the duration of one run. A `null_listener` constant exists for callers that don't subscribe, keeping the emit path branch-free.
_Avoid_: "StreamPartSink" (old name), "UI listener", "observer" (the **StreamObserver** / **ToolCallObserver** are the narrow internal callbacks; the public seam is the Listener).

**ToolCall**:
The canonical, finalised record of one tool call — `{ id, name, arguments }`. Lives on assistant **ChatMessage**s in history, in **Turn**s returned by **LanguageModel**, and as input to **ExecutorService**. Ids are always non-empty; **LanguageModel** mints fallbacks when the protocol omits them.
_Avoid_: "StoredToolCall" (old, redundant — there is one canonical ToolCall now).

**ToolDelta**:
The payload type passed through **StreamObserver**'s `on_tool_delta` callback — `{ index, name, arguments }` where `name`/`arguments` are *chunks*, not complete values. A streaming snapshot, distinct from the finalised **ToolCall**. The OpenAI adapter accumulates these internally; outside that adapter no one assembles them back into ToolCalls.
_Avoid_: "streaming ToolCall" (the older shape that conflated the two).

**nova.run**:
The single public entry point — `pub fn run(init: std.process.Init, config: Config) !void`. Wires the OpenAI client, the **ExecutorService**, the agent, the embedded system prompt, and the TUI together, then runs until the TUI exits. `src/main.zig` collapses to ~3 lines (`Config.fromEnv` → `nova.run`). Embedders who want lower-level access bypass `nova.run` and use `Agent.run(listener)` directly with their own listener — the modules stay public.

**Config**:
The flat record passed to **nova.run** — `{ base_url, api_key, model, system_prompt: ?[]const u8 }`. OpenAI-shaped today (a second LM adapter would evolve this to carry an `LmConfig` union). `Config.fromEnv(env_map)` derives a Config from `OPENAI_BASE_URL` / `OPENAI_API_KEY` / `OPENAI_MODEL` with sensible defaults; embedders that don't want env lookups construct a Config literal directly. `system_prompt = null` resolves to the embedded `src/prompts/system.md` at runtime.

**ToolResult**:
The output of one **ToolCall**, carrying both channels of ADR-0002 in one record:

- **LLM channel:** `tool_call_id`, `content` (the LLM-facing observation — `stdout` or `stderr` per the fallback rule).
- **Human channel:** `display_label`, `display_body`, `stderr`, `failed`.

Returned in `[]ToolResult` from `ExecutorService.runAll`. Two consumption points share the same value: **ToolCallObserver**'s `on_finished` receives a `*const ToolResult` mid-`runAll` (the agent's bridge reads the human-channel fields and emits an **Agent.Event**), and after `runAll` returns, `Agent.takeToolResults` walks the slice — moves the LLM-channel fields into history and frees the human-channel fields the listener already consumed. Each slot is set to `undefined` after the move per the **take* convention**.
_Avoid_: "ToolFinish" (an earlier sketch had a separate type for the human channel — collapsed into ToolResult), "tool output" (clashes with **Display body**).

## Relationships

- An **Expand-by-default tool** emits a **Display body**, which becomes the body of its finished thread message.
- `edit_file`'s display body is a **Diff view**; `write_file`'s is the new file content verbatim.
- Every tool produces a **Display label** from its argument JSON; the TUI decorates it (e.g. the `$ ` prefix) before placing it in the thread.
- A **LanguageModel** consumes a slice of `ChatMessage`s, reports progress back to the agent via a **StreamObserver**, and returns a `Turn` carrying **ToolCall**s.
- An **ExecutorService** consumes a slice of **ToolCall**s, reports progress back to the agent via a **ToolCallObserver**, and returns a slice of **ToolResult**s.
- The agent translates **StreamObserver** and **ToolCallObserver** callbacks into **Agent.Event**s and emits them through its single public seam, **Agent.Listener**. Sub-modules do not know that a Listener exists.
- The **Tool registry** is consumed by **ExecutorService** (for dispatch) and by each **LanguageModel** variant (for building its provider-specific tools schema from each **Tool**'s **Schema**). The agent never sees it; the TUI never sees it.
- The agent loops: ask the **LanguageModel** for a turn, hand any **ToolCall**s to the **ExecutorService**, fold the **ToolResult**s into history, repeat — emitting **Agent.Event**s at every transition.
- A **SessionManager** persists durable sessions; a **Thread** renders transient TUI messages.
- A **Command** is handled by the TUI and does not become an agent history message.

## Conventions

- **`take*` verbs signal ownership transfer.** A function named `takeX(...)` consumes `X` and sets its source slots to `undefined` after the move. Precedent: `tools.takeResult` (`src/tools.zig:91`). Use `take*` rather than `consume*` / `move*` / `into*`.
- **C-flattenable Agent.Event payloads.** Variant payloads on **Agent.Event** must use only flat fields — strings as `[]const u8`, integers, enums, single-level nested structs of flat fields. No Zig pointers, no slice-of-slices, no nested tagged unions. This keeps the door open for an FFI shim that wraps Agent.Event as a C struct without redesigning the type. Today the in-process Zig TUI consumes Events directly; the discipline costs nothing.
- **Prompts live as files under `src/prompts/`.** Tool descriptions are in `src/prompts/tools/*.md` and `@embedFile`'d by each tool. The system prompt is `src/prompts/system.md`, loaded the same way. Do not inline long prompts as multi-line string literals in `.zig` files.

## Example dialogue

> **Dev:** "When the model calls `edit_file`, the user sees the diff but the model just sees a confirmation — how?"
> **Maintainer:** "The tool emits both. `stdout` carries a terse confirmation that flows back to the LLM as the tool observation; a separate **Display body** carrying the **Diff view** is shown only to the user. The **ExecutorService** does that split — it hands the agent a **ToolResult** carrying just the observation, and reports the Display body up through its **ToolCallObserver**. The agent translates that into a `tool_call_finished` **Agent.Event** and emits it on its **Agent.Listener**; the TUI is what subscribes."
