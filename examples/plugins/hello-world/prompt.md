---
description: Minimal demo plugin — a greeting tool and a clock.
---

This is a minimal example plugin demonstrating tool registration. Its tools are
toys, but they illustrate the `lua__hello-world__<tool>` naming and parameter
handling.

## When to use each tool

- `lua__hello-world__greet` — Return a friendly greeting for a given `name`.
  A demonstration tool; prefer real file/search tools for actual work.
- `lua__hello-world__current_time` — Return the current wall-clock time.

## Guidelines

- Treat this plugin as a template for writing your own plugins, not as a tool
  you would reach for in real tasks. Its value is showing how `register_tool`
  maps to the `lua__<plugin>__<tool>` namespace the model calls.
