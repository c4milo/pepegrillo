# Performance work

The method every performance change follows in a project that adopts pepegrillo, for anyone, person
or agent, who touches a hot path. Each project keeps an appendix of its own, `docs/performance.md`
in its tree, with its instruments, its admission rule, its baselines, its costs and the pitfalls it
has paid for; this folder is the part they share. This file holds the method's six steps;
[performance_hardware.md](performance_hardware.md) holds step 4's rules for the hardware, and
[performance_zig.md](performance_zig.md) what Zig 0.16 does to hot code. The discipline is Abseil's,
applied to trees that allocate nothing on their hot paths, whether a path computes over memory or
waits on I/O: [the index](https://abseil.io/fast/), starting with
[Performance Hints](https://abseil.io/fast/hints.html). Where a step follows one of its episodes,
the episode is linked.

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
    rebuilds the baseline. The harness also compiles to the same machine code for every candidate:
    one caller that passed the shared timing loop a slice whose length was known only at run time
    left a bounds check in that loop for every row.
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
- A move is placement, not the change's, when the program built at both commits runs that input on
  code identical apart from its addresses: build the benchmark for the judge's targets at both
  commits, and compare every function, addresses masked, within its symbol's size. Placement alone
  moved identical code 21 to 38% on one x86-64 core and up to 14% on another.
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
- When no profile line holds a tenth of the time, count instructions per unit on inputs of one
  kind of unit each, at two round counts differenced to cancel setup. The cheapest kind gives the
  base cost, and each kind's excess its part: a number's 126 against a baseline's 35, on an M1 Pro.
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
- A machine that steps once per byte is a reference: take the common shapes directly, leave the
  rest to it, and prove the two agree on every short input over the grammar's letters.
- One tradeoff at a time ([#79](https://abseil.io/fast/79)): one change per branch, measured alone.
- A change that measures flat leaves, however well it reads ([#9](https://abseil.io/fast/9)); a
  claim that does not beat the noise leaves with its code.
- The routes, in order: the checked path stays the reference; a fast path inside margins the
  checked code sets up; runtime safety off only where a ruling names the loop; assembly only where
  the compiler has stopped gaining on the judge, with the decision recorded first and a table of
  the loop's accesses in its file. A project's decisions record where each route was ruled.

## 4. Build it with the hardware in mind

[performance_hardware.md](performance_hardware.md) holds this step's rules: registers, branches,
memory, vectors, batching, and the tools that see what a profile cannot.
[performance_zig.md](performance_zig.md) holds what Zig 0.16 does to the code those rules shape.

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
A `NOT CAUGHT` is a missing test, written before the commit. Four masks to expect: a run's last
units handled by the reference path inside a margin, which hides a fault in the loop's tail; an
effect a later step overwrites; a test whose input never reaches the state the test names; and a
fast loop whose undone work the reference redoes, the output the same: test what the loop took.

A path for an instruction set no development machine has runs its tests only where the judge has
it. Have the benchmark check every path against the reference over seeded inputs before timing.

Run every check once with nothing broken before counting, since a check that fails anyway makes
every mutation look caught. Bound every wait a failing test can reach, so a mutation fails in
seconds. Zig adds traps of its own to the count: see [tests and
mutations](performance_zig.md#tests-and-mutations).

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
  belongs to Zig and not to the project moves to [performance_zig.md](performance_zig.md).
- The commands, in one block.
