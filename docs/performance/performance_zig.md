# What Zig 0.16 does to hot code

Part of the performance method in [performance.md](performance.md). Each item was seen in a
measurement or in a disassembly, on Zig 0.16.0 with its LLVM backend unless the item names another
backend. A Zig upgrade rechecks every item, and every exception a project ruled on the strength of
one.

## Safety checks

- ReleaseSafe keeps three checks: slice and array bounds, integer overflow, and `unreachable`,
  which `std.debug.assert` compiles to. Their price depends on the loop. It was 2% in a loop whose
  margins made each check a predicted branch, and 10 to 22% in a loop with a check on nearly every
  add. It depends on the processor too: one workload's checks cost 7 to 10% on a Xeon 8370C, 4 to
  6% on an EPYC 7763 and 1 to 3% on an EPYC 9V45. The same benchmark built ReleaseFast bounds
  their total on each processor.
- `@setRuntimeSafety(false)` covers its own scope. An `inline fn` that the scope calls keeps its
  checks. To run a loop unchecked, set it in every function the loop inlines, from one comptime
  `bool`. A generic type that computed the setting with a comptime method call in each of its
  methods exceeded the comptime branch quota.
- Without the checks, an assertion is a premise the optimizer builds on: `assert(x)` is
  `if (!x) unreachable`, and a false one gives wrong code where a checked build panics.
- An assertion added to let the compiler drop a later bounds check drops nothing unless it compares
  the index with the length that check uses. One against a runtime field added a load and a compare.
  Write indices the compiler can prove instead:
  - Index an array of comptime length with an integer type whose range is that length: `u8` into
    `[256]T`, `u5` into `[32]T`. A `usize` index keeps its check; `x & 0xff` into `[256]T` does
    not.
  - Read a fixed width through one array pointer. `input[position..][0..8]` checks once, where
    eight single-byte reads check eight times: 9 instructions against 64 in ReleaseSafe.
  - Slice once, then index the slice. Indices into the whole input pay a check at every access.
  - `for (a, b) |x, y|` checks the lengths once. A loop index that its own condition bounds carries
    no overflow check; a running sum of values the compiler cannot bound keeps one.

## The loop's state

- Zig emits no type-based alias information. A store through any pointer, of a byte or of a `u32`,
  may change a struct reached through another pointer. So a loop that works on `state.field` loads
  and stores that field again on every iteration. Copy the fields into locals at the loop's entry
  and store them once at its exit. `noalias` on the parameter gives the same code, as a promise
  that nothing checks.
- The locals take the register's width, `usize` or `u64`, and narrow where they are used. A `u7`
  field of a struct that a loop reached through a pointer was spilled and reloaded through the
  stack on every iteration, about 25 cycles each time. A `u9` counter and a `u6` value carried from
  one iteration to the next went through memory as well.
- An array indexed at run time kept its whole struct in memory: once one joined a loop's state,
  the loop's other fields spilled too. Keep such arrays in a struct of their own beside the loop's
  state.
- A function that takes the loop's address and is not inlined keeps the loop's locals in memory for
  the whole frame. One such helper cost 54% on one input; one `pub fn` wrapper taking `*Loop` cost
  40% on two inputs while the median gained 14%. Both became `inline fn`. A method the loop calls
  per step is the same case: a walk whose step LLVM left out of line ran 1.4 to 1.6 times as long
  as the same walk with the step an `inline fn`.
