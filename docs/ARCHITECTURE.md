# Nova Architecture

## LLM Gateway

Nova accepts any OpenAI-compatible endpoint (either `/completions` or `/responses`).

We try to normalise the request to a shape that is most compatible with the target provider.

## Agent Tools

Nova exposes the following tools:

- `bash`

`bash` has some middleware written for it that makes it friendlier for agent use. For example, large outputs from a `cat` command are written to a temp file and the agent is told the full is in that file if needed.

## Steering

Steering is done by enqueuing messages into a bounded queue. The front of the queue is popped and appended to the conversation after the agent's current tool calling turn is done. If the agent stops and there are still messages in the queue we flush all the messages and append them into the conversation.

## Tree

User's can branch off at any point in their conversation to pursue different paths. These are saved into the session and are resumable. User messages, assistant messages and even tool calls are all valid branching points.
