---
name: tui-dev
description: Use when writing, debugging, or reviewing Zay's terminal UI. Covers libvaxis/vxfw, App state, widget boundaries, lifecycle ticks, async jobs, and draw-purity rules.
---

# Zay TUI Development

The TUI is built with libvaxis and its `vxfw` widget framework. Read the TUI
sections of `docs/PATTERNS.md` and `docs/ARCHITECTURE.md` before changing a
cross-cutting flow. The current framework and module split are the source of
truth; do not copy old custom `libxev`/`zig-aio` event-loop examples into the
application.

## Module ownership

- `src/tui.zig` owns `App` lifecycle and `RootWidget`.
- `src/tui/app_state.zig` groups state by concern instead of growing a flat
  `App` struct.
- `src/tui/*_lifecycle.zig` modules own domain transitions and keep `App`
  methods as thin delegates where compatibility requires them.
- `src/tui/widgets/` contains rendering widgets. Leaf widgets must not hold an
  `App` pointer (`INV-WIDGET-1`); pass scalar props or a view model built at the
  frame boundary. The picker `overlay` is the documented composite exception.
- `src/tui/command_router.zig` owns per-mode key handling. Do not add another
  private `App` key-routing path.

## Rendering and input

- Keep draw functions observational: no filesystem/network work, no manager
  refreshes, and no hidden state transitions. Snapshot or format data in the
  lifecycle/tick path, then render the prepared cache.
- Prefer vxfw primitives and follow existing `RootWidget` composition.
- `vxfw.TextField.widget()` is mutating and needs `*Self`; accessors that expose
  it must be on `*App`, not `*const App`.
- Use `panel.ViewportWindow.compute(...)` and `viewport.screenRow(i)` for
  scrollable overlay lists.
- Keep redraws bounded: only request another tick while visible state can still
  change (active jobs, notices, animations, or pending bridge work).

## Async and lanes

- App-level background families use `Job(T)` from `src/tui/job.zig`. Assign the
  owning slot only after the last fallible step (arm-last), adopt exactly once,
  and never call blocking `cancel` from render code.
- `JobFamily` is exhaustive in both `anyJobActive` and teardown cancellation.
- Lane worktree provisioning is a multi-tick `LaneBridge` operation; use
  `src/tui/lane_lifecycle.zig` and `src/tui/lanes/worktree_job.zig` rather than
  running `git worktree add` on the render path.
- Preserve the lane teardown order: terminate child processes, remove the
  worktree, then prune it. Manifest rows are parked/deleted in the ordering
  documented in `docs/PATTERNS.md`.

## Testing

Reproduce a reported behavior with a focused test or the existing scripted TUI
smoke harness before changing behavior. Inline TUI tests are wired through
`src/tui/tests.zig` and the test root; a file that is never imported will not
run its tests. Use `zig build test -Dtest-filter=<substring>` for a narrow
check, then `zig build test`. Verify Windows-specific behavior when touching
terminal, path, socket, shell, or worktree code.

## References

- `docs/PATTERNS.md`: TUI module split, widget extraction, draw purity, state
  grouping, viewport, and `Job(T)` invariants.
- `docs/ARCHITECTURE.md`: the user-facing lane and TUI model.
- `src/tui/`: current implementation; inspect neighboring widgets before
  creating a new pattern.
