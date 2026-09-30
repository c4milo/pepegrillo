# 4. Build it with the hardware in mind

Step 4 of the method in [performance.md](performance.md): the rules for writing a change so the
hardware runs it well.

**Registers.**

- A loop's state lives in the locals of a function of its own, out of line, with the rare paths in
  other functions, so the compiler keeps the hot registers for the loop. The locals take the
  register's width.
- Any function that takes the loop's address is inline. An out-of-line callee that takes it puts
  the whole loop in memory for the frame's life.
- Read the loop's disassembly. A load or store through the stack pointer inside it is a spill. A
  load or store through the state's pointer is a reload the compiler kept because a store might
  change the state ([the loop's state](performance_zig.md#the-loops-state)).
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
- Outside assembly, Zig aligns a function, not a loop inside it. `align(64)` on a hot function,
  and on each kernel of an object whose text is 16-byte aligned, keeps its loops where its own code
  puts them, whatever changes before it. In assembly, align a loop's top to a fetch line only where
  the judge shows the gain: placement alone moves a result either way, by 21 to 38% on one x86-64
  core ([step 1](performance.md#1-measure-the-gap-first)).

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
- Unaligned loads of a word, or of a 16- or 32-byte vector, cost nothing to speak of. A 64-byte
  load across a cache line does: a 64-lane loop ran at a third of its speed on one x86-64 core,
  a third slower on another. Start such a loop on a line, after one unaligned block, and time it
  at several offsets from a line, since a buffer sits where its allocator put it. Aligning a table
  costs padding inside a named limit, so it is priced and asked for first.
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
  measurements on that CPU. A pass that stops at the first byte of interest rescans the block at
  each stop and lost 37% at 64 bytes, where a validator, with no stop, gained 1.4 times from 32
  lanes to 64. On an M1 Pro, a scan a word at a time sped 18-digit runs 14% and slowed one-digit
  runs 41%: measure the lengths the inputs hold before widening a scan.

**Batching.**

- One pass of a loop takes as many units as its margins allow; units go in runs with one
  bookkeeping per run; a refill loads a word at a time; a copy stores its first chunks before it
  looks at its length; a lookup goes out before the refill it can overlap
  ([hints](https://abseil.io/fast/hints.html)).
- A latency chain shortens only with fewer dependent steps or two chains overlapped; fewer
  instructions do nothing for it.
- A shorter loop is a guess until a paired run shows the gain. Stepping one index over counted
  blocks cut a 16-byte loop from 24 instructions to 16, and llvm-mca predicted 15% fewer cycles
  on a Neoverse N2; there, two paired runs measured it 2 to 9% slower over text strings.

**Seeing what a profile cannot.** `llvm-mca` over a loop's text gives its dependency chains and
its throughput per iteration ([#99](https://abseil.io/fast/99)); it assumes every load hits the
first-level cache, and it knows only the cores LLVM models. Hardware counters give cycles,
instructions and mispredicts per unit beside the baseline's.
