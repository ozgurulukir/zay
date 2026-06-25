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

## Parallel

Subagent workflows are achieved by the `/parallel` command which creates a separate git worktree for your agent to work in. The TUI supports tiling so you can have multiple agents on the screen at any time. We call each tile a `lane`. The maximum number of lanes that can be active is currently 4, because that is the empirical limit for the mental load required to manage all agents effectively.

## Bash auto-review

We have fine-tuned a ModernBERT base model on a corpus of over 3000 bash commands and classified each command as either safe or unsafe. We run this model on every bash tool call the agent makes, and if it's marked unsafe, we show a permission prompt to either approve or reject the call. Thanks to the efficient architecture of ModernBERT (i.e. Alternating Attention) and its small size the performance overhead of making these inference calls is negligible.
