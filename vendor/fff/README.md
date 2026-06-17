# FFF

Fast file search. Used by the `search_codebase` tool and the TUI to generate filepath / code autocompletions.

Source: https://github.com/dmtrKovalenko/fff

## Building

Nova vendors the generated C header at `vendor/fff/fff.h`, but does not commit the platform-specific dynamic library. Build it from a gitignored checkout of fff.

```bash
git clone --depth 1 https://github.com/dmtrKovalenko/fff third_party/fff
cd third_party/fff
make build-c-lib
```

The Nova runtime looks for the library in this order:

- macOS: `vendor/fff/libfff_c.dylib`, `third_party/fff/target/release/libfff_c.dylib`, then `libfff_c.dylib` on the loader path.
- Linux: `vendor/fff/libfff_c.so`, `third_party/fff/target/release/libfff_c.so`, then `libfff_c.so` on the loader path.
- Windows: `vendor\\fff\\fff_c.dll`, `third_party\\fff\\target\\release\\fff_c.dll`, then `fff_c.dll` on the loader path.

## Updating the header

Regenerate `fff.h` from the FFF repository when the C ABI changes:

```bash
cd third_party/fff
make header
cp crates/fff-c/include/fff.h ../../vendor/fff/fff.h
```
