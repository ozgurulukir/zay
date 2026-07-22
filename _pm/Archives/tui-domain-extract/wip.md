# tui-domain-extract — In progress

One item at a time (Rule 9).

## Status

All three phases committed and pushed. `tui.zig` 5100 → **4409** (-691, -13.5%).
3 new modules totalling 910 lines. `zig build && zig build test` pass.

## Constraints

- Strangler Fig pattern: original methods stay as 1-line delegates.
- `pub fn` accessors where cross-module reads need Zig 0.16 field bypass.
- `zig build && zig build test` must pass after each commit.
- atomic commits, pushed to `origin/main`.
