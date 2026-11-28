---
name: tigerstyle
description: Use when writing, editing, or reviewing Zig 0.16 code in Zay to apply the repository's control-flow, assertion, memory, concurrency, and naming conventions.
---

# TigerStyle for Zay

Safety, clarity, and explicit ownership come first. Pair this skill with `docs/DEVELOPMENT.md` (Zig 0.16 API recipes, file header order, and test reachability via `src/root.zig`) and `docs/patterns/README.md` (subsystem invariants).

## Control flow and assertions

- Keep control flow explicit and bounded: bound queues, buffers, retries, and external work (unless a protocol or file format is legitimately streaming), and bound or avoid recursion.
- Centralize branching and state updates in the parent function ("push `if`s up and `for`s down"); keep leaf helpers pure.
- Flatten opaque compound conditions into clear `if`/`else` branches so positive and negative cases are both obvious and handled or asserted.
- State range invariants positively (`if (index < length)` rather than `if (index >= length)`).
- Handle every Zig error union explicitly; reserve `catch unreachable` for proven invariants.
- Pass options explicitly at library call sites rather than relying on implicit defaults.
- Assert API boundaries and state transitions on both sides of a boundary (e.g., before writing and after reading), covering both the valid space and the invalid boundary. Omit assertions already guaranteed by types or loop bounds.
- Split compound assertions (`assert(a); assert(b);` over `assert(a and b);`), and write implications on one line (`if (a) assert(b);`).

## Memory, concurrency, and types

- Make post-startup allocations explicit, tightly scoped, and paired with `defer` or `errdefer`; use blank lines to group allocation and `defer` pairs. Never let an `errdefer` fire after manual `deinit` on an error path, and free buffers explicitly before `return null` inside `catch` blocks.
- Shrink variable scope: declare variables as close to first use as possible to avoid place-of-check-to-place-of-use gaps and variable misuse.
- Pass read-only arguments larger than 16 bytes as `*const T` to prevent accidental stack copies.
- Initialize large or immovable structs in place via out-pointers (`fn init(target: *LargeStruct) !void`); in-place initialization is viral up the enclosing container.
- Zero padding/buffers cleanly to avoid buffer bleeds or non-deterministic output.
- Use `std.Io.Mutex` / `std.Io.Condition` for locking; `std.atomic.Mutex` is a spinlock in Zig 0.16 and pegs CPU. Never block the TUI render path; route background work through `Job(T)` (`arm-first`) and bridge conventions.
- Use `usize` for indexes and lengths, and fixed-width integers for wire formats, persisted data, and cross-platform limits.
- Prefer `void` over `bool`, `bool` over `u64`, `u64` over `?u64`, and `?u64` over `!u64` to keep call-site branching shallow.

## Performance

- Batch work and decouple control plane from data plane; optimize for the slowest resource first in order: network, disk, memory, CPU.
- Extract hot loops into standalone functions taking primitive arguments without `self` so field caching and redundant work stay visible.

## Naming and layout

Follow `docs/DEVELOPMENT.md` casing rules: `camelCase` for functions and methods, `snake_case` for variables, parameters, and constants, `PascalCase` for types, and `const Self = @This();` at the top of modules/structs.

- Put units and qualifiers last in descending significance so related names align (`latency_ms_max`, `latency_ms_min`).
- Spell out variable names (`gpa: Allocator`, `arena: Allocator`, `source`/`target` with matching lengths for symmetry) except primitive loop/sort/matrix indexes; use `--long` flags in scripts.
- Preserve acronym capitalization (`VSRState`, not `VsrState`).
- Prefix single-caller helpers with the caller's name (`readSector` / `readSectorCallback`), and put callbacks last in parameter lists.
- Prefer nouns over participles (`replica.pipeline` over `replica.preparing`).
- Use an options struct when positional arguments share types (`u64, u64`) or accept `null`; pass unique singleton dependencies (`allocator`, `io`) positionally from general to specific.
- Order file and struct members top-down: fields, then types (ending with `const Self = @This();`), then methods (`init`/`main` first). Extract complex nested types to top-level structs.
- Write comments as full sentences explaining **why** (invariants, constraints, workarounds), not **what**; inline end-of-line comments may be brief phrases.

## Off-by-one and arithmetic

- Treat `index` (0-based), `count` (1-based: `index + 1`), and `size` (`count * unit_bytes`) as distinct semantic concepts; convert explicitly.
- State division intent with Zig builtins (`@divExact`, `@divFloor`, `@divTrunc`) instead of bare `/`.
