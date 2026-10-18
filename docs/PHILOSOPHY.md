# Zay Philosophy

Zay is built for the human driver of agents. The agent can execute ordinary
shell commands directly; the human steers the work, reviews changes, and
makes the decisions. Commands classified as unsafe prompt for approval.
Zay aims to make that work clear and manageable. For project overview and
installation, see the [README](../README.md).

## The Trifecta

Bash. Worktrees. Tmux.

Together, these tools cover a wide range of coding work. Bash is the
interface to the machine, worktrees provide separate branches and working
files for parallel work, and tmux keeps long-running work alive. Everything
else is optional.

## Bash is enough

Zay treats the shell as the substrate, not the fallback. A setup with only
the core tools — `bash` and the built-in `lane` machinery for parallel
worktrees — is a complete Zay, not a degraded one. The agent reads, edits,
builds, searches, and ships using shell commands, and isolates or
parallelizes work with lanes when needed. We deliberately keep no extension
a prerequisite: if a task is best done with `rg`, `sed`, and a heredoc, that
is the answer, not a missing tool.

Bash-only is a choice, and a valid one. It keeps the agent minimal,
auditable, and inside the terminal's native vocabulary.

## Tools are superpowers, not prerequisites

When the shell is not the most natural fit, Zay grows with you — on your
terms.

- **Lua plugins** are restricted tools you write yourself: filesystem
  helpers, git workflows, JSON pipelines, and other repeated shell tasks.
  They are opt-in, project-scoped, and not required.
- **MCP servers** plug existing tools and data sources into the agent with a
  few lines of configuration.

Plugins and MCP let a team specialize Zay; they are not required for the
core product to work. A user who writes tools and one who never installs
them are both running the same product. The difference is how far they want
the agent to reach beyond the shell.

## Safety is not optional

An agent with a shell has real power, so its boundaries should be clear. Zay
classifies shell and skill commands with built-in patterns or an optional
external classifier. A command classified as unsafe asks for approval, but
the built-in matcher covers selected patterns and is not a complete security
boundary. Worktree lanes isolate file and branch changes; they do not sandbox
processes. Use an operating-system container or virtual machine when a
stronger boundary is needed. See the [Safety & Classifier
Guide](wiki/SAFETY_CLASSIFIER.md).

## Local-first (with Roaming Options)

Every session lives in a SQLite database on your machine by default. Your
conversations, timeline, and history stay on disk and can be resumed. For
multi-machine roaming, optional cloud and remote backends (Turso LibSQL,
Cloudflare D1, or a PostgreSQL companion service) can be enabled.
