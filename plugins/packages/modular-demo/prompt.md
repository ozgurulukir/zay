---
name: modular-demo
description: Multi-file Lua plugin demonstration
---

# Modular Demo Plugin

Provides a single tool, `calculate_stats`, implemented across separate Lua files via `zay.require`. It takes a comma-separated `numbers` string, skips non-numeric tokens, and returns `Count: N | Sum: X.XX | Average: X.XZ`.
