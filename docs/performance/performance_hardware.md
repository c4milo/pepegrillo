# 4. Build it with the hardware in mind

This is step 4 of the method in [performance.md](performance.md). It gives the rules to write a
change that the hardware runs well.

**Registers.**

- Keep the state of a loop in the locals of a separate function, out of line. Put the rare paths in
  other functions. The compiler then keeps the hot registers for the loop. The locals take the
  width of a register.
- Make inline every function that takes the address of the loop. An out-of-line callee that takes
  it puts the whole loop in memory for the life of the frame.
- Read the disassembly of the loop:
  - A load or a store through the stack pointer inside the loop is a spill.
  - A load or a store through the pointer to the state is a reload. The compiler kept it because a
    store can change the state ([the loop's state](performance_zig.md#the-loops-state)).
- In assembly, give each register a job, and write the plan in the header of the file. Pack what
  does not fit. Spill to the loop's struct what a phase does not need, once per phase.
- Keep the values of a chain of operations in registers. Each result goes to the next operation
  with no store and no load. Write the chain as one function on locals, not as calls that pass
  structs through memory.

**Branches.**

- Fold two checks into one branch where the hardware can do it.
- Use a select, not a branch, for a minimum or a choice when the branch is hard to predict. A
  predicted branch costs less, because a select waits for its condition and for both inputs.
  `@branchHint(.unpredictable)` asks the compiler for the select.
- Keep few branches that depend on the data, and keep them stable within an input. A mispredict
  costs what the table in the appendix says. A narrow core pays more.
- Let the common path fall through. In assembly, put a refill, a second-level lookup or a rare case
  in a block after the loop.
  - A branch that is not taken goes to the block. The block ends with a branch back to the loop.
    This is how the compiler places cold blocks.
  - A loop with the compiler's instructions and one more taken branch per unit ran 2.4% slower on a
    Neoverse N2. An M1 Pro ran it 6% faster.
- Outside assembly, Zig aligns a function, not a loop in it.
  - Put `align(64)` on a hot function. Put it also on each kernel of an object whose text has a
    16-byte alignment. The loops then stay where the function's own code puts them, whatever
    changes before it.
  - In assembly, align the top of a loop to a fetch line only where the judge shows the gain.
    Placement alone moves a result in either direction: by 21 to 38% on one x86-64 core
    ([step 1](performance.md#1-measure-the-gap-first)).

**Memory.**

- Use tables that fit the first-level cache ([#83](https://abseil.io/fast/83)):
  - Entries of the smallest integer that holds the value.
  - A pointer array, not a multiply, for the address of a table.
  - An indexed array, not a chain of pointers.
  - The widest window or the largest table that still fits. A wider window does fewer steps, and
    the table pays for it only while it stays in the first-level cache of the smallest core that
    runs it.
- Put together the fields that one loop touches, hot scalars before tables. Do not let two threads
  write one line.
- The hardware prefetcher handles sequential streams. A reference far back into history misses, at
  a cost that the format sets. A software prefetch that gains on the filter can measure flat on the
  judge, which has different caches. The judge decides.
- Make a copy move chunks of a vector register, and let it write past its end into room that a
  margin holds. Do not use an exact loop. Where a copy overlaps its source, move a width that the
  distance holds. Then no load waits on the store before it.
- An unaligned load of a word, or of a 16- or 32-byte vector, costs almost nothing. A 64-byte load
  across a cache line costs much more.
  - A 64-lane loop ran at a third of its speed on one x86-64 core, and a third slower on another.
  - Start such a loop on a line, after one unaligned block.
  - Time the loop at several offsets from a line, because a buffer is where its allocator put it.
  - An aligned table costs padding inside a named limit. Price it, and ask for it first.
- Do no work per unit across the boundary of a caller. One call takes everything that the buffers
  hold.

**Vectors.**

- Keep every execution unit busy. On a wide core, run independent scalar work in the general
  registers beside the vector work, in the same pass.
- Use every lane of a register. An instruction that works on two lanes does two independent jobs
  for the cost of one, when two jobs exist.
- Keep a verdict in the vector registers across a group of blocks. Move it to a general register
  once per group. Each move costs, and a narrow core pays more for it.
- The bit mask of a compare is one instruction on x86-64. On aarch64 it is several instructions,
  because aarch64 has no such instruction. A path that uses the mask must prove its speed on aarch64
  too.
- A call inside a vector loop spills every live vector register. The System V ABI of x86-64 keeps
  none across a call. aarch64 keeps only the low 64 bits of v8 to v15.
- A wider vector can lose. One instruction can cost five times as much on the cores of one vendor
  as on the cores of another that report the same features.
  - Choose a width and an instruction per CPU, from measurements on that CPU.
  - A pass that stops at the first byte of interest scans the block again at each stop. It lost 37%
    at 64 bytes. A validator does not stop, and it gained 1.4 times from 32 lanes to 64.
  - On an M1 Pro, a scan of one word at a time made 18-digit runs 14% faster and one-digit runs 41%
    slower. Measure the lengths in the inputs before you make a scan wider.

**Batches.**

- Make one pass of a loop take as many units as its margins allow
  ([hints](https://abseil.io/fast/hints.html)):
  - Put units in runs, with one bookkeeping step per run.
  - Make a refill load one word at a time.
  - Make a copy store its first chunks before it looks at its length.
  - Start a lookup before the refill that it can overlap.
- Only fewer dependent steps, or two chains that overlap, make a latency chain shorter. Fewer
  instructions do nothing for it.
- Give the most frequent special case of an operation its own code. A square needs about half the
  word products of a multiplication. A square that ran as a multiplication took 0.81 µs at 32 words
  on an M1 Pro, where a baseline's square took 0.58 µs.
- Do work once for each operation, not once for each round of a loop. Compute before a retry loop
  what each round computes again from inputs the loop does not change. Price the memory that it
  holds against the limit of the appendix.
- Where instructions bind, write each step with the fewest instructions that the instruction set
  gives. A rotation by a multiple of 8 is one byte shuffle. An equal form of a formula can remove
  instructions, as complemented lanes remove most NOT instructions from Keccak's chi.
- A shorter loop is a guess until a paired run shows the gain. One index that stepped over counted
  blocks cut a 16-byte loop from 24 instructions to 16. llvm-mca predicted 15% fewer cycles on a
  Neoverse N2. There, two paired runs measured it 2 to 9% slower over text strings.

**What a profile cannot see.**

- `llvm-mca` over the text of a loop gives its dependency chains and its throughput per iteration
  ([#99](https://abseil.io/fast/99)). It assumes that every load hits the first-level cache. It
  knows only the cores that LLVM models.
- Hardware counters give cycles, instructions and mispredicts per unit, beside the counts of the
  baseline.
