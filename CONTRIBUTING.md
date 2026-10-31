# Contributing to Zay

Thanks for considering a contribution. Zay is a Zig project; please read this before
opening a pull request.

## Ground rules

- Be respectful; see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
- Security issues: do **not** open a public issue — see [SECURITY.md](SECURITY.md).
- One concern per PR. Keep diffs focused.

## Development setup

See [docs/BUILDING.md](docs/BUILDING.md). Short version:

```bash
git clone https://github.com/ozgurulukir/zay.git
cd zay
zig build --fetch
zig build
zig build test
```

Requirements: Zig `0.16.0`, Git `2.20+`.

## Coding conventions

- Zig `0.16` idioms; follow [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) (TigerStyle, ownership, memory safety).
- Run `zig fmt` on changed Zig files.
- New files must be wired into the module graph (`src/root.zig`) or their tests silently never run.
- Keep the deterministic safety matcher (`src/tools/bash_safety.zig`) and sandbox boundaries intact; do not weaken them.

## Testing

Before submitting:

```bash
zig build test          # authoritative signal is exit code 0
zig build test-plugin   # example Lua plugins' test.lua suites
```

Read the test-runner quirks in [docs/BUILDING.md](docs/BUILDING.md#test-runner-quirks-read-before-debugging-a-failure)
before interpreting a failure (output goes to stderr; exit code is authoritative).

## Pull requests

- Describe the change and the motivation.
- Link related issues.
- Add or update tests for behavior changes.
- Update docs when user-facing behavior changes.

## Commit messages

Use clear, imperative subjects. No co-author trailers are required.

A commit that alters runtime behavior must use a `fix`/`feat`/`perf` subject
even when the change rides in with tests; `test:` commits are test-only by
definition. Git archaeology treats `test:` as behavior-neutral, so a reader
hunting when a behavior changed will skip such a commit.