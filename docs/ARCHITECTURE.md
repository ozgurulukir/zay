# Nova Architecture

## LLM Gateway

Nova accepts any OpenAI-compatible endpoint (either `/completions` or `/responses`).

We try to normalise the request to a shape that is most compatible with the target provider.

## Agent Tools

Nova exposes the following tools:

- `read`
- `write_file`
- `edit_file`
- `grep`
- `find`
- `bash`

`read` emits content-hash anchors (`LINE+HASH|TEXT`) that `edit_file` consumes in hashline patch documents.

`grep` and `find` use FFF behind the scenes for fast search.

`bash` works as a plain shell executor.

## Steering

Steering is done by enqueuing messages into a bounded queue. The front of the queue is popped and appended to the conversation after the agent's current tool calling turn is done. If the agent stops and there are still messages in the queue we flush all the messages and append them into the conversation.
