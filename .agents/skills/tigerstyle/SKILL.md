---
name: tigerstyle
description: Use when writing any code. It describes how to write beautiful, maintainable and performant code.
---

## Goals when writing code

- Write code that is simple and elegant
- Avoid technical debt at all costs
- Maximise the safety of the program

### Rules

- Use only very simple, explicit control flow
- Do not use recursion
- Minimise abstractions to a few excellent ones, increasing abstractions creates risk of a leaky abstraction
- Bound everything, all loops and queues must have a fixed upper bound
- Use explicitly-sized types like `u32` for everything, avoid architecture-specific `usize`.
- Assert all function arguments and return values, pre/postconditions and invariants. A
  function must not operate blindly on data it has not checked. We expect on average a minimum of two
  assertions per function.
- For every property you want to enforce, try to find at least two different code paths where an assertion can be added. For example, assert validity of data right before writing it to disk, and also immediately after reading from disk.
- Split compound assertions: prefer `assert(a); assert(b);` over `assert(a and b);`.
  The former is simpler to read, and provides more precise information if the condition fails.
- Use single-line `if` to assert an implication: `if (a) assert(b)`.
- The golden rule of assertions is to assert the positive space that you do expect AND to
  assert the negative space that you do not expect because where data moves across the
  valid/invalid boundary between these spaces is where interesting bugs are often found. This is
  also why tests must test exhaustively, not only with valid data but also with invalid data,
  and as valid data becomes invalid.
- All memory must be statically allocated at startup. No memory may be dynamically allocated (or
  freed and reallocated) after initialization. This avoids unpredictable behavior that can
  significantly affect performance, and avoids use-after-free.
- Declare variables at the smallest possible scope, and minimize the number of variables in
  scope, to reduce the probability that variables are misused.
- Functions must be at most 70 lines
- Functions should take a few parameters, have a simple return type, with meaty logic inside.
- Centralize control flow. When splitting a large function, try to keep all switch/if statements in the "parent" function, and move non-branchy logic fragments to helper functions. Divide responsibility. All control flow should be handled by _one_ function, the rest shouldn't
  care about control flow at all. In other words,
  ("push `if`s up and `for`s down").
  Similarly, centralize state manipulation. Let the parent function keep all relevant state in
  local variables, and use helpers to compute what needs to change, rather than applying the
  change directly. Keep leaf functions pure.
- Whenever your program has to interact with external entities, don't do things directly in
  reaction to external events. Instead, your program should run at its own pace. Not only does
  this make your program safer by keeping the control flow of your program under your control, it
  also improves performance for the same reason (you get to batch, instead of context switching on
  every event). Additionally, this makes it easier to maintain bounds on work done per time period.
- Compound conditions that evaluate multiple booleans make it difficult for the reader to verify
  that all cases are handled. Split compound conditions into simple conditions using nested
  `if/else` branches. Split complex `else if` chains into `else { if { } }` trees. This makes the
  branches and cases clear. Again, consider whether a single `if` does not also need a matching
  `else` branch, to ensure that the positive and negative spaces are handled or asserted.
- State invariants positively. When working with lengths and indexes, this
  form is easy to get right (and understand):

  ```
  if (index < length) {
    // The invariant holds.
  } else {
    // The invariant doesn't hold.
  }
  ```

  This form is harder, and also goes against the grain of how `index` would typically be compared to
  `length`, for example, in a loop condition:

  ```
  if (index >= length) {
    // It's not true that the invariant holds.
  }
  ```

- All errors must be handled. If a path can throw, that exception must be handled.

- Explicitly pass options to library functions at the call site, instead of relying on the
  defaults. This improves readability but most of all avoids latent, potentially
  catastrophic bugs in case the library ever changes its defaults.

## Performance

