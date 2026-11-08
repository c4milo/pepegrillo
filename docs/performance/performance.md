# Performance work

This folder holds the method for every performance change in a project that adopts pepegrillo. It
is for anyone, person or agent, who changes a hot path. Each project also keeps its own appendix,
`docs/performance.md` in its tree. The appendix holds the project's instruments, admission rule,
baselines, costs and pitfalls. This folder is the part that all projects share.

- This file holds the six steps of the method.
- [performance_hardware.md](performance_hardware.md) holds the rules of step 4 for the hardware.
- [performance_zig.md](performance_zig.md) holds what Zig 0.16 does to hot code.

The discipline comes from Abseil. Here it applies to trees that allocate nothing on their hot paths.
A path can compute over memory or wait on I/O. Abseil's articles are in
[the index](https://abseil.io/fast/). Start with
[Performance Hints](https://abseil.io/fast/hints.html).
Where a step follows one of the articles, the step links it.

Every change goes through six steps, in this order:

1. Measure the gap.
2. Attribute the cost.
3. Choose the lever.
4. Build the change with the hardware in mind.
5. Prove the change.
6. Land the change.

A step that you skip costs days.

## 1. Measure the gap first

- Use two instruments with different jobs. The filter is local and answers in a minute. The judge
  gives the numbers that the project publishes. The appendix names both.
  - Never put a number from the filter in a document.
  - Never take a number from the judge out of two runs compared with each other.
- Count what noise does not change. Other processes and a laptop's clocks do not change the
  instructions that retire per unit of work. Cycles and wall time are valid only on a machine that
  runs nothing else.
  - Instructions are a substitute for time only where instructions bind (step 2).
  - Code that spins or polls retires instructions in proportion to the time it waits.
  - When the filter and the judge disagree, the judge decides.
- A number is the median of five runs, with its spread. The spread is the slowest run minus the
  fastest run, as a share of the median.
  - Put every candidate in one harness, interleaved, with pinned versions.
  - Write down the machine, the Zig version, the optimize mode and the target CPU beside the
    number ([#39](https://abseil.io/fast/39), [#75](https://abseil.io/fast/75),
    [#88](https://abseil.io/fast/88)).
  - Five runs resolve a difference of a few percent. A smaller difference needs more runs or more
    jobs.
- The harness runs the code as its callers do:
  - Run unmeasured rounds first. Then the first candidate does not pay for the warm-up of the
    process. The warm-up is page faults, cold caches, cold branch predictors and a rising clock
    speed.
  - Allocate the state once. Reach it through a pointer, and initialize it in each round, as
    callers do.
  - Inline every candidate in the same way. Consume every result. Use `std.mem.doNotOptimizeAway`
    where nothing else reads a result.
  - Make a timed interval span many steps of its clock. Time a batch, never one operation.
  - Keep setup out of the timed interval. Time the work between rounds, such as a restore of
    state, in a separate row.
  - Put the candidates in one binary where you can. A rebuild alone moves a number. Three binaries
    with the same code on the measured path gave 42.8, 45.0 and 52.7 ns.
  - Compare two builds only when the same harness source made them. A change to the harness
    rebuilds the baseline.
  - Make sure that the harness compiles to the same machine code for every candidate. One caller
    gave the shared timing loop a slice of run-time length. That slice left a bounds check in the
    loop for every row.
- The noise that an input must pass is the larger of two values: its spread, and the floor that
  the appendix sets.
  - A paired job measures the base and the change in one run.
  - A change stays when an input wins past the noise in each of at least two paired jobs.
  - A change stays only when no input loses past the noise in any job.
  - The appendix records the layout noise, which is how far a rebuild alone moves a number. A win
    smaller than the layout noise must also hold on a second CPU model.
  - Report the losses first. Report every figure that goes with a speed too, such as the
    compression of a stream or the size of a request.
- The speed of a baseline can drift between the phases of one paired job. In one job, ten inputs
  lost 4 to 7% against a baseline. The measured code was the same byte for byte in both phases. The
  next job reversed every loss.
  - When a change touches one target, show from the disassembly that the code of the other targets
    did not change.
  - Say that in the report, and judge the change on the target that it touches.
- A move can come from placement and not from the change. This is true when both commits run that
  input on code that differs only in its addresses. To find out:
  1. Build the benchmark for the judge's targets at both commits.
  2. Compare every function within the size of its symbol, with the addresses masked.

  Placement alone moved the same code 21 to 38% on one x86-64 core and up to 14% on another.
- Compare designs per unit of work, not per second ([#7](https://abseil.io/fast/7)). Count
  instructions per symbol, per frame, per request or per operation.
- Some units wait on I/O, such as a request, a message or a lookup. For these units, a number is a
  distribution as well as a rate.
  - Report the median, the 99th and 99.9th percentiles and the maximum. Write the offered load
    beside them.
  - Use a load generator that sends on a schedule. A generator that waits for each reply sends
    nothing while the system stalls. Its percentiles then do not show the stall.
  - Make the buckets of the histogram narrower than the difference that the change claims.
  - A percentile that loses past the noise is a loss.

## 2. Attribute the cost

- Profile in three layers:
  1. By function, with a sampler.
  2. By inlined source line, with the symbolizer and the debug information.
  3. By instruction, with the disassembly and the sample counts.

  Look where the cost is, not where a tool is easy to use ([#74](https://abseil.io/fast/74)).
- On a virtual machine, a sampler can put an event on the wrong instruction. On hosted runners, the
  samples for branch misses fell on the same instructions as the samples for cycles. On such a
  machine, price a branch with counters and A/B runs. Use a sample only to see where the time goes.
- Split the whole into parts that the code does not split. For example, use a harness that stops
  after a header, or a count of the units in a stream or a request. The totals then become costs
  per unit.
- Sometimes no line of the profile holds a tenth of the time. Then count instructions per unit on
  inputs that each hold one kind of unit.
  - Count at two round counts, and take the difference to remove the cost of setup.
  - The cheapest kind gives the base cost. The excess of each other kind gives its part.
  - For example, a number cost 126 instructions against 35 for a baseline, on an M1 Pro.
- Count what a unit costs the kernel: system calls, wakeups and context switches per unit. Get them
  from the counters or the tracepoints of the kernel. On a busy machine, a count is evidence and a
  time is not. A tracer that stops the process at every call changes the batches that it counts.
- Compare a baseline part by part. Sample its binary by function name. Never read its source. The
  baseline is an oracle and a number, not a design.
- Where the judge gives access to the counters, first split its issue slots in the top-down
  method:
  - Slots that the front end left empty.
  - Slots that held work which a mispredict discarded.
  - Slots that stalled on memory or on the execution units.
  - Slots that retired an instruction.

  Linux `perf stat` reports this split on recent Intel, AMD and Neoverse cores. The split tells you
  which resource of the next item to test first.
- Name the resource that binds before you remove anything:
  - Instructions bind when instructions per cycle are high and the instruction ratio matches the
    time ratio.
  - A latency chain binds when fewer instructions give the same time. An example is one lookup that
    waits on the shift of the last symbol.
  - Branches bind when the mispredicts per unit are high. The table in the appendix gives the cost
    of a mispredict.
  - Memory binds at the cost of a miss. Believe it only when the counters show it
    ([#53](https://abseil.io/fast/53), [#62](https://abseil.io/fast/62)).
- Estimate before you build ([#90](https://abseil.io/fast/90)). The number of units times the cost
  per unit is the ceiling of a change. The costs table of the appendix gives the cost per unit. A
  ceiling under a few percent does not get a branch, unless a ruling asks for it.

## 3. Choose the lever

- First remove work that the program does not need. Examples are a pass over a buffer that another
  check already covers, and a value computed per unit that one computation per call can give. Price
  every pass over a buffer before you build on it.
- Then remove structural costs. Examples are a sort per code, a call per symbol and a library call
  per small copy. Others are a frame that spills the registers of a loop, an exit from a loop per
  unit of work, and a syscall per frame. Each change names the cost that it removes
  ([#72](https://abseil.io/fast/72)).
- A machine that steps once per byte is a reference. Do the common shapes directly and send the
  other shapes to the reference. Prove that the two agree on every short input over the letters of
  the grammar.
- Make one tradeoff at a time ([#79](https://abseil.io/fast/79)). Put one change on each branch,
  and measure it alone.
- Remove a change that measures flat, even when its code is easier to read
  ([#9](https://abseil.io/fast/9)). Remove a claim that does not beat the noise, with its code.
- Use the routes in this order:
  1. The checked path stays the reference.
  2. A fast path inside margins that the checked code makes.
  3. Runtime safety off, only in a loop that a ruling names.
  4. Assembly, only where the compiler no longer gains on the judge. Record the decision first, and
     put a table of the loop's accesses in its file.

  The decisions of a project record where it ruled each route.

## 4. Build it with the hardware in mind

[performance_hardware.md](performance_hardware.md) holds the rules of this step. They cover
registers, branches, memory, vectors and batches. They also cover the tools that see what a profile
cannot see.
[performance_zig.md](performance_zig.md) holds what Zig 0.16 does to the code that these rules
shape.

## 5. Prove it

Every fast path gives the same result as the reference path, on every input. Do four proofs,
cheapest first, before you push a branch:

1. Run a first-difference harness. Put an input through the change and through the reference. Print
   both results and the first place where they differ. Run it on the fixtures and on every kind of
   input that the project measures.
2. Run the tests of the module at every input length and every room, with the state moved between
   calls.
3. Run the differential check against the oracle of the project over its corpora, corruptions
   included.
4. Run the fuzzer for a short time.

Then prove the tests. Break each check that the change adds, one at a time, and make sure that a
test fails. A `NOT CAUGHT` is a missing test. Write that test before the commit. Expect four masks:

- The reference path does the last units of a run inside a margin. This hides a fault in the tail
  of the loop.
- A later step overwrites an effect.
- The input of a test never gets to the state that the test names.
- The reference does again the work that a fast loop did not do, so the output stays the same. Test
  what the loop did.

A path for an instruction set that no development machine has runs its tests only on a judge that
has it. Make the benchmark check every path against the reference over seeded inputs before the
timed runs.

Run every check once with nothing broken before you count. A check that fails anyway makes every
mutation look caught. Put a limit on every wait that a failed test can get to, so that a mutation
fails in seconds. Zig adds its own traps to the count: see
[tests and mutations](performance_zig.md#tests-and-mutations).

Check the inputs that do not use the hot path that the change touched. These include the inputs
made of the unit that the loop handles least, the smallest inputs for a header, and the largest
inputs for history.

## 6. Land it

- Put one change on each branch, and measure it alone. Delete the branch after you record its
  numbers.
- In the commit body, name the cost that the change removes, the runs and ratios of the judge, and
  the verdict of each mutation.
- Record the judge's runs, each compared within itself, where the project records them. The main
  branch takes the change only when the rule of the appendix admits it.
- A ruled exception is runtime safety off or a loop in assembly. Measure it again at each Zig
  upgrade against the path that it replaced. Remove it with its code when that path is as fast.
- pepegrillo's `instructions` tool holds each benchmark case to its instructions per operation on
  every commit. A count is the same on a busy runner, and a time is not.
  - A change that moves a count writes the baseline again, and its commit says why.
  - The judge's times still decide what a count cannot see: a miss, a mispredict or a wait.
- Record each published comparison again after each change that claims one of its rows. An old
  record hides a gain and sends the next change to a gap that is already closed.
- Never push a performance change that you did not measure. Never chain a push after a step that
  can stop before it completes.

## What an appendix states

- The filter and the judge: the machines, the commands, and where a number is published and where
  it is not.
- The admission rule in numbers:
  - The floor that a win or a loss must pass.
  - The layout noise that a rebuild alone gives on the judge.
  - How many runs and jobs.
- For a unit that waits on I/O, the offered loads and the percentiles that the judge reports.
- The cases that the instruction count holds, and its threshold, when the project runs the
  `instructions` tool.
- The baselines, and how the project compares against them without a read of their source.
- The costs table: the cost on the judge of a first-level hit, a miss, a mispredict, a copy and a
  syscall. Each cost is measured, with the run it came from.
- The pitfalls that the project paid for, as a table of symptom, cause and rule. A pitfall that
  belongs to Zig and not to the project moves to [performance_zig.md](performance_zig.md).
- The commands, in one block.
