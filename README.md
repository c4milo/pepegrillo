# pepegrillo

pepegrillo is the developer tooling a Zig 0.16 project runs from its build to hold its tree to its
own rules. It has six tools:

- **lint**: a driver that walks the tree and runs rules over Zig and Markdown files, and generic
  rules a project configures: `forbidden_references`, `file_length`, `magic_numbers`,
  `denied_words`, `unbounded_loop`, `relative_import`, `defer_order`, `unreleased_acquire`,
  `markdown`, `static_alignment`, `global_state` and `undefined_fill`. `lint.names` checks at compile time that the
  names a configuration holds still name something, so a rule cannot go quiet when what it guards
  is renamed.
- **complexity**: a cognitive-complexity scorer for every function and `test` block.
- **commit**: a Conventional Commits linter for commit messages, and a `pre-push` hook that runs it.
- **tla**: runs the TLC model checker over every TLA+ model under `spec/tla/`, and checks each
  configuration reaches the verdict it expects.
- **lean**: builds the Lean 4 project under `spec/lean/` with lake.
- **instructions**: counts a project's benchmark cases under cachegrind, and fails a case whose
  instructions per operation moved past the project's threshold from a baseline the project
  commits.

A project states its settings in its own tool entry points. pepegrillo holds the engines and names
no project.

## Use it from a project

Add pepegrillo as a lazy dependency, pinned by hash:

```bash
zig fetch --save=pepegrillo git+https://github.com/c4milo/pepegrillo#<commit>
```

Then mark it lazy in `build.zig.zon`:

```zig
.pepegrillo = .{
    .url = "git+https://github.com/c4milo/pepegrillo#<commit>",
    .hash = "<hash>",
    .lazy = true,
},
```

In `build.zig`, ask for it only when the project is the root build. A project that depends on this
one then never fetches pepegrillo:

```zig
if (b.pkg_hash.len != 0) return;
const pepegrillo = b.lazyDependency("pepegrillo", .{}) orelse return;
const module = pepegrillo.module("pepegrillo");
```

Each tool is an executable whose root is one of the project's files, importing `module` as
`pepegrillo`:

```zig
// tools/lint.zig
const std = @import("std");
const pepegrillo = @import("pepegrillo");
const rules = pepegrillo.lint.rules;

const file_length = rules.file_length.Rule(.{
    .scope = .{ .extensions = &.{ ".zig", ".sh" }, .include_directories = &.{ "src", "tools" } },
});

const Linter = pepegrillo.lint.Linter(.{file_length});

pub fn main(init: std.process.Init) !void {
    return Linter.main(init);
}
```

```zig
// tools/cognitive_complexity.zig
const std = @import("std");
const pepegrillo = @import("pepegrillo");

pub fn main(init: std.process.Init) !void {
    return pepegrillo.complexity.main(init);
}
```

## Formal specifications

A project keeps its formal specifications under `spec/`: TLA+ models in `spec/tla/`, one directory
per model, and one Lean 4 project in `spec/lean/`.

```text
spec/
  tla/
    store/
      Store.tla
      Store.cfg
      Store_crash.cfg
      mutants/
        skip_fsync.cfg
  lean/
    lakefile.toml
    lean-toolchain
```

Each `.cfg` file is one TLC run. Its first comment lines say what TLC must conclude, and may name
the module it checks when no `.tla` file's name prefixes its own:

```text
\* expect: violated
\* module: Store
```

A configuration that expects `holds` passes when every invariant and property holds. One that
expects `violated` passes when TLC finds a behavior that breaks one, which shows the property can
fail. A file in `mutants/` expects `violated` unless it says otherwise.

The `tla` tool pins TLC by release and SHA-256:

```zig
// tools/tla.zig
const std = @import("std");
const pepegrillo = @import("pepegrillo");

pub fn main(init: std.process.Init) !void {
    return pepegrillo.tla.main(init, .{
        .tlc_release = "v1.7.4",
        .tlc_sha256 = "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88",
    });
}
```

It runs the jar `$TLA2TOOLS_JAR` names. Without that variable it fetches the release's
`tla2tools.jar` with curl into `$XDG_CACHE_HOME/pepegrillo`, or `$HOME/.cache/pepegrillo`. It
refuses a jar whose SHA-256 is not the pinned one. TLC needs Java 11 or newer.

