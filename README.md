<div align="center">

# Zay

**A fast, single-binary coding agent for your terminal.**

<sub>Z(ig) + *ay* (Turkish for "moon") — a nod to Lua, Portuguese for moon.</sub>

[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d?style=flat-square&logo=zig&logoColor=white)](https://ziglang.org)
[![Version](https://img.shields.io/github/v/release/ozgurulukir/zay?style=flat-square)](https://github.com/ozgurulukir/zay/releases)
[![License](https://img.shields.io/github/license/ozgurulukir/zay?style=flat-square)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/ozgurulukir/zay?style=flat-square)](https://github.com/ozgurulukir/zay/stargazers)

</div>

---

## About

Zay is a **terminal-native coding agent** designed for speed, focus, and low latency. It ships as a single compiled Zig binary that connects to OpenAI Codex (via ChatGPT OAuth) or any OpenAI-compatible provider, orchestrates parallel work across isolated git worktree lanes, logs every turn to a local SQLite database (with optional Turso / LibSQL, Cloudflare D1, or PostgreSQL companion backends), and is extensible with sandboxed Lua plugins and MCP servers.

It is built for developers who want a fast, local-first agent that stays in the terminal and keeps the human in the loop: the agent proposes and executes, the human steers, approves, and decides.

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

1. **Native TUI** — instant startup, fluid scrolling, custom color themes (built on libvaxis).
2. **Any LLM provider** — native ChatGPT & Codex OAuth (no API keys), plus OpenRouter, Ollama, DeepSeek, Gemini, Mistral, Cerebras, and custom OpenAI-compatible endpoints.
3. **Parallel git lanes** — run multiple agent threads concurrently in isolated git worktrees; inspect progress and merge back cleanly.
4. **Background jobs** — asynchronous test runs, builds, or dev servers with real-time log tailing (`Ctrl+O`).
5. **Context compaction** — dynamic, token-calibrated retention budgets that preserve critical history below model limits.
6. **Extensible via Lua & MCP** — Lua plugins register custom tools and receive tool-call notifications; MCP servers provide additional tools.
7. **Local-first persistence** — SQLite timeline by default; optional cloud roaming (Turso LibSQL / Cloudflare D1) or a PostgreSQL companion service; branch switching (`/timeline`) and single-keystroke rewind (`/undo`).
8. **Layered safety** — deterministic command safety matcher, git worktree isolation, sandboxed Lua plugins, optional AI safety classifier.

## Execution & Safety Model

Zay runs without granular per-action permission prompts (YOLO mode), relying on layered safety guardrails:

- **Built-in Deterministic Safety Matcher (default):** zero-dependency lexical token analysis (`src/tools/bash_safety.zig`) that intercepts high-risk destructive commands (`rm -rf /`, drive wipes, `mkfs`, fork bombs) and gates them behind confirmation prompts.
- **Git Worktree Isolation:** risky or wide refactors can be spawned into isolated **Parallel Lanes** (`/parallel` or `lane spawn`), physically contained in dedicated worktrees.
- **Sandboxed Lua Plugins:** embedded runtime with unsafe libraries stripped (`io`, `os.execute`), strict workspace path confinement, and instruction budgets.
- **Optional AI Safety Classifier:** deep contextual command evaluation via a local ModernBERT service or an LLM-as-classifier proxy (OpenAI / Ollama / OpenRouter) (`tools/classifier/`).

> [!CAUTION]
> Because Zay executes commands directly in your workspace without per-action confirmation prompts, run it in repositories you trust or confine broad changes to parallel git lanes.

### Optional safety classifier

To enable Tier 2 contextual risk analysis with the ModernBERT classifier:

```bash
uv run -m tools.classifier.server --model modernbert --port 8765
export ZAY_BASH_CLASSIFIER_URL="http://127.0.0.1:8765/classify"
```

See the **[Safety & Classifier Guide](docs/wiki/SAFETY_CLASSIFIER.md)** for Docker deployment and API details.

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
- 🛡️ **[Safety & Classifier Guide](docs/wiki/SAFETY_CLASSIFIER.md)** — multi-tier safety architecture.
- 🗄️ **[Database & Sessions](docs/DATABASE.md)** — SQLite, Turso / LibSQL, Cloudflare D1, PostgreSQL.
- ⚙️ **[Configuration Reference](docs/CONFIG.md)** — providers, API keys, compaction, themes.
- 🧠 **[Engineering Patterns](docs/PATTERNS.md)** — invariants, background slots, thread safety.
- 🔌 **[MCP Guide](docs/MCP.md)** — stdio and Streamable HTTP MCP integration.
- 🧩 **[Lua Plugins](docs/plugins/)** — building custom tools.
- 🛠️ **[Contributor Guidelines](AGENTS.md)** — TigerStyle, Zig 0.16 idioms, testing.
- 🛠️ **[Building from source](docs/BUILDING.md)** — clone, fetch, build, test, install.

## Platform Support

- **Linux:** fully supported and tested daily.
- **macOS (Apple Silicon):** binaries shipped for every release (`zay-macos-aarch64`); beta until exercised on real hardware. Unsigned — see the installer's Gatekeeper note.
- **Windows:** daily-driver ready; release CI builds `zay-windows-x86_64.exe` natively. PowerShell 7 (`pwsh`) is the shell tool.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please also read the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

Zay is open source under the [MIT License](LICENSE). Third-party components and licenses are listed in [attribution.md](attribution.md). Distributed "AS IS", without warranty. See also [SECURITY.md](SECURITY.md) for reporting vulnerabilities.