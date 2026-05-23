# Nova Guidelines

This project uses Zig version 0.16

Always consult the tigerstyle skill when writing code.

## Building the TUI

We use libvaxis vxfw for building the TUI. The source code for this library is inside zig-pkg.

Prefer to use the primitives provided by the framework as much as possible.

## Verifying

Run the following:

- `zig fmt`

- `zig build test`
