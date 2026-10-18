<div align="center">

# Zay

**A single-binary coding agent for your terminal.**

<sub>Z(ig) + *ay* (Turkish for "moon") — a nod to Lua, Portuguese for moon.</sub>

[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d?style=flat-square&logo=zig&logoColor=white)](https://ziglang.org)
[![Version](https://img.shields.io/github/v/release/ozgurulukir/zay?style=flat-square)](https://github.com/ozgurulukir/zay/releases)
[![License](https://img.shields.io/github/license/ozgurulukir/zay?style=flat-square)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/ozgurulukir/zay?style=flat-square)](https://github.com/ozgurulukir/zay/stargazers)

</div>

---

## About

Zay is a **terminal-native coding agent** built as a single compiled Zig
binary. It connects to OpenAI Codex (via ChatGPT OAuth) or configurable
OpenAI-compatible providers, runs parallel workers in separate Git
worktrees, records turns in a local SQLite database (with optional Turso /
LibSQL, Cloudflare D1, or PostgreSQL companion backends), and supports Lua
plugins and MCP servers.

It is built for developers who want a local-first agent that stays in the
terminal. The developer steers the work, reviews changes, and makes the
decisions. Zay asks for approval when its command classifier marks a shell or
skill command unsafe.

## Quickstart

### Prerequisites

- [Zig](https://ziglang.org/download/) `0.16.0`
- [Git](https://git-scm.com/) `2.20+`
- A shell (Bash on Linux/macOS, PowerShell 7+ on Windows)
- Optional: [ripgrep](https://github.com/BurntSushi/ripgrep) (fast code search), [uv](https://github.com/astral-sh/uv) + Python 3.11+ (only for the optional safety classifier)

### Installation

**Linux / macOS (one-line):**

```bash
curl -fsSL https://raw.githubusercontent.com/ozgurulukir/zay/main/install.sh | bash
```

**Windows (PowerShell):**

```powershell
irm https://raw.githubusercontent.com/ozgurulukir/zay/main/install.ps1 | iex
```

**From source:**

```bash
git clone https://github.com/ozgurulukir/zay.git
cd zay
zig build --fetch
zig build install -Doptimize=ReleaseFast --prefix "$HOME/.local"
zay --version
```

### Minimal example

```bash
zay
```

Then type a request, e.g. `explain this repository` or `fix the failing tests`. Use `/help` for the command palette.

## Features

1. **Native TUI** — terminal interface with scrolling and custom color themes, built on libvaxis.
2. **LLM providers** — native ChatGPT and Codex OAuth, plus configurable
   OpenAI-compatible endpoints.
3. **Parallel git lanes** — run multiple agent threads concurrently in
   separate Git worktrees; inspect progress and merge results back.
4. **Background jobs** — asynchronous test runs, builds, or dev servers with real-time log tailing (`Ctrl+O`).
5. **Context compaction** — summarizes older conversation content and trims tool results to manage context usage.
6. **Extensible via Lua & MCP** — Lua plugins register custom tools and
   receive tool-call notifications; MCP servers provide additional tools.
7. **Local-first persistence** — SQLite timeline by default; optional cloud
   roaming (Turso LibSQL / Cloudflare D1) or a PostgreSQL companion service;
   branch switching (`/timeline`) and single-keystroke rewind (`/undo`).
8. **Layered safety** — local command patterns, approval prompts for commands
   classified as unsafe, worktree isolation, restricted Lua runtime, and an
   optional external classifier.

## Execution & Safety Model

Ordinary shell commands run without a per-command confirmation prompt. Before
a shell command or a `skill` command-mode call runs, Zay classifies it. By
default, it uses a built-in pattern matcher. When configured, an external
classifier supplies the verdict; failed requests fall back to the local
matcher. A command classified as unsafe prompts for interactive approval.
The built-in matcher recognizes selected patterns and cannot identify every
risky command.

- **Parallel lanes:** separate Git worktrees isolate each lane's branch and
  working files. They do not restrict the process's operating-system
  permissions.
- **Lua plugins:** plugins run in a restricted Lua environment with an
  instruction budget and Zay-provided bridge functions. See [plugin
  permissions and runtime](docs/plugins/permissions-and-runtime.md).
- **Optional external classifier:** the service supports model-based, rules,
  and LLM-proxy presets. See the [Safety & Classifier Guide](docs/wiki/SAFETY_CLASSIFIER.md)
  for setup and behavior.

> [!CAUTION]
> Shell commands run with the operating-system permissions of the Zay
> process. The classifier is a heuristic approval gate, and a Git worktree
> is workspace isolation; neither is an operating-system sandbox. Use a
> restricted account, container, or virtual machine when untrusted code needs
> that boundary.

## Essential Shortcuts

| Shortcut | Action |
|:---|:---|
| `/` or `Ctrl+K` | Command palette (`/connect`, `/model`, `/parallel`, `/diff`, `/timeline`, `/undo`, `/help`) |
| `@file` | Attach file contents directly into prompt |
| `$skill` | Invoke a specialized agent skill |
| `Ctrl+O` | Background Jobs & Log Viewer |
| `Shift+Tab` | Cycle between active parallel lanes |
| `Ctrl+L` | Cycle the focused worker lane in split view |
| `Ctrl+W` | Cycle split layout (dual → grid → tab) |
| `Ctrl+F` | Search transcript |
| `Ctrl+↑ / Ctrl+↓` | Navigate prompt history |
| `Alt+V` | Paste from clipboard |
| `Esc` | Cancel turn / dismiss modal |

## Documentation

- 🏛️ **[Documentation index](docs/index.md)** — entry point to all docs.
- 🏛️ **[System Architecture](docs/ARCHITECTURE.md)** — event pipeline, client layers, memory model.
- 🛡️ **[Safety & Classifier Guide](docs/wiki/SAFETY_CLASSIFIER.md)** — classifier flow, approval prompts, and limits.
- 🗄️ **[Database & Sessions](docs/database/README.md)** — SQLite, Turso / LibSQL, Cloudflare D1, PostgreSQL.
- ⚙️ **[Configuration Reference](docs/config/README.md)** — providers, API keys, compaction, themes.
- 🧠 **[Engineering Patterns](docs/patterns/README.md)** — invariants, background slots, thread safety.
- 🔌 **[MCP Guide](docs/mcp/README.md)** — stdio and Streamable HTTP MCP integration.
- 🧩 **[Lua Plugins](docs/plugins/)** — building custom tools.
- 🛠️ **[Contributor Guidelines](CONTRIBUTING.md)** — development setup, coding conventions, and pull requests.
- 🛠️ **[Building from source](docs/BUILDING.md)** — clone, fetch, build, test, install.

## Release Targets

The release workflow builds Linux x86_64, macOS arm64 (Apple Silicon), and
Windows x86_64 binaries. It runs a `--version` smoke check on Linux and macOS;
the Windows artifact is build-only in that workflow. The macOS binary is
unsigned; see the installer's Gatekeeper note if macOS blocks it.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please also read the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

Zay is open source under the [MIT License](LICENSE). Third-party components
and licenses are listed in [attribution.md](attribution.md). Distributed "AS
IS", without warranty. See [SECURITY.md](SECURITY.md) for vulnerability
reporting.
