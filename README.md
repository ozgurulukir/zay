# Nova

The coding agent for shipping to the stars.

> Alpha software. Expect things to break.

# Quick Start

Git clone `fff` (used for file search) into `third_party/` and build it. Specific instructions
in [vendor/fff/README.md](vendor/fff/README.md).

Download `P0u4a/ModernBERT-bash-classifier` from huggingface (used for classifying the bash tool calls). Easiest way is with huggingface cli.

```bash
hf download P0u4a/ModernBERT-bash-classifier
```

And export the model to ONNX

```bash
cd vendor/local-models
uv run python export_onnx.py --model-dir /path/to/model
```

Then

```sh
zig build run
```

Add the binary (`zig-out/bin/nova`) to your PATH so you can invoke it from anywhere.

# Architecture

The TUI is a vxfw application. `src/tui.zig` holds the `App` lifecycle
and the top-level `RootWidget`; the rest of `src/tui/` is split by
concern:

- `event_router.zig` — top-level event entry (`captureEvent`).
- `command_router.zig` — per-mode key dispatch (one struct per `App.Mode`).
- `app_state.zig` — `App` state grouped into sub-structs.
- `background_delivery.zig` — background-job poll/format/deliver.
- `thread.zig` — `Thread` (lane) state, multi-lane state machine.
- `turn.zig` / `turn_view.zig` — turn lifecycle + render.
- `diff_viewer.zig` — `/diff` viewer widget.
- `model_catalogue.zig` / `model_loader.zig` / `model_cache.zig` — model
  catalogue, async loader, cached model handles.
- `provider_controller.zig` — provider API controller.
- `agent_worker.zig` — agent worker plumbing.
- `blackhole.zig` — startup animation.
- `metrics.zig` — runtime metrics.
- `naming.zig` / `style.zig` / `status.zig` / `tool_policy.zig` —
  shared helpers and policies.

`src/tui/widgets/` holds the per-widget draw code (message, command
panel, at_search, lanes picker, model picker, provider picker, resume
picker, tree selector, panel layout, tree art).
