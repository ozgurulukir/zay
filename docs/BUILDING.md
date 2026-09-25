# Building Zay from source

This guide is for compiling Zay locally. For normal use, prefer a release
binary or one of the installers in the root README.

## Requirements

- Zig 0.16.0
- Git 2.20 or newer
- Network access for the first dependency fetch

## Clone, fetch, build, and install

```bash
git clone https://github.com/ozgurulukir/zay.git
cd zay
zig build --fetch
zig build
zig build test
zig build install -Doptimize=ReleaseFast --prefix "$HOME/.local"
```

The pinned libvaxis revision includes the upstream fixes for the Windows input
loop, bracketed paste handling, and FocusHandler recovery. No local vaxis patch
application step is required.

On Windows PowerShell:

```powershell
git clone https://github.com/ozgurulukir/zay.git
Set-Location zay
zig build --fetch
zig build
zig build test
zig build install -Doptimize=ReleaseFast --prefix "$HOME/.local"
```

## Troubleshooting

If dependency fetching fails, resolve the network or Git error and rerun
`zig build --fetch`. The dependency is fetched into Zig's package cache; it
does not need to be modified in the Zay checkout.