- State at an address known at compile time compiles differently from the same state behind a
  pointer: an encoder's state held in a global `var` ran 20% slower. Benchmark state the way
  callers hold it ([step 1](performance.md#1-measure-the-gap-first)).
- On macOS, every read of a `threadlocal` calls the thread-variable getter (`blr`): 1.56 ns against
  0.94 ns for a global. On Linux the read uses the thread pointer register and makes no call.
  Read a thread-local once, outside the loop.

## Copies and fills

- Debug and ReleaseSafe fill memory declared `undefined` with 0xAA. A function with a local
  `var batch: [512]u64 = undefined` calls `memset` over 4 KiB on every call. One such array cost
  a round trip 396 instructions, and an encoder's scratch arrays filled about 14 KiB a block. Size
  a scratch array to its data, or keep it in the caller's state, where the fill happens once.
- On Linux, a Zig executable contains compiler_rt's `memset`, a loop that stores one byte at a
  time, and that copy serves every `memset` call in the program, with glibc linked or without;
  on macOS, libSystem's `memset` serves it. A 32 KiB `@memset` took 33,500 cycles and 100,000
  instructions on a Neoverse N2, against 1,200 cycles on an M1.
- The 0xAA fill, an `@memset` that LLVM does not expand inline, and a zeroing loop that LLVM
  recognizes all become that call: a loop of 16-byte vector stores over 576 bytes compiled to the
  same `memset` call as `@memset`. On a hot path, clear with vector stores in a loop that passes
  its pointer to `std.mem.doNotOptimizeAway`, which keeps the stores. compiler_rt's `memcpy`
  moves a vector at a time.
- Assigning a struct copies all of it. Copying a fixed-capacity list whole moved 2,448 bytes and
  took a cache hit from 7.0 to 34.3 ns. Copy the used part.
- A function that returned an 8 MiB table by value overflowed an 8 MiB stack. Initialize a large
  value in place, through a pointer.

## Inlining and generic code

- A generic function called with the same comptime arguments from two places has two callers, and
  LLVM may inline it for one benchmark candidate and call it for another. The A/B then measures a
  call; a skew of 15 to 26% was seen. Give setup code a comptime value that no candidate uses.
  Enter each candidate with `@call(.always_inline, ...)`, or with `.never_inline` for every
  candidate when other code must call one of them too.
- `@call(.always_inline, ...)` on a function LLVM already inlined changed its branch layout. A
  change meant to move nothing but a function's alignment adds neither.
- A release build merges functions whose machine code is the same into one symbol. A sampler's
  count for that symbol covers every merged function, and its callers in the binary overcount.
  Read what two instances share from their comptime arguments in the source, and what is out of
  line from the binary.
- A microbenchmark's timed body, inlined into its sampling loop, measured 3 cycles in some builds
  and 4 in others. Put the timed body in a `noinline` function.
- LLVM turned the data-dependent branch of a mispredict benchmark into a select, which removed the
  mispredict the benchmark was built to price. Load the branch's arms through a `*volatile`
  pointer, check the disassembly for the branch, and refuse a result too small to be a mispredict.

## Vector code

- `@Vector` expresses only what LLVM lowers from generic vector operations. It has no carry-less
  multiply, no CRC32 instruction and no dot product into wider lanes, and the shuffles that
  describe a pairwise sum ran slower than the scalar path. These take inline assembly with
  register operands.
- Keep a verdict as a `@Vector(16, u8)` with one bit per rule until the end. Each operation on a
  `@Vector(16, bool)` lowered to a full-width mask with its own compare: 5 instructions a block
  where the integer form took 2.
- `@reduce`, and the `@bitCast` of a bool vector to an integer, move a value from the vector
  registers to a general register. After the compare, the bit mask takes one `pmovmskb` on x86-64,
  and five instructions and a constant load on aarch64. One reduce per 16-byte block held a
  validator to 3 GB/s on a Neoverse N2; OR the verdicts across 64 bytes and reduce once.
- LLVM split a 16-byte load into lane loads when a `@shuffle` read only the vector's low lanes: 24
  loads for four blocks where 4 would do, and the loop at a tenth of its expected speed. An empty
  `asm` that takes and returns the vector keeps the load whole. Put it between the load and the
  shuffles:

  ```zig
  const whole = switch (builtin.cpu.arch) {
      .x86_64 => asm ("" : [ret] "=x" (-> Block) : [in] "0" (block)),
      else => asm ("" : [ret] "=w" (-> Block) : [in] "0" (block)),
  };
  ```

  Look for lane loads in a slow vector loop: `ld1.b` and `ld1.s` on aarch64, `vpinsrb` on x86-64.
- A saturating subtract over an array stays a scalar loop in both release modes: `head.* -|= half`
  over 32 Ki `u16` entries took 8% of an encoder's time. Write the vector:
  `chunk.* = @as(@Vector(16, u16), chunk.*) -| @as(@Vector(16, u16), @splat(half));`.
- x86-64 has 16 vector registers below AVX-512, and two 16-lane loops inlined into one function
  filled them: a function's stack references went from 40 to 113. Keep one vector loop per
  function there, with the rare paths out of line, and measure the shape per caller.
- Zig 0.16 compiles every function in a module for the module's CPU, and no attribute raises one
  function's. A path for AVX2 or AVX-512 is a module of its own, compiled for that level and chosen
  once per call from the CPU found at run time.
- In a program that links libc on aarch64 Linux, `std.os.linux.getauxval` finds nothing;
  `std.c.getauxval` reads the kernel's capability words.

## Inline assembly

- `std.fmt.comptimePrint` takes at most 32 arguments in one call. Build a long template from
  pieces, one print each, joined with `++`.
- `packed` is a keyword, so it cannot name an operand.

## Alignment and statics

- An alignment above the page size does not survive loading. The object file records it, and the
  loader places the image at a page boundary, 16 KiB on Apple Silicon. ReleaseSafe trusts the
  type, folds the arithmetic that finds the aligned address, and reaches `unreachable` in a frame
  that names the wrong function; Debug stops at the assertion. Ask for spare room and align at run
  time, with a comptime bound on the alignment a type may claim.
- Zig 0.16's own x86-64 backend placed a container-level `var` of a struct off the alignment an
  aligned field gives its type, unless the variable restates it:
  `var loop: Loop align(@alignOf(Loop)) = undefined;`. LLVM placed it right. A comptime assert
  cannot see this, because the type's alignment is correct and only the address is wrong.
  pepegrillo's `static-alignment` rule reports a static without it.
- An `undefined` static holds different bytes under that backend than under LLVM: a test that read
  a field it never set passed on aarch64 and failed in Debug on x86-64. Set every field a path
  reads.
- The same backend writes an `undefined` static into `.data`, where LLVM puts it in `.bss`: a
  16 MiB table made a 22 MB object file. Set `use_llvm = true` on an executable with large
  statics.

## Builds and baselines

- A cross build compiles for its target's baseline CPU unless `-Dcpu` names one: `x86_64-linux`
  is x86-64 v1, without AVX2 or BMI2, and `aarch64-linux` is a generic core. A native build uses
  the host's CPU. A baseline that picks AVX2 or BMI2 at run time beats a v1 build for that reason
  alone. Measure at the CPU callers build for, and name it beside the number.
- C compiled in a Zig build takes the build's optimize mode, sanitizers included. In ReleaseSafe
  the trapping checks kept a C loop scalar that ReleaseFast vectorized, and doubled a C baseline's
  instruction count. Build a baseline with its own flags: `sanitize_c = .off` on its module, or
  `-fno-sanitize=all` among its C flags.
- Zig 0.16 builds Debug for x86-64 Linux with its own backend. It refuses `.intel_syntax`, a
  vector indexed by a lane known only at run time, and a 512-bit operand of inline assembly. Set
  `use_llvm = true` on a module that needs LLVM, and run the tests under both backends. Try an
  experimental backend on a runner: one compiled seven modules at once, used 19.5 GiB, and crashed
  a laptop.
- LLVM's Debug build for an x86-64 CPU with AVX-512 cannot pass a `@Vector(N, bool)` across a
  call. A function that takes or returns one is `inline`.
- Zig 0.16.0 cannot build its bundled libc++ for macOS 26, so a C++ baseline builds for Linux
  targets only.
- `zig fetch --save` given `?ref=<tag>` pinned a branch's head once. Pin `?ref=<tag>#<commit>`,
  with the commit from `git ls-remote <repo> 'refs/tags/<tag>^{}'`, and check the hash it records.
- `.zig-cache` keeps every build and removes nothing. Builds across many option sets, a CPU or a
  mutation each, filled 51 GB. Cap it in CI, and clear it after a sweep.
- A Run step that inherits stdio, the default for a step with no output file, holds a global lock,
  so such steps run one at a time: three 1-second commands took 3.24 s, and 1.17 s once each
  checked its exit code with `expectExitCode(0)`. A benchmark's step keeps the lock, so no two
  benchmarks run at once; a test's step checks its exit code.

## Clocks and the standard library

- On macOS, `CLOCK_MONOTONIC` moves in 1 µs steps. `CLOCK_UPTIME_RAW` and `CLOCK_MONOTONIC_RAW`
  move in 41 ns steps, and a read costs about 20 ns on an M1 Pro; `mach_absolute_time` reads the
  same counter in 6 to 8 ns. `std.Io`'s `.awake` clock reads `CLOCK_UPTIME_RAW` there, and `.boot`
  reads `CLOCK_MONOTONIC_RAW`.
- `std.mem.findScalar`, `findScalarPos`, `eql` and `countScalar` run vector loops. `findAny`
  (`indexOfAny`), `findScalarLast` (`lastIndexOfScalar`) and `findSentinel` compare one element
  at a time, and `sliceTo` over a `[*:0]` pointer calls `findSentinel`: over 264 bytes it took
  51.4 ns, against 5.85 ns over a slice. Pass slices, and write a search for several values by
  hand.
- `std.simd.firstTrue` finds the first set lane with two reductions and a select: 25 to 27
  instructions on x86-64 for 32 lanes, where `@ctz(@as(u32, @bitCast(mask)))` takes 4 or 5, and 35
  against 19 on aarch64.
- std's vector loops take their width from `std.simd.suggestVectorLength`, fixed by the build's
  CPU: 16 bytes at the x86-64 baseline and on Apple cores, and 32 with AVX2, on x86-64 v4 and on
  znver4, which prefer 256-bit vectors. On aarch64 a CPU with SVE gets 32 whatever its register
  width; a Neoverse N2's is 128 bits.
- `Io.async` and `Io.Group.async` may run the function before they return. A server that handled
  each connection with `Group.async` served its first connection forever. Use `concurrent` for
  work that must run beside the caller.
- `std.Thread.spawn` returns before the thread runs. A harness that sent work at once to a thread
  it had just started lost its first requests to a retry; wait for the thread to signal that it is
  ready.
- `std.Io.Threaded` holds a worker thread for each sleeping task. 4,096 timers need 4,096 threads,
  past the 2,048 a macOS runner allows a process, so a benchmark of waits under it measures threads.
- Debug is slow for computation: AEGIS ran at about 300 MB/s. A test program that hashes or
  compresses much builds ReleaseSafe, which keeps the checks.
- `std.crypto`'s SHA-256 over 5 MiB took 2.2 ms on an M1 Pro in ReleaseSafe, against 1.3 ms for
  AES-128-GCM and 0.15 ms for a copy. Price the pass before a design adds one ([step
  3](performance.md#3-choose-the-lever)).

## Tests and mutations

- Zig refuses an unused local or parameter, a discarded error set, and code after a `return` that
  is known at compile time. A mutation that causes one of these fails to build, and a harness that
  counts a non-zero exit as `CAUGHT` counts a mutation no test saw. Count `CAUGHT` only when a
  named test fails (`error: '<name>' failed`) or a halt check reports it, and count a build error
  apart.
- Write mutations that build. Add `_ = name;` for a name the mutation stops using; for a name still
  used elsewhere, that line is itself an error, "pointless discard". Change a value in place, as
  `x -| 1`, and keep a condition known only at run time, as `cond and false`, in place of
  `if (true) return`.
- An assertion right before an index into the same slice repeats the bounds check, so a mutation
  that deletes it changes nothing and no test can catch it. Drop such an assertion, and index
  before any side effect, so the bounds check stops the call where the assertion would have.
- A build error shows in 0.6 s with `-fno-emit-bin`, against 9.8 s for a build that emits code:
  check that a mutation compiles before running its tests.
- A mutation caught by a safety panic, an index out of bounds or an `unreachable` reached, proves
  the check only where safety is on. In a loop that runs unchecked, the same fault writes past a
  buffer and reports nothing. For such a loop, require a test that sees the wrong output, and run
  the mutations in Debug or ReleaseSafe.
- `zig build` marks a step that passed but wrote to stderr with ` w`, and prints `failed command:`
  after it; the build summary says what failed. Test output is not always valid UTF-8, so a harness
  decodes it with replacement.
- Zig 0.16.0's test runner does not build in fuzz mode in Debug. Fuzz a ReleaseSafe build.
