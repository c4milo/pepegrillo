# What Zig 0.16 does to code the compiler runs

This file is part of the performance method in [performance.md](performance.md), and of
[performance_zig.md](performance_zig.md). Its items are about comptime code: a parser, a type
checker or a table that the compiler runs for each item of a schema. Each item comes from a
measurement on Zig 0.16.0. The compiler's semantic analysis runs comptime code, so no backend
changes an item. At each Zig upgrade, check every item again.

- Zig 0.16 runs comptime code in an interpreter. In a Debug build on a 2.1 GHz Xeon, one turn of a
  loop took 3.5 µs, one call 3 to 5 µs, one slice 5 µs and `std.mem.eql` of two short texts 20 µs.
  The same step of a built program takes less than a nanosecond.
  - A parser took the compiler 6.5 ms for a text of 40 octets. A function written by hand, which
    did what the text stated, took it 0.17 ms.
  - Count the steps of comptime code that runs once for each item of a long list.
- `@hasField(E, name)` and `@field(E, name)` find an enum's member by its name in one step,
  whatever the enum's size. A loop of `std.mem.eql` over each name takes one call for each name.
  - A reader compared each identifier with 21 words. With an enum that named each word once, it
    read the same texts in 62% of the time.
  - Declare the names as an enum's members. For names known only from a list, build the enum once
    with `@Enum`.
- The compiler keeps the answer of a comptime call, and gives it again for the same arguments. It
  keeps no answer of a function that calls `@setEvalBranchQuota`. It keeps none of a function that
  calls such a function either, at any depth.
  - Ten calls of one function, whose loop took 50,000 turns, took 203 ms. With
    `@setEvalBranchQuota` in the function, they took 1,584 ms. With it in a function that the
    function calls, they took 1,566 ms.
  - Raise the quota in a function that is the value of a constant:
    `fn Kept(args) type { return struct { const value = compute(args); }; }`. The compiler
    computes `Kept(args).value` once, under the quota that `compute` raises. It answers
    `Kept(args)` from memory. The same ten calls took 204 ms.
  - No test fails when an answer is not kept: only the time shows it. A schema of 2,300 rules
    built in 25.7 s with one raise under its type checker, and in 20.5 s without it.
  - Keep the functions that raise the quota in a file of their own. A test can then refuse the
    builtin's name in each other file that the hot comptime code reads.
- An answer from memory still counts against the quota. The compiler adds the branches of the
  call's first run to the caller's count each time it gives the answer again.
  - A loop of 480 calls of a kept one-line function stayed under the default quota of 1000, and a
    loop of 520 passed it: each call counts 1, and each turn of the loop counts 1.
  - So one evaluation takes the same count in each build, whatever the compiler computed before
    it. A test can state a cost as a quota: `comptime { @setEvalBranchQuota(budget); work(); }`
    stops the build when the work takes more branches than the budget.
  - The compiler says that an evaluation passed its quota, and it never says the count. To find
    the least quota that builds, halve a range.
- A raise of the quota in a comptime call stays raised for the caller. A runtime function that
  loops with `inline for` can then depend on a raise that is not its own.
  - A loop over the 2,000 fields of a message built while a function that it called raised the
    quota. It stopped at the default quota when that raise moved into a constant's value.
  - A function that loops over a long list at comptime raises the quota itself.
- A function that the compiler runs needs a test that runs it at comptime.
  - `var rest = if (signed) text[1..] else text;` compiled as a program, and each test passed. At
    comptime the bounds of `text[1..]` are known, so `rest` took the type of a pointer to an
    array, and `rest = rest[n..]` failed to compile.
  - State `[]const u8` for a variable that holds slices of several lengths.
- Each function that the compiler makes from a generic one took about 0.17 ms in a Debug build.
  - Code that made two functions for each node of a tree took 2.6 ms for a tree of 10 nodes. With
    the helper of each node an `inline fn`, it took 2.1 ms.
  - A helper with one caller is `inline`. Measure a helper with many callers first.
