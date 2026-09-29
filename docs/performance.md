# Performance work

The method every performance change follows in a project that adopts pepegrillo, for anyone, person
or agent, who touches a hot path. Each project keeps an appendix of its own, `docs/performance.md`
in its tree, with its instruments, its admission rule, its baselines, its costs and the pitfalls it
has paid for; this document is the part they share. The discipline is Abseil's, applied to a tree
that ships no allocation and no I/O on its hot paths: [the index](https://abseil.io/fast/), starting
with [Performance Hints](https://abseil.io/fast/hints.html). Where a step follows one of its
episodes, the episode is linked.

Every change walks six steps, in order: measure the gap, attribute the cost, choose the lever, build
with the hardware in mind, prove it, land it. A skipped step costs days.

## 1. Measure the gap first

- Two instruments, with different jobs: a local filter that answers in a minute, and a judge whose
  numbers the project publishes. The appendix names both. A number from the filter never lands in a
  document; a number from the judge never comes from two runs compared with each other.
- Count what survives noise. Instructions retired per unit of work survive other processes and a
  laptop's clocks; cycles and wall time count only on a machine running nothing else.
- A number is the median of five runs with its spread, every candidate interleaved in one harness
  with pinned versions, on the machine written down beside it ([#39](https://abseil.io/fast/39),
  [#75](https://abseil.io/fast/75), [#88](https://abseil.io/fast/88)).
- A change stays when it wins past the noise in the judge's runs and no input loses past the noise
  in any of them; the appendix states the rule in numbers. Report the losses first, and every
  figure that goes with a speed, such as a stream's compression or a request's size.
- Compare designs per unit of work, not per second ([#7](https://abseil.io/fast/7)): instructions
  per symbol, per frame, per request, per operation.

## 2. Attribute the cost

- Profile in three layers: by function, with a sampler; by inlined source line, with the symbolizer
  over debug information; by instruction, with the disassembly and the sample counts. Look where the
  cost is, not where a tool shines its light ([#74](https://abseil.io/fast/74)).
- Split the whole into the parts the code does not: a harness that stops after a header, a counter
  of the units a stream or a request holds, so that totals become per-unit costs.
- Compare a baseline part by part: sample its binary by function names. Never read its source; the
  baseline is an oracle and a number, not a design.
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

- Structural costs first: a sort per code, a call per symbol, a library call per small copy, a
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
  other functions, so the compiler keeps the hot registers for the loop.
- Any function that takes the loop's address is inline. An out-of-line callee that takes it puts
  the whole loop in memory for the frame's life.
- Read the loop's disassembly: a load or store through the stack pointer inside it is a spill.
- In assembly, allot every register and write the plan in the file's header; pack what does not
  fit; spill what a phase does not need to the loop's struct, once per phase.

**Branches.**

- Fold two checks into one branch where the hardware offers it; select instead of branching for a
  minimum or a choice.
- Keep data-dependent branches few and stable within an input; a mispredict costs what the
  appendix's table says, and a narrow core pays more.
- Align a loop's top to a fetch line.

**Memory.**

- Tables that fit the first-level cache, entries of the smallest integer that holds the value, a
  pointer array in place of a multiply for a table's address, an indexed array in place of a
  pointer chain ([#83](https://abseil.io/fast/83)).
- The fields one loop touches sit together, hot scalars before tables; no two threads write one
  line.
- Sequential streams belong to the hardware prefetcher; a reference far back into history misses,
  at a cost the format dictates.
- A copy moves chunks of a vector register and overruns into room a margin holds, in place of an
  exact loop; where a copy overlaps its source, move a width the distance holds, so no load waits
  on the store before it.
- Unaligned loads of a word or a vector cost nothing to speak of on the targets a project ships
  to; aligning a table costs padding inside a named limit, so it is priced and asked for first.
- No per-unit work across a caller's boundary: one call takes everything the buffers hold.

**Batching.**

- One pass of a loop takes as many units as its margins allow; units go in runs with one
  bookkeeping per run; a refill loads a word at a time; a copy stores its first chunks before it
  looks at its length; a lookup goes out before the refill it can overlap
  ([hints](https://abseil.io/fast/hints.html)).
- A latency chain shortens only with fewer dependent steps or two chains overlapped; fewer
  instructions do nothing for it.

**Seeing what a profile cannot.** `llvm-mca` over a loop's text gives its dependency chains and
its throughput per iteration ([#99](https://abseil.io/fast/99)); hardware counters give cycles,
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
A `NOT CAUGHT` is a missing test, written before the commit. Two masks to expect: a run's last
units handled by the reference path inside a margin, which hides a fault in the loop's tail; and an
effect a later step overwrites.

Check the inputs that do not share the hot path the change touched: the ones made of the unit the
loop handles least, the smallest inputs for a header, the largest for history.

## 6. Land it

- One change per branch, measured alone, with the branch deleted once its numbers are recorded.
- The commit body names the cost removed, the filter's numbers, and each mutation's verdict.
- The judge's runs, compared inside each run, recorded where the project records them; the main
  branch takes the change only when the appendix's rule admits it.
- Never push a performance change unmeasured, and never chain a push after a step that can stop
  halfway.

## What an appendix states

- The filter and the judge: the machines, the commands, where a number is published and where it
  is not.
- The admission rule in numbers: the bar a win or a loss must pass, and how many runs.
- The baselines, and how the project compares against them without reading their source.
- The costs table: what a first-level hit, a miss, a mispredict, a copy and a syscall cost on the
  judge, measured, with the run they came from.
- The pitfalls the project has paid for, as a table of symptom, cause and rule.
- The commands, in one block.
