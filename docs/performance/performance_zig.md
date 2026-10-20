# What Zig 0.16 does to hot code

This file is part of the performance method in [performance.md](performance.md). Each item comes
from a measurement or a disassembly on Zig 0.16.0 with its LLVM backend. An item that names a
different backend is the exception. At each Zig upgrade, check every item again. Also check every
exception that a project ruled because of an item.

## Safety checks

- ReleaseSafe keeps three checks: slice and array bounds, integer overflow, and `unreachable`.
  `std.debug.assert` compiles to `unreachable`.
  - The cost of the checks depends on the loop. It was 2% in a loop whose margins made each check a
    predicted branch. It was 10 to 22% in a loop with a check on almost every add.
  - The cost depends on the processor too. The checks of one workload cost 7 to 10% on a Xeon
    8370C. They cost 4 to 6% on an EPYC 7763 and 1 to 3% on an EPYC 9V45.
  - The same benchmark built ReleaseFast gives the limit of their total on each processor.
- `@setRuntimeSafety(false)` applies to its own scope only. An `inline fn` that the scope calls
  keeps its checks.
  - To run a loop without checks, set it in every function that the loop inlines, from one comptime
    `bool`.
  - A generic type computed the setting with a comptime method call in each of its methods. It went
    past the comptime branch quota.
- Without the checks, the optimizer takes an assertion as true. `assert(x)` is
  `if (!x) unreachable`. A false assertion gives wrong code where a checked build panics.
- An assertion can let the compiler remove a later bounds check. It does this only when it compares
  the index with the length that the check uses. One assertion against a runtime field added a load
  and a compare. Write indices that the compiler can prove:
  - Index an array of comptime length with an integer type whose range is that length: `u8` into
    `[256]T`, `u5` into `[32]T`. A `usize` index keeps its check. `x & 0xff` into `[256]T` does
    not.
  - Read a fixed width through one array pointer. `input[position..][0..8]` checks once. Eight
    reads of one byte check eight times: 9 instructions against 64 in ReleaseSafe.
  - Slice once, then index the slice. Each index into the whole input pays a check.
  - `for (a, b) |x, y|` checks the lengths once. A loop index that its own condition limits has no
    overflow check. A running sum of values that the compiler cannot limit keeps one.

## The loop's state

- Zig gives LLVM no type-based alias information. A store through any pointer, of a byte or of a
  `u32`, can change a struct that another pointer reaches.
  - So a loop that works on `state.field` loads and stores that field again in each iteration.
  - Copy the fields into locals at the start of the loop, and store them once at its end.
  - `noalias` on the parameter gives the same code. It is a promise that nothing checks.
- Give the locals the width of a register, `usize` or `u64`, and make them narrower where you use
  them.
  - A `u7` field of a struct behind a pointer went through the stack in each iteration. Each time
    cost about 25 cycles.
  - A `u9` counter and a `u6` value kept from one iteration to the next also went through memory.
- An array indexed at run time kept its whole struct in memory. When such an array became part of
  the loop's state, the other fields of the loop spilled too. Keep such arrays in a separate struct
  beside the state of the loop.
- A function that takes the address of the loop and is not inlined keeps the loop's locals in
  memory for the whole frame.
  - One such helper cost 54% on one input.
  - One `pub fn` wrapper that took `*Loop` cost 40% on two inputs, while the median gained 14%.
  - Both became `inline fn`.
  - A method that the loop calls at each step is the same case. A walk whose step LLVM left out of
    line took 1.4 to 1.6 times as long as the walk with an `inline fn` step.
