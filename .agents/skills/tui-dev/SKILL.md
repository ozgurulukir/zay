---
name: tui-dev
description: Use when building, debugging, or reviewing Zay's terminal UI—covering libvaxis/vxfw widgets, overlays, key routing, App state, ticks, lanes, Job(T) async work, and draw purity.
---

# Zay TUI Development

Zay's terminal UI uses `libvaxis` and its `vxfw` widget layer (`build.zig.zon` pin). Read `docs/patterns/architecture-and-layering.md`, `docs/patterns/tui-lanes-and-worktrees.md`, and `docs/ARCHITECTURE.md` before changing a cross-cutting flow; see [`references/libvaxis.md`](references/libvaxis.md) for `vxfw` composition details.

## Module ownership

- `src/tui.zig` owns `App` lifecycle and `RootWidget`.
- `src/tui/app_state.zig` groups UI-owned state by concern (`InputState`, `PickerStates`, `NavState`, etc.) instead of flattening fields onto `App`.
- `src/tui/*_lifecycle.zig` modules own domain transitions; state belonging to an extracted concern lives in its spoke module without mirroring fields onto `App`.
- `src/tui/widgets/` holds rendering widgets. Leaf widgets follow `INV-WIDGET-1`: never import `src/tui.zig` or hold `*App`; pass scalar props, view models, and `*const Palette` built at the frame boundary. Documented mutable pointer exceptions: `InputProps.input_field: *vxfw.TextField` and `diff.zig` (`*diff_viewer.State`). `drawRoot` may write only `app.frame_geometry`.
- `src/tui/command_router.zig` owns per-mode key handling; place new mode handlers there.

## Rendering and input

- Keep draw paths observational: perform filesystem, network, cache-refresh, and state-transition work in lifecycle/tick paths, then render the prepared cache.
- Use `vxfw` primitives and existing `RootWidget` composition. Because `vxfw.TextField.widget()` mutates its receiver, accessors returning `*vxfw.TextField` take `*App`, not `*const App`.
- Use `panel.ViewportWindow.compute(...)` (or `computeWithScroll(...)`) and `viewport.screenRow(i)` for scrollable overlay lists.
- Keep ticks bounded: request another tick only while visible state can still change (active jobs, toasts, animations, or pending bridge work).

## Async jobs and lanes

- App-level background families use `Job(T)` (`src/tui/job.zig`): **arm-first** (assign the owning union/optional slot first, then arm through `&slot`), poll non-blockingly via `isDone()`, adopt exactly once, and call blocking `cancel` only at teardown—never from render code.
- Keep `JobFamily` (`src/tui/lifecycle.zig`) exhaustive in both `anyJobActive` and `cancelAllJobs`.
- Route lane worktree provisioning through `src/tui/lane_lifecycle.zig` and `src/tui/lanes/worktree_job.zig` (`LaneBridge`), keeping git worktree work off the render path.
- Preserve lane teardown order (`cleanupLaneWorktreeAndBranch`): drop manifest row, terminate child processes, remove the worktree, then prune if removal failed.

## Verification

1. Reproduce reported UI behavior with a focused test or scripted smoke check before editing.
2. Wire new TUI test files into `src/tui/tests.zig` and `src/root.zig` (`_ = @import(...)` inside `test`), then run `zig build test -Dtest-filter=<substring>` followed by `zig build test`.
3. After changes to mode transitions, focus routing, overlays, or input drawing, run `zig build && python3 tools/pty-smoke/pty_smoke.py` per `docs/BUILDING.md#verifying`. Verify Windows behavior when touching terminal, path, socket, shell, or worktree code.
