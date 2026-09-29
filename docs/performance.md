# Performance work

The method every performance change follows in a project that adopts pepegrillo, for anyone, person
or agent, who touches a hot path. Each project keeps an appendix of its own, `docs/performance.md`
in its tree, with its instruments, its admission rule, its baselines, its costs and the pitfalls it
has paid for; this document is the part they share, and its last section holds what Zig 0.16 does
to hot code. The discipline is Abseil's, applied to trees that allocate nothing on their hot
paths, whether a path computes over memory or waits on I/O: [the index](https://abseil.io/fast/),
starting with [Performance Hints](https://abseil.io/fast/hints.html). Where a step follows one of
its episodes, the episode is linked.

Every change walks six steps, in order: measure the gap, attribute the cost, choose the lever, build
with the hardware in mind, prove it, land it. A skipped step costs days.

## 1. Measure the gap first

- Two instruments, with different jobs: a local filter that answers in a minute, and a judge whose
  numbers the project publishes. The appendix names both. A number from the filter never lands in a
  document; a number from the judge never comes from two runs compared with each other.
- Count what survives noise. Instructions retired per unit of work survive other processes and a
  laptop's clocks; cycles and wall time count only on a machine running nothing else. Instructions
  stand in for time only where instructions bind (step 2), and code that spins or polls retires
  instructions in proportion to the time it waits. When the filter and the judge disagree, the judge
  decides.
- A number is the median of five runs with its spread, the slowest run less the fastest as a share
  of the median. Every candidate is interleaved in one harness with pinned versions, on the machine
  written down beside it, with the Zig version, the optimize mode and the CPU the build targets
  ([#39](https://abseil.io/fast/39), [#75](https://abseil.io/fast/75),
  [#88](https://abseil.io/fast/88)). Five runs resolve a difference of a few percent; a smaller
  bar needs more runs or more jobs.
- The harness runs the code the way its callers do:
  - Unmeasured rounds come first, so the first candidate does not pay the process's warm-up: page
    faults, cold caches and branch predictors, a processor still raising its clock speed.
  - State is allocated once, reached through a pointer and initialized each round, as callers hold
    it.
  - Every candidate is inlined the same way, and every result is consumed, with
    `std.mem.doNotOptimizeAway` where nothing else reads it.
  - A timed interval spans many steps of its clock: time a batch, never one operation.
  - Setup stays out of the timed interval. Work between rounds, such as restoring state, is timed
    in a row of its own.
  - Candidates share one binary where they can. A rebuild alone moves a number: three binaries
    with the same code on the measured path gave 42.8, 45.0 and 52.7 ns.
  - Two builds compare only when the same harness source made them; a change to the harness
    rebuilds the baseline.
- The noise an input must pass is the larger of its spread and the floor the appendix sets. A
  change stays when an input wins past the noise in every one of at least two paired jobs, each
  measuring the base and the change in one run, and no input loses past the noise in any job. A
  win smaller than the layout noise the appendix records must hold on a second CPU model too,
  since a rebuild alone moves a number that far. Report the losses first, and every figure that
  goes with a speed, such as a stream's compression or a request's size.
- A baseline's own speed can drift between the phases of one paired job. In one job, ten inputs
  lost 4 to 7% against a baseline although the code measured was byte for byte the same in both
  phases, and the next job reversed every loss. When a change touches one target, show from the
  disassembly that the other targets' code is unchanged, say so, and judge the change on the
  target it touches.
- Compare designs per unit of work, not per second ([#7](https://abseil.io/fast/7)): instructions
  per symbol, per frame, per request, per operation.
- Where the unit waits on I/O, such as a request, a message or a lookup, the number is a
  distribution as well as a rate: the median, the 99th and 99.9th percentiles and the maximum, at
  an offered load written beside them. The load comes from a generator that sends on a schedule. A
  generator that waits for each reply sends nothing while the system stalls, so its percentiles
  leave the stall out. The histogram's buckets are narrower than the difference the change claims,
  and a percentile that loses past the noise is a loss.

## 2. Attribute the cost

- Profile in three layers: by function, with a sampler; by inlined source line, with the symbolizer
  over debug information; by instruction, with the disassembly and the sample counts. Look where the
  cost is, not where a tool shines its light ([#74](https://abseil.io/fast/74)).
- A sampler on a virtual machine can charge an event to the wrong instruction: on hosted runners,
  samples taken on branch misses landed on the same instructions as samples taken on cycles.
  There, price a branch with counters and A/B runs, and read a sample only as where the time goes.
- Split the whole into the parts the code does not: a harness that stops after a header, a counter
  of the units a stream or a request holds, so that totals become per-unit costs.
- Count what a unit costs the kernel: system calls, wakeups and context switches per unit, from the
  kernel's counters or its tracepoints. On a busy machine a count is evidence where a time is not.
  A tracer that stops the process at every call changes the batching it counts.
- Compare a baseline part by part: sample its binary by function names. Never read its source; the
  baseline is an oracle and a number, not a design.
- Where the judge exposes the counters, split its issue slots first, the top-down way: slots the
  front end left empty, slots spent on work a mispredict threw away, slots stalled on memory or on
  the execution units, and slots that retired an instruction. Linux `perf stat` reports the split
  on recent Intel, AMD and Neoverse cores, and it says which resource below to test first.
- Name the binding resource before cutting anything. Instructions bind when instructions per cycle
  are high and the instruction ratio matches the time ratio. A latency chain binds when a cut of
  instructions measures flat: one lookup waiting on the last symbol's shift. Branches bind when
  mispredicts per unit are high, at a cost the appendix's table gives. Memory binds at the cost of
  a miss, which needs the counters before anyone believes it ([#53](https://abseil.io/fast/53),
  [#62](https://abseil.io/fast/62)).
- Estimate before building ([#90](https://abseil.io/fast/90)): units times the cost per unit,
  from the appendix's costs table, is a change's ceiling. A ceiling under a few percent is no
  branch, unless a ruling asks for it.

## 3. Choose the lever

- Work the program need not do goes first: a pass over a buffer that another check already covers,
  a value computed per unit that one computation per call would give. Price every pass over a
  buffer before building on it.
- Then structural costs: a sort per code, a call per symbol, a library call per small copy, a
  frame that spills a loop's registers, an exit from a loop per unit of work, a syscall per frame.
  Each names the cost it removes ([#72](https://abseil.io/fast/72)).
- One tradeoff at a time ([#79](https://abseil.io/fast/79)): one change per branch, measured alone.
- A change that measures flat leaves, however well it reads ([#9](https://abseil.io/fast/9)); a
  claim that does not beat the noise leaves with its code.
- The routes, in order: the checked path stays the reference; a fast path inside margins the
  checked code sets up; runtime safety off only where a ruling names the loop; assembly only where
  the compiler has stopped gaining on the judge, with the decision recorded first and a table of
  the loop's accesses in its file. A project's decisions record where each route was ruled.

## 4. Build it with the hardware in mind

**Registers.**

- A loop's state lives in the locals of a function of its own, out of line, with the rare paths in
  other functions, so the compiler keeps the hot registers for the loop. The locals take the
  register's width.
- Any function that takes the loop's address is inline. An out-of-line callee that takes it puts
  the whole loop in memory for the frame's life.
- Read the loop's disassembly. A load or store through the stack pointer inside it is a spill. A
  load or store through the state's pointer is a reload the compiler kept because a store might
  change the state ([the loop's state](#the-loops-state)).
- In assembly, allot every register and write the plan in the file's header; pack what does not
  fit; spill what a phase does not need to the loop's struct, once per phase.

**Branches.**

- Fold two checks into one branch where the hardware offers it.
- Select instead of branching for a minimum or a choice when the branch is hard to predict. A
  predicted branch costs less, since a select waits for its condition and for both inputs.
  `@branchHint(.unpredictable)` asks the compiler for the select.
- Keep data-dependent branches few and stable within an input; a mispredict costs what the
  appendix's table says, and a narrow core pays more.
- The common path falls through. In assembly, a refill, a second-level lookup or a rare case goes
  in a block after the loop, entered by a branch left untaken and ending in a branch back to the
  loop, as the compiler places cold blocks. A loop with the compiler's instructions and one more
  taken branch per unit ran 2.4% slower on a Neoverse N2, where an M1 Pro ran it 6% faster.
- In assembly, align a loop's top to a fetch line only where the judge shows the gain. Alignment
  alone moves a result a few percent either way, and outside assembly Zig gives no control of it.

**Memory.**

- Tables that fit the first-level cache, entries of the smallest integer that holds the value, a
  pointer array in place of a multiply for a table's address, an indexed array in place of a
  pointer chain ([#83](https://abseil.io/fast/83)).
- The fields one loop touches sit together, hot scalars before tables; no two threads write one
  line.
- Sequential streams belong to the hardware prefetcher; a reference far back into history misses,
  at a cost the format dictates. A software prefetch that gains on the filter can measure flat on
  the judge, whose caches differ, so the judge decides it.
- A copy moves chunks of a vector register and overruns into room a margin holds, in place of an
  exact loop; where a copy overlaps its source, move a width the distance holds, so no load waits
  on the store before it.
- Unaligned loads of a word or a vector cost nothing to speak of on the targets a project ships
  to; aligning a table costs padding inside a named limit, so it is priced and asked for first.
- No per-unit work across a caller's boundary: one call takes everything the buffers hold.

**Vectors.**

- Keep a verdict in the vector registers across a group of blocks, and move it to a general
  register once per group. Each move costs, and a narrow core pays more for it.
- A compare's bit mask is one instruction on x86-64 and several on aarch64, which has no such
  instruction. A path built on the mask proves its speed on aarch64 too.
- A call inside a vector loop spills every live vector register: x86-64's System V ABI keeps none
  across a call, and aarch64 keeps only the low 64 bits of v8 to v15.
- A wider vector can lose, and one instruction can cost five times as much on one vendor's cores
  as on another's that report the same features. Choose a width and an instruction per CPU, from
  measurements on that CPU.

**Batching.**

- One pass of a loop takes as many units as its margins allow; units go in runs with one
  bookkeeping per run; a refill loads a word at a time; a copy stores its first chunks before it
  looks at its length; a lookup goes out before the refill it can overlap
  ([hints](https://abseil.io/fast/hints.html)).
- A latency chain shortens only with fewer dependent steps or two chains overlapped; fewer
  instructions do nothing for it.

**Seeing what a profile cannot.** `llvm-mca` over a loop's text gives its dependency chains and
its throughput per iteration ([#99](https://abseil.io/fast/99)); it assumes every load hits the
first-level cache, and it knows only the cores LLVM models. Hardware counters give cycles,
instructions and mispredicts per unit beside the baseline's.

## 5. Prove it

Every fast path gives what the reference path gives, on every input. Four proofs, cheapest first,
all before a branch is pushed:

1. A first-difference harness: run an input through the change and through the reference, print
   both outcomes and the first place they differ. Run it on the fixtures and on every kind of
   input the project measures.
2. The module's tests, at every input length and every room, the state moved between calls.
3. The differential check against the project's oracle over its corpora, corruptions included.
4. The fuzzer, a short pass.

Then prove the tests: break each check the change adds, one at a time, and require a test to fail.
A `NOT CAUGHT` is a missing test, written before the commit. Three masks to expect: a run's last
units handled by the reference path inside a margin, which hides a fault in the loop's tail; an
effect a later step overwrites; and a test whose input never reaches the state the test names.

Run every check once with nothing broken before counting, since a check that fails anyway makes
every mutation look caught. Bound every wait a failing test can reach, so a mutation fails in
seconds. Zig adds traps of its own to the count: see [tests and mutations](#tests-and-mutations).

Check the inputs that do not share the hot path the change touched: the ones made of the unit the
loop handles least, the smallest inputs for a header, the largest for history.

## 6. Land it

- One change per branch, measured alone, with the branch deleted once its numbers are recorded.
- The commit body names the cost removed, the judge's runs and ratios, and each mutation's
  verdict.
- The judge's runs, compared inside each run, recorded where the project records them; the main
  branch takes the change only when the appendix's rule admits it.
- A ruled exception, runtime safety off or a loop in assembly, is measured again at each Zig
  upgrade against the path it replaced, and leaves with its code once that path matches it.
- Never push a performance change unmeasured, and never chain a push after a step that can stop
  halfway.

## What an appendix states

- The filter and the judge: the machines, the commands, where a number is published and where it
  is not.
- The admission rule in numbers: the floor a win or a loss must pass, the layout noise a rebuild
  alone gives on the judge, and how many runs and jobs.
- For a unit that waits on I/O, the offered loads and the percentiles the judge reports.
- The baselines, and how the project compares against them without reading their source.
- The costs table: what a first-level hit, a miss, a mispredict, a copy and a syscall cost on the
  judge, measured, with the run they came from.
- The pitfalls the project has paid for, as a table of symptom, cause and rule. A pitfall that
  belongs to Zig and not to the project moves to the next section of this document.
- The commands, in one block.

## What Zig 0.16 does to hot code

Each item was seen in a measurement or in a disassembly, on Zig 0.16.0 with its LLVM backend
unless the item names another backend. A Zig upgrade rechecks every item, and every exception a
project ruled on the strength of one.

### Safety checks

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

### The loop's state

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
  callers hold it (step 1).
- On macOS, every read of a `threadlocal` calls the thread-variable getter (`blr`): 1.56 ns against
  0.94 ns for a global. On Linux the read uses the thread pointer register and makes no call.
  Read a thread-local once, outside the loop.

### Copies and fills

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

### Inlining and generic code

- A generic function called with the same comptime arguments from two places has two callers, and
  LLVM may inline it for one benchmark candidate and call it for another. The A/B then measures a
  call; a skew of 15 to 26% was seen. Give setup code a comptime value that no candidate uses.
  Enter each candidate with `@call(.always_inline, ...)`, or with `.never_inline` for every
  candidate when other code must call one of them too.
- A release build merges functions whose machine code is the same into one symbol. A sampler's
  count for that symbol covers every merged function, and its callers in the binary overcount.
  Read what two instances share from their comptime arguments in the source, and what is out of
  line from the binary.
- A microbenchmark's timed body, inlined into its sampling loop, measured 3 cycles in some builds
  and 4 in others. Put the timed body in a `noinline` function.
- LLVM turned the data-dependent branch of a mispredict benchmark into a select, which removed the
  mispredict the benchmark was built to price. Load the branch's arms through a `*volatile`
  pointer, check the disassembly for the branch, and refuse a result too small to be a mispredict.

### Vector code

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

### Inline assembly

- `std.fmt.comptimePrint` takes at most 32 arguments in one call. Build a long template from
  pieces, one print each, joined with `++`.
- `packed` is a keyword, so it cannot name an operand.

### Alignment and statics

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

### Builds and baselines

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

### Clocks and the standard library

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
  AES-128-GCM and 0.15 ms for a copy. Price the pass before a design adds one (step 3).

### Tests and mutations

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
