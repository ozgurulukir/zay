# Assistant response classification

Response semantics belong to the adapter boundary. Request capability flags
(`WireDialect`) do not establish the meaning of response fields. The agent and
TUI consume typed text, reasoning and tool events; they must not infer a kind
from prose, model naming or whether an answer has arrived yet.

## Design decision

| Shape | Consequence |
| --- | --- |
| Teach the TUI provider/model heuristics | Couples presentation to protocols and leaves persisted turns inconsistent. |
| Reuse request dialect for response classification | Cannot describe models or proxies sharing a request format but different response extensions. |
| Resolve a separate response policy at the adapter boundary | Keeps protocols local and allows explicit provider/model overrides. Chosen. |

`ai/response_policy.zig` owns pure inbound field semantics. `ai.Config` can carry
a value-only `Policy` override, whose lifecycle is identical to the client
configuration. The chat client resolves a default policy from provider identity
and passes it through `StreamEnv` to decoding. Unknown extensions are ignored;
`content` is answer text. Explicit reasoning fields remain reasoning even when
no final answer arrives. Absence of an answer is not evidence that reasoning
should be relabeled as an answer.

DeepSeek documents `reasoning_content` separately from `content` in its
[chat schema](https://api-docs.deepseek.com/api/create-chat-completion/).
OpenRouter documents separate reasoning output in its
[reasoning guide](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens).
Ollama's native `thinking` extension is enabled by provider identity or an
explicit override, rather than universally applied to every compatible proxy.

## Completion contracts

- Provider/model configuration must expose explicit response-policy overrides
  and preserve them through config parsing, cloning, saving and client attach.
- Wire decoding must preserve typed content parts and their order. Multiple
  aliases must not duplicate output or hide earlier bytes from observers.
- Chat and Responses adapters must classify explicit answer content as text,
  including assistant commentary and final-answer phases. Structured reasoning
  stays reasoning; encrypted reasoning is never rendered as plain text.
- Completed turns and observer events must agree on classification. Chat parts
  retain wire order. Responses deltas are delivered as they arrive, while the
  completed turn retains output-item order; interleaved items are routed by
  identity rather than appended to the most recently created item.
- Transcript reconstruction must retain all answer blocks, and live rendering
  must not move a later reasoning segment ahead of earlier answer text.
- Regression fixtures must cover mixed reasoning/answer/tool output across
  adapters and provider policies, including a proxy mapping `thinking` to text.

Implemented: the policy boundary, field-level provider/model overrides
through loading/cloning/serialization/attach/model switching, ordered chat
parts shared by callbacks and turn assembly, equal same-chunk reasoning-alias
deduplication, and answer/reasoning block preservation in live and rebuilt
transcripts. Structured chat content and reasoning details are decoded by
explicit part type. Responses routes answer/reasoning events by item id and
output index, preserves commentary/final-answer phases for replay, and rejects
final snapshots that contradict text already displayed.

Response-policy overrides apply to chat extensions, not explicitly typed
Responses events. They do not parse prose or guess semantics from model names.
Alias deduplication recognizes equal payloads in the same chunk, not arbitrary
alternative fragmentations. The observer API has no item identity, so a live
transcript cannot reconstruct canonical ordering for arbitrarily interleaved
Responses items; completed turns keep each item's content separate.

## Verification

The optimized build and plugin suite pass. The full optimized test run
(`zig build test -Doptimize=ReleaseFast`, with loopback access for HTTP fixtures)
reports 1,887 passed, 28 skipped, and one unrelated failure: the unchanged
`session_switcher` test "map-based resume sort does not fold pathsEqual-equal
group keys into one entry" assumes Windows path equality on Linux. All
classification, configuration, adapter, runtime-role and transcript regressions
pass in that run. Formatting, JSON-schema parsing and diff checks also pass.

The default Debug test build still hits the Zig compiler SIGSEGV observed
before this change; it is not a validated gate. A pre-existing exhausted HTTP
fixture for truncated tool-call retry was completed with the normal post-tool
answer response so the full optimized suite can terminate.
