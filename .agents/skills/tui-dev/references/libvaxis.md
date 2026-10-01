# Current libvaxis/vxfw notes

This project uses the pinned libvaxis dependency from build.zig.zon and its
vxfw widget layer. The application owns the event loop and lifecycle in
src/tui.zig and src/tui/lifecycle.zig; this reference is intentionally about
application integration, not a standalone libxev or zig-aio loop.

## Use the existing framework shape

- Inspect neighboring widgets under src/tui/widgets/ and use their
  vxfw.Widget/draw() composition as the template.
- Build render-ready props or view models before drawing. Keep I/O, cache
  refreshes, and state transitions in lifecycle/tick functions.
- vxfw.TextField.widget() mutates the field, so a caller needs *TextField.
  Do not make an accessor *const App if it returns a mutable text field.
- Use the framework's layout, border, text, list, and viewport primitives before
  adding manual terminal-cell arithmetic.

## Zay-specific boundaries

- Leaf widgets do not reference App; pass values or view models instead.
- The overlay picker composite is the only documented aliasing exception.
- Do not introduce custom event-loop code for a widget feature.
- Keep draw paths free of filesystem, network, and manager access. If visible
  state changes asynchronously, update a cache in the lifecycle tick and let
  the next frame render it.

For exact module ownership and regression tests, see the TUI sections in
docs/PATTERNS.md and docs/ARCHITECTURE.md.