- State at an address known at compile time compiles differently from the same state behind a
  pointer. The state of an encoder in a global `var` ran 20% slower. In a benchmark, hold the state
  as callers hold it ([step 1](performance.md#1-measure-the-gap-first)).
- On macOS, each read of a `threadlocal` calls the getter of the thread variable (`blr`). It took
  1.56 ns against 0.94 ns for a global. On Linux, the read uses the thread pointer register and
  makes no call. Read a thread-local value once, outside the loop.

## Copies and fills

- Debug and ReleaseSafe fill memory declared `undefined` with 0xAA on every call. They do this
  when the function reads one element, and when it reads none.
  - A 512-byte local array took 16 paired vector stores.
  - `var batch: [512]u64 = undefined` calls `memset` over 4 KiB.
  - One such array added 396 instructions to a round trip. Two more took 214 of the 775 cycles in
    the tick of an event loop. The scratch arrays of an encoder filled about 14 KiB per block.
  - Such a function also gets a stack-protector check.
  - Make a scratch array the size of its data, or keep it in the caller's state. There the fill
    occurs once.
- On Linux, a Zig executable contains the `memset` of compiler_rt. It is a loop that stores one
  byte at a time.
  - That copy serves every `memset` call of the program's own code, with glibc linked or not. C
    compiled into the program uses it too.
  - The copy is hidden, so a shared library that the program loads keeps the `memset` of libc.
  - On macOS, the `memset` of libSystem serves every call.
  - A 32 KiB `@memset` took 33,500 cycles and 100,000 instructions on a Neoverse N2. It took 1,200
    cycles on an M1.
- Three things become that call: the 0xAA fill, an `@memset` that LLVM does not expand inline, and
  a zero loop that LLVM recognizes. A loop of 16-byte vector stores over 576 bytes compiled to the
  same `memset` call as `@memset`.
  - On a hot path, clear memory with vector stores in a loop that gives its pointer to
    `std.mem.doNotOptimizeAway`. That call keeps the stores.
  - The `memcpy` of compiler_rt moves one vector at a time.
- The master branch of Zig writes `memset` with vector stores. Zig 0.16.0 does not. Until a release
  has it, a program exports its own `memset`. The linker then uses it in place of the copy in
  compiler_rt. On an M1 Pro with arm64 Linux and glibc linked:
  - A 4 KiB fill took 94 to 100 ns, where compiler_rt took 1,372 to 1,377 ns.
  - A 32 KiB fill took 1.2 to 1.3 µs, where compiler_rt took 11 to 12 µs.
  - A fill of about 512 bytes or less never calls `memset`, because the compiler writes it in
    place.
- A program exports the override: the program that a project ships, and each benchmark program.
  - C code of a baseline that is compiled into the program calls it too.
  - The override is hidden, as the copy in compiler_rt is. So a baseline loaded as a shared library
    keeps the `memset` of libc, which is already fast. Each side then runs a fast `memset`, but not
    the same one.
  - Put the function once in a module that the programs share. That module exports nothing.
  - Put the `comptime` block that exports it in the root of each program, or in a module that only
    programs import.
  - A library exports no override, because the program of its caller owns the symbol.
  - The guard limits the export to Linux and to Zig 0.16. So the override stops at the upgrade.
    Delete it then.

  ```zig
  comptime {
      const zig_0_16 = builtin.zig_version.major == 0 and builtin.zig_version.minor == 16;
      if (builtin.os.tag == .linux and zig_0_16) @export(&memset, .{ .name = "memset" });
  }

  fn memset(dest: ?[*]u8, value: c_int, len: usize) callconv(.c) ?[*]u8 {
      @setRuntimeSafety(false);
      const d = dest orelse return dest;
      const byte: u8 = @truncate(@as(c_uint, @bitCast(value)));
      const fill: @Vector(32, u8) = @splat(byte);
      if (len < 32) {
          for (0..len) |i| {
              d[i] = byte;
              std.mem.doNotOptimizeAway(d);
          }
          return dest;
      }
      for (0..len / 32) |chunk| {
          d[chunk * 32 ..][0..32].* = fill;
          std.mem.doNotOptimizeAway(d);
      }
      d[len - 32 ..][0..32].* = fill;
      return dest;
  }
  ```

  - The value is C's `int`, as C declares it. The function stores its low byte.
  - Both loops are bounded `for` loops, so a lint rule against unbounded loops accepts them.
  - Without its barrier, LLVM 21 changes the short loop into a jump to the entry of this same
    function. The first short fill then never returns.
  - The barrier in the block loop stops a later LLVM from the same change to that loop.
  - A check that disassembles the override and finds no call to `memset` catches a missing
    barrier.
  - `-fno-builtin` on the program is not a substitute. It makes each `@memset` a byte loop in
    place, and nothing calls the new `memset`.
- An assignment of a struct copies all of it. A copy of a whole list of fixed capacity moved 2,448
  bytes. It made a cache hit take 34.3 ns, not 7.0 ns. Copy only the part in use.
- A function that returned an 8 MiB table by value overflowed an 8 MiB stack. Initialize a large
  value in place, through a pointer.

## Inlining and generic code

- A generic function that two places call with the same comptime arguments has two callers. LLVM
  can inline it for one benchmark candidate and call it for another.
  - The A/B then measures a call. A skew of 15 to 26% occurred.
  - Give the setup code a comptime value that no candidate uses.
  - Enter each candidate with `@call(.always_inline, ...)`. When other code must call a candidate
    too, use `.never_inline` for every candidate.
- `@call(.always_inline, ...)` on a function that LLVM already inlined changed its branch layout. A
  change that only moves the alignment of a function forces no inlining, neither `.always_inline`
  nor `.never_inline`.
- A release build merges functions with the same machine code into one symbol.
  - The sampler's count for that symbol includes every merged function. Its callers in the binary
    then show too much.
  - Read in the source what two instances share, from their comptime arguments. Read in the binary
    what is out of line.
- The timed body of a microbenchmark, inlined into its sample loop, measured 3 cycles in some
  builds and 4 in others. Put the timed body in a `noinline` function.
- LLVM changed the data-dependent branch of a mispredict benchmark into a select. This removed the
  mispredict that the benchmark had to price.
  - Load the arms of the branch through a `*volatile` pointer.
  - Look for the branch in the disassembly.
  - Refuse a result that is too small to be a mispredict.

## Vector code

- No loop over a length known only at run time becomes vector code. Zig 0.16 turns off LLVM's loop
  vectorizer for Zig code, to avoid a miscompilation in LLVM 21. `noalias` on the parameters does
  not turn it on again.
  - Six loops stayed scalar code in both release modes, on x86-64 with AVX2 and on aarch64. They
    were an add of one array into another, a sum, a maximum, an xor, a count of one byte and a
    saturating subtract.
  - On an M1 Pro in ReleaseFast, `head.* -|= half` over 32 Ki `u16` entries took 14.6 µs as
    written. It took 0.95 µs with the vector. In an encoder, that loop used 8% of the time.
  - Write the vector:
    `chunk.* = @as(@Vector(16, u16), chunk.*) -| @as(@Vector(16, u16), @splat(half));`.
  - Zig 0.17.0 keeps the vectorizer off. Its release notes expect it again in 0.18.
- LLVM's vectorizer of straight-line code stays on in both release modes. So a loop over a short
  array of comptime length still becomes vector code after LLVM unrolls it.
  - An in-place saturating subtract became vector code up to 32 entries. At 64 it stayed a scalar
    loop.
  - A sum became vector code up to 64 entries.
  - An add of one such array into another stayed scalar until both parameters were `noalias`,
    because the two arrays can overlap.
- `@Vector` expresses only what LLVM can lower from generic vector operations. It has no carry-less
  multiply, no CRC32 instruction and no dot product into wider lanes. The shuffles for a pairwise
  sum ran slower than the scalar path. These operations need inline assembly with register
  operands.
- Keep a verdict as a `@Vector(16, u8)`, with one bit per rule, until the end. Each operation on a
  `@Vector(16, bool)` became a full-width mask with its own compare. That took 5 instructions per
  block, and the integer form took 2.
- `@reduce`, and the `@bitCast` of a bool vector to an integer, move a value from the vector
  registers to a general register.
  - After the compare, the bit mask takes one `pmovmskb` on x86-64. On aarch64 it takes five
    instructions and a constant load.
  - One reduce per 16-byte block held a validator to 3 GB/s on a Neoverse N2.
  - OR the verdicts across 64 bytes, and reduce once.
- LLVM split a 16-byte load into lane loads when a `@shuffle` read only the low lanes of the
  vector. It did 24 loads for four blocks, where 4 loads were enough. The loop ran at a tenth of
  its expected speed. An empty `asm` that takes and returns the vector keeps the load whole. Put it
  between the load and the shuffles:

  ```zig
  const whole = switch (builtin.cpu.arch) {
      .x86_64 => asm ("" : [ret] "=x" (-> Block) : [in] "0" (block)),
      else => asm ("" : [ret] "=w" (-> Block) : [in] "0" (block)),
  };
  ```

  In a slow vector loop, look for lane loads: `ld1.b` and `ld1.s` on aarch64, `vpinsrb` on x86-64.
- Below AVX-512, x86-64 has 16 vector registers. Two 16-lane loops inlined into one function used
  all of them. The stack references of the function went from 40 to 113. On x86-64, keep one vector
  loop per function, with the rare paths out of line. Measure the shape per caller.
- Zig 0.16 compiles every function in a module for the CPU of the module. No attribute changes the
  CPU of one function. A path for AVX2 or AVX-512 is a separate module, compiled for that level.
  The code chooses it once per call, from the CPU that it finds at run time.
- In a program that links libc on aarch64 Linux, `std.os.linux.getauxval` finds nothing.
  `std.c.getauxval` reads the capability words of the kernel.

## Inline assembly

- `std.fmt.comptimePrint` takes at most 32 arguments in one call. Make a long template from parts,
  one print each, joined with `++`.
- `packed` is a keyword, so it cannot be the name of an operand.

## Alignment and statics

- An alignment above the page size does not stay after the load of the program. The object file
  records it, but the loader puts the image at a page boundary, 16 KiB on Apple Silicon.
  - ReleaseSafe trusts the type and folds the arithmetic that finds the aligned address. It then
    gets to `unreachable` in a frame that names the wrong function.
  - Debug stops at the assertion.
  - Ask for spare room and align at run time. Put a comptime limit on the alignment that a type can
    claim.
- The x86-64 backend of Zig 0.16 put a container-level `var` of a struct off the alignment of its
  type. The type had that alignment from an aligned field.
  - The variable must state the alignment again:
    `var loop: Loop align(@alignOf(Loop)) = undefined;`.
  - LLVM put the variable at the correct address.
  - A comptime assert cannot see this, because the alignment of the type is correct. Only the
    address is wrong.
  - pepegrillo's `static-alignment` rule reports a static without the alignment.
- An `undefined` static holds different bytes under that backend than under LLVM. A test that read
  a field it never set passed on aarch64 and failed in Debug on x86-64. Set every field that a path
  reads.
- The same backend writes an `undefined` static into `.data`, where LLVM puts it in `.bss`. A
  16 MiB table made a 22 MB object file. Set `use_llvm = true` on an executable with large
  statics.

## Builds and baselines

- A cross build compiles for the baseline CPU of its target, unless `-Dcpu` names a CPU.
  - `x86_64-linux` is x86-64 v1, without AVX2 or BMI2. `aarch64-linux` is a generic core.
  - A native build uses the CPU of the host.
  - A baseline that selects AVX2 or BMI2 at run time beats a v1 build for that reason only.
  - Measure at the CPU that callers build for, and name it beside the number.
- C compiled in a Zig build gets the optimize mode of the build, sanitizers included. In
  ReleaseSafe, the trap checks kept a C loop scalar that ReleaseFast made vector code. They doubled
  the instruction count of a C baseline. Build a baseline with its own flags: `sanitize_c = .off`
  on its module, or `-fno-sanitize=all` in its C flags.
- clang keeps its loop vectorizer for C compiled in the same build. In ReleaseFast, the loop of a C
  baseline is then vector code, where the same loop in Zig is scalar.
  - The C form of the saturating subtract in [Vector code](#vector-code) took 0.88 µs. The Zig loop
    as written took 14.6 µs.
  - Where the loop of a baseline is vector code, write the Zig vector before you compare the two.
- Zig 0.16 builds Debug for x86-64 Linux with its own backend.
  - That backend refuses `.intel_syntax`, a vector indexed by a lane known only at run time, and a
    512-bit operand of inline assembly.
  - Set `use_llvm = true` on a module that needs LLVM, and run the tests under both backends.
  - Try an experimental backend on a runner. One compiled seven modules at once, used 19.5 GiB, and
    crashed a laptop.
- LLVM's Debug build for an x86-64 CPU with AVX-512 cannot pass a `@Vector(N, bool)` across a
  call. Make `inline` a function that takes or returns one.
- Zig 0.16.0 cannot build its bundled libc++ for macOS 26. So a C++ baseline builds for Linux
  targets only.
- `zig fetch --save` with `?ref=<tag>` once pinned the head of a branch. Pin
  `?ref=<tag>#<commit>`, and get the commit from `git ls-remote <repo> 'refs/tags/<tag>^{}'`.
  Check the hash that it records.
- `.zig-cache` keeps every build and removes nothing. Builds across many option sets, each with a
  CPU or a mutation, filled 51 GB. Put a limit on it in CI, and clear it after a sweep.
- Two source trees that share one `--cache-dir` get each other's binaries.
  - A cache entry names the root file by its path relative to the work directory. It names every
    other file by the absolute path in the tree that compiled it first.
  - A second tree whose root file has the same bytes matches that entry. The check for changes
    then reads the files of the first tree.
  - Two trees with one root file and different imports showed this. The second tree ran the tests
    of the first tree, and 2 passed. With its own cache, the second tree ran its 3 tests, and one
    failed.
  - A mutation verdict from such a tree can be false in either direction.
  - Give each tree, worktrees included, its own cache. Give each side of a paired measurement its
    own cache too.
- A Run step that inherits stdio holds a global lock. This is the default for a step with no output
  file. So such steps run one at a time.
  - Three 1-second commands took 3.24 s. They took 1.17 s when each checked its exit code with
    `expectExitCode(0)`.
  - Let the step of a benchmark keep the lock, so that no two benchmarks run at the same time.
  - Make the step of a test check its exit code.
  - A checked step that passed still prints its standard error under `failed command:`. The ` w`
    item in [Tests and mutations](#tests-and-mutations) tells more.

## Clocks and the standard library

- On macOS, `CLOCK_MONOTONIC` moves in steps of 1 µs.
  - `CLOCK_UPTIME_RAW` and `CLOCK_MONOTONIC_RAW` move in steps of 41 ns. A read costs about 20 ns
    on an M1 Pro.
  - `mach_absolute_time` reads the same counter in 6 to 8 ns.
  - There, the `.awake` clock of `std.Io` reads `CLOCK_UPTIME_RAW`, and `.boot` reads
    `CLOCK_MONOTONIC_RAW`.
- `std.mem.findScalar`, `findScalarPos`, `eql` and `countScalar` run vector loops.
  - `findAny` (`indexOfAny`), `findScalarLast` (`lastIndexOfScalar`) and `findSentinel` compare
    one element at a time.
  - `sliceTo` over a `[*:0]` pointer calls `findSentinel`. Over 264 bytes it took 51.4 ns, against
    5.85 ns over a slice.
  - Give slices. Write a search for several values yourself.
- `std.simd.firstTrue` finds the first set lane with two reductions and a select. On x86-64 for 32
  lanes it takes 25 to 27 instructions, where `@ctz(@as(u32, @bitCast(mask)))` takes 4 or 5. On
  aarch64 it takes 35 against 19.
- The vector loops of std get their width from `std.simd.suggestVectorLength`. The CPU of the build
  sets that width.
  - The width is 16 bytes at the x86-64 baseline and on Apple cores.
  - It is 32 bytes with AVX2, on x86-64 v4 and on znver4, which prefer 256-bit vectors.
  - On aarch64, a CPU with SVE gets 32 bytes, whatever its register width. The register width of a
    Neoverse N2 is 128 bits.
- `Io.async` and `Io.Group.async` can run the function before they return. A server that handled
  each connection with `Group.async` served its first connection forever. Use `concurrent` for work
  that must run beside the caller.
- `std.Thread.spawn` returns before the thread runs. A harness sent work at once to a new thread,
  and lost its first requests to a retry. Wait for the thread to signal that it is ready.
- `std.Io.Threaded` holds a worker thread for each task that sleeps. 4,096 timers need 4,096
  threads. A macOS runner allows 2,048 per process. So a benchmark of waits under it measures
  threads.
- Debug is slow for computation: AEGIS ran at about 300 MB/s. Build a test program that hashes or
  compresses much data in ReleaseSafe, which keeps the checks.
- On an M1 Pro in ReleaseSafe, the SHA-256 of `std.crypto` over 5 MiB took 2.2 ms. AES-128-GCM
  took 1.3 ms, and a copy took 0.15 ms. Price a pass before a design adds one
  ([step 3](performance.md#3-choose-the-lever)).

## Tests and mutations

- Zig refuses an unused local or parameter, a discarded error set, and code after a `return` that
  is known at compile time.
  - A mutation that causes one of these fails to build.
  - A harness that counts a non-zero exit as `CAUGHT` then counts a mutation that no test saw.
  - Count `CAUGHT` only when a named test fails (`error: '<name>' failed`) or a halt check reports
    it. Count a build error separately.
- Write mutations that build:
  - Add `_ = name;` for a name that the mutation stops to use. For a name still used in a different
    place, that line is itself an error, "pointless discard".
  - Change a value in place, as `x -| 1`.
  - Keep a condition known only at run time, as `cond and false`, in place of `if (true) return`.
- An assertion just before an index into the same slice repeats the bounds check. A mutation that
  deletes it changes nothing, and no test can catch it. Remove such an assertion. Index before any
  side effect, so that the bounds check stops the call where the assertion stopped it.
- A build error shows in 0.6 s with `-fno-emit-bin`, and in 9.8 s for a build that emits code.
  Make sure that a mutation compiles before you run its tests.
- A safety panic can catch a mutation: an index out of bounds, or an `unreachable` that the code
  gets to. That proves the check only where safety is on.
  - In a loop without checks, the same fault writes past a buffer and reports nothing.
  - For such a loop, require a test that sees the wrong output.
  - Run the mutations in Debug or ReleaseSafe.
- `zig build` marks with ` w` a step that passed but wrote to stderr, and prints
  `failed command:` after it. The build summary says what failed. Test output is not always valid
  UTF-8, so a harness decodes it with replacement.
- The test runner of Zig 0.16.0 does not build in fuzz mode in Debug. Fuzz a ReleaseSafe build.
