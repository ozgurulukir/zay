# Use structured local history with OpenResponses replay

Nova keeps durable local session history authoritative by storing structured messages and replaying the full conversation to OpenResponses with `store: false`, rather than relying on `previous_response_id` provider continuation. This preserves resume, fork, tree navigation, and debugging semantics while still allowing provider prompt caching; Responses item identity is stored in structured assistant blocks so replay can reconstruct provider-specific text, reasoning, and tool-call items.

## Considered Options

- Use `previous_response_id` and send only new input items on follow-up requests.
- Replay full structured local history each request and rely on prompt caching for efficiency.

## Consequences

Session format breakage is acceptable while Nova is fresh. Upload payloads may be larger than continuation-based requests, but the request remains self-contained and provider-side state is an optimization rather than part of correctness.