The `lean` tool runs `lake build` in `spec/lean/`, which must hold the `lean-toolchain` file elan
reads for the Lean release. lake is found on PATH or at `$HOME/.elan/bin/lake`.

```zig
// tools/lean.zig
const std = @import("std");
const pepegrillo = @import("pepegrillo");

pub fn main(init: std.process.Init) !void {
    return pepegrillo.lean.main(init, .{});
}
```

## Instruction counts

The `instructions` tool holds a project's benchmark cases to the instructions each operation
takes. A time needs a machine running nothing else, and a CI runner is never that machine. A count
is the same on a busy runner as on a quiet one, so it can gate a commit. A count sees no cache miss
and no mispredict, and code that spins or polls counts its wait, so a timed benchmark on a quiet
machine still judges what a count cannot see.

A project names its cases:

```zig
// tools/instructions.zig
const std = @import("std");
const pepegrillo = @import("pepegrillo");

pub fn main(init: std.process.Init) !void {
    return pepegrillo.instructions.main(init, .{
        .cases = &.{
            .{ .name = "cache_hit", .arguments = &.{"cache-hit"} },
            .{ .name = "query_build", .arguments = &.{"query-build"}, .rounds = 200 },
        },
        .threshold_per_mille = 20,
    });
}
```

Its build passes the benchmark program to the tool, once to check and once to write the baseline:

```zig
const instructions = b.addExecutable(.{
    .name = "instructions",
    .root_module = b.createModule(.{
        .root_source_file = b.path("tools/instructions.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "pepegrillo", .module = module }},
    }),
});
const check = b.addRunArtifact(instructions);
check.addArtifactArg(bench);
check.setCwd(b.path("."));
b.step("instructions", "Hold the benchmark cases to their counts").dependOn(&check.step);
const rewrite = b.addRunArtifact(instructions);
rewrite.addArg("--rewrite");
rewrite.addArtifactArg(bench);
rewrite.setCwd(b.path("."));
b.step("instructions-rewrite", "Write the counts anew").dependOn(&rewrite.step);
```

Each case runs `<program> <arguments...> <rounds>`: the program runs the case's operation `rounds`
times and exits 0. The tool counts a run of `rounds` twice, and a run of twice as many once. The
long run less a short one is what `rounds` operations cost, since both pay the same setup. When the
two short runs disagree, the case is unstable and fails: a counted case does the same work on every
run.

A case pins the code path it measures, and the build pins the program's optimize mode and CPU,
which the baseline cannot see. valgrind hides AVX-512 and SVE from a program's CPU probe, so a
program that picks its path at run time takes another path under the counter.

`zig build instructions-rewrite` writes `bench/instructions.zon`, which the project commits in a
commit that says why the counts moved:

```zig
.{
    .counter = "cachegrind 3.22.0",
    .zig = "0.16.0",
    .target = "x86_64-linux",
    .cases = .{
        .{ .name = "cache_hit", .rounds = 1000, .instructions = 153000 },
        .{ .name = "query_build", .rounds = 200, .instructions = 246800 },
    },
}
```

`zig build instructions` fails a case whose cost per operation moved past the threshold either
way, a shrink too, so the baseline follows each gain. It prints each finding at its case's line in
the baseline:

```text
bench/instructions.zon:8:12: error: [instructions] cache_hit grew to 160.2 instructions per operation, +4.7% from 153.0, past 2.0%
```

A baseline counted by another counter, Zig release or target is not compared; it is written anew.
The tool needs valgrind, which runs on Linux: `apt-get install valgrind` on a GitHub runner.
Anywhere else it reports that it cannot count, and exits 2.

## Try an unpushed change

`zig build --fork=<path to a pepegrillo checkout>` builds the project against that checkout in
place of the pinned commit.

## Develop pepegrillo

- `zig build test` runs the lint and the complexity score over pepegrillo itself, every unit test,
  and the format check.
- `zig build hooks` installs the commit-message hook in this clone.

`CLAUDE.md` holds the conventions.
