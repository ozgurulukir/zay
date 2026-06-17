---
name: tui-dev
description: Use when writing TUI-related code. It explains libvaxis usage guidelines.
---

# Using libvaxis

Refer to [libvaxis docs](./references/libvaxis.md) on how to use libvaxis when building the TUI.

# Debugging

When the user reports an issue, reproduce the issue in a test case. Do NOT start fixing without a reproducible test case. Ask the user for debug logs if necessary. DO NOT GUESS.

# Guidelines

- Prefer to use the features provided by libvaxis as much as possible

- Be mindful of how the code increases the number of redraws and how it affects the performance