- Be explicit. Minimize dependence on the compiler to do the right thing for you.

  In particular, extract hot loops into stand-alone functions with primitive arguments without
  `self` (see [an example](https://github.com/tigerbeetle/tigerbeetle/blob/0.16.19/src/lsm/compaction.zig#L1932-L1937)).
  That way, the compiler doesn't need to prove that it can cache struct's fields in registers, and a
  human reader can spot redundant computations easier.

- Optimize for the slowest resources first (network, disk, memory, CPU) in that order, after
  compensating for the frequency of usage, because faster resources may be used many times more. For
  example, a memory cache miss may be as expensive as a disk fsync, if it happens many times more.

- Distinguish between the control plane and data plane. A clear delineation between control plane
  and data plane through the use of batching enables a high level of assertion safety without losing
  performance.

- Amortize network, disk, memory and CPU costs by batching accesses.

- Let the CPU be a sprinter doing the 100m. Be predictable. Don't force the CPU to zig zag and
  change lanes. Give the CPU large enough chunks of work. This comes back to batching.

## Naming Things

- Get the nouns and verbs just right. Great names are the essence of great code, they capture
  what a thing is or does, and provide a crisp, intuitive mental model. They show that you
  understand the domain. Take time to find the perfect name, to find nouns and verbs that work
  together, so that the whole is greater than the sum of its parts.

- Do not abbreviate variable names, unless the variable is a primitive integer type used as an
  argument to a sort function or matrix calculation. Use long form arguments in scripts: `--force`,
  not `-f`. Single letter flags are for interactive usage.

- Use proper capitalization for acronyms (`VSRState`, not `VsrState`).

- Add units or qualifiers to variable names, and put the units or qualifiers last, sorted by
  descending significance, so that the variable starts with the most significant word, and ends with
  the least significant word. For example, `latency_ms_max` rather than `max_latency_ms`. This will
  then line up nicely when `latency_ms_min` is added, as well as group all variables that relate to
  latency.

- Infuse names with meaning. For example, `allocator: Allocator` is a good, if boring name,
  but `gpa: Allocator` and `arena: Allocator` are excellent. They inform the reader whether
  `deinit` should be called explicitly.

- When choosing related names, try hard to find names with the same number of characters so that
  related variables all line up in the source. For example, as arguments to a memcpy function,
  `source` and `target` are better than `src` and `dest` because they have the second-order effect
  that any related variables such as `source_offset` and `target_offset` will all line up in
  calculations and slices. This makes the code symmetrical, with clean blocks that are easier for
  the eye to parse and for the reader to check.

- When a single function calls out to a helper function or callback, prefix the name of the helper
  function with the name of the calling function to show the call history. For example,
  `read_sector()` and `read_sector_callback()`.

- Callbacks go last in the list of parameters. This mirrors control flow: callbacks are also
  invoked last.

- Order matters for readability (even if it doesn't affect semantics). On the first read, a file
  is read top-down, so put important things near the top. The `main` function goes first.

  The same goes for objects or structs, the order is fields then types then methods:

  ```
  time: Time,
  process_id: ProcessID,

  const ProcessID = struct { cluster: u128, replica: u8 };
  const Tracer = @This(); // This alias concludes the types section.

  pub fn init(gpa: std.mem.Allocator, time: Time) !Tracer {
      ...
  }
  ```

  If a nested type is complex, make it a top-level struct.

  At the same time, not everything has a single right order. When in doubt, consider sorting
  alphabetically, taking advantage of big-endian naming.

- Don't overload names with multiple meanings that are context-dependent.

- Think of how names will be used outside the code, in documentation or communication. For example,
  a noun is often a better descriptor than an adjective or present participle, because a noun can be
  directly used in correspondence without having to be rephrased. Compare `replica.pipeline` vs
  `replica.preparing`. The former can be used directly as a section header in a document or
  conversation, whereas the latter must be clarified. Noun names compose more clearly for derived
  identifiers, e.g. `config.pipeline_max`.

- For named arguments: Use it when arguments can be
  mixed up. A function taking two `u64` must use an options struct. If an argument can be `null`,
  it should be named so that the meaning of `null` literal at the call site is clear.

  Because dependencies like an allocator or a tracer are singletons with unique types, they should
  be threaded through constructors positionally, from the most general to the most specific.

- Comments are sentences, with a space after the slash, with a capital letter and a full stop, or a
  colon if they relate to something that follows. Comments are well-written prose describing the
  code, not just scribblings in the margin. Comments after the end of a line _can_ be phrases, with
  no punctuation.

### Cache Invalidation

- Don't duplicate variables or take aliases to them. This will reduce the probability that state
  gets out of sync.

- If you don't mean a function argument to be copied when passed by value, and if the argument type
  is more than 16 bytes, then pass the argument as `*const`. This will catch bugs where the caller
  makes an accidental copy on the stack before calling the function.

- Construct larger structs _in-place_ by passing an _out pointer_ during initialization.

  In-place initializations can assume **pointer stability** and **immovable types** while
  eliminating intermediate copy-move allocations, which can lead to undesirable stack growth.

  Keep in mind that in-place initializations are viral — if any field is initialized
  in-place, the entire container struct should be initialized in-place as well.

  **Prefer:**

  ```zig
  fn init(target: *LargeStruct) !void {
    target.* = .{
      // in-place initialization.
    };
  }

  fn main() !void {
    var target: LargeStruct = undefined;
    try target.init();
  }
  ```

  **Over:**

  ```zig
  fn init() !LargeStruct {
    return LargeStruct {
      // moving the initialized object.
    }
  }

  fn main() !void {
    var target = try LargeStruct.init();
  }
  ```

- **Shrink the scope** to minimize the number of variables at play and reduce the probability that
  the wrong variable is used.

- Calculate or check variables close to where/when they are used. **Don't introduce variables before
  they are needed.** Don't leave them around where they are not. This will reduce the probability of
  a POCPOU (place-of-check to place-of-use), a distant cousin to the infamous
  [TOCTOU](https://en.wikipedia.org/wiki/Time-of-check_to_time-of-use). Most bugs come down to a
  semantic gap, caused by a gap in time or space, because it's harder to check code that's not
  contained along those dimensions.

- Use simpler function signatures and return types to reduce dimensionality at the call site, the
  number of branches that need to be handled at the call site, because this dimensionality can also
  be viral, propagating through the call chain. For example, as a return type, `void` trumps `bool`,
  `bool` trumps `u64`, `u64` trumps `?u64`, and `?u64` trumps `!u64`.

- Ensure that functions run to completion without suspending, so that precondition assertions are
  true throughout the lifetime of the function. These assertions are useful documentation without a
  suspend, but may be misleading otherwise.

- Be on your guard for **[buffer bleeds](https://en.wikipedia.org/wiki/Heartbleed)**. This is a
  buffer underflow, the opposite of a buffer overflow, where a buffer is not fully utilized, with
  padding not zeroed correctly. This may not only leak sensitive information, but may cause
  deterministic guarantees as required by TigerBeetle to be violated.

- Use newlines to **group resource allocation and deallocation**, i.e. before the resource
  allocation and after the corresponding `defer` statement, to make leaks easier to spot.

### Off-By-One Errors

- The usual suspects for off-by-one errors are casual interactions between an `index`, a `count`
  or a `size`. These are all primitive integer types, but should be seen as distinct types, with
  clear rules to cast between them. To go from an `index` to a `count` you need to add one, since
  indexes are 0-based but counts are 1-based. To go from a `count` to a `size` you need to
  multiply by the unit. Again, this is why including units and qualifiers in variable names is
  important.

- Show your intent with respect to division. For example, use `div_exact()`, `div_floor()` or
  `div_ceil()` to show the reader you've thought through all the interesting scenarios where
  rounding may be involved.
