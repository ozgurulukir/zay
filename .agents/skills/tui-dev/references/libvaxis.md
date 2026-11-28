# libvaxis and vxfw integration notes

Zay uses the pinned `libvaxis` dependency in `build.zig.zon` and its `vxfw` widget layer. Application event loop and lifecycle live in `src/tui.zig` and `src/tui/lifecycle.zig`; use `vxfw` primitives rather than introducing standalone `libxev` or `zig-aio` loops.

## Framework composition

- Inspect neighboring widgets under `src/tui/widgets/` and mirror their `vxfw.Widget` / `drawFn` and `DrawContext` → `vxfw.Surface` / `SubSurface` layout.
- Build render-ready props and view models in `src/tui/root_layout.zig` / `src/tui/lane_column.zig` before constructing leaf widgets (`INV-WIDGET-1` exceptions: `InputProps.input_field: *vxfw.TextField` and `diff.zig`'s `*diff_viewer.State`).
- `vxfw.TextField.widget()` takes `*Self`, so accessors returning `*vxfw.TextField` require `*App`.
- Use `panel.Shell`, `panel.listSurface`, and `panel.ViewportWindow` (`src/tui/widgets/panel.zig`) for bordered overlay lists and scroll geometry before writing custom terminal-cell arithmetic.

For exact ownership contracts and regression tests, see `docs/patterns/architecture-and-layering.md` and `docs/patterns/tui-lanes-and-worktrees.md`.
