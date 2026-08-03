# Nova Philosophy

Nova is built for the human driver of agents. Everything it does is centered around the assumption that there is always a human in the loop. The agent proposes and executes; the human steers, approves, and decides. Consequently, Nova does its best to ensure the experience of the human driver is exquisite.

## The Trifecta

Bash. Worktrees. Tmux.

With these three tools and some well-written skills, an agent can achieve _anything_ and **everything**. Bash is the universal interface to the machine, worktrees are parallel worlds to explore, and tmux keeps long-running work alive. Everything else is sugar.

## Bash is enough

Nova treats the shell as the substrate, not the fallback. A setup with nothing but the core tools — `bash` (plus the built-in `lane` machinery for parallel worktrees) — is a complete Nova, not a degraded one: the agent reads, edits, builds, searches, and ships using only shell commands, and isolates or parallelizes work with lanes when it needs to. We deliberately keep no *extension* a prerequisite: if a task is best done with `rg`, `sed`, and a heredoc, that is the answer, not a missing tool.

Bash-only is a choice, and a valid one. It keeps the agent minimal, auditable, and always inside the terminal's native vocabulary.

## Tools are superpowers, not prerequisites

When the shell is not the most natural fit, Nova grows with you — on your terms.

- **Lua plugins** are sandboxed tools you write yourself: filesystem helpers, git workflows, JSON pipelines — anything that would otherwise be a repeated shell incantation. Opt-in, project-scoped, never required.
- **MCP servers** plug an existing ecosystem of tools and data sources into the agent with a few lines of config.

Plugins and MCP are how a team specializes Nova; they are not what makes Nova work. A user who writes tools and a user who never installs one are both running the same product, to the same depth — the only difference is how far they want the agent to reach beyond the shell.

## Safety is not optional

An agent with a shell has real power, so safety is part of the design, not an afterthought. Dangerous commands are gated before they run, and the human is always in the loop to approve the destructive ones. Power, yes — but power that asks first.

## Local-first

Every session lives in a SQLite database on your machine. Your conversations, your timeline, your history — yours, on your disk, resumable at any time. Nothing is held hostage by a cloud.
