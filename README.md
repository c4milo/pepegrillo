# pepegrillo

pepegrillo is the developer tooling a Zig 0.16 project runs from its build to hold its tree to its
own rules. It has five tools:

- **lint**: a driver that walks the tree and runs rules over Zig and Markdown files, and generic
  rules a project configures: `forbidden_references`, `file_length`, `magic_numbers`,
  `denied_words`, `unbounded_loop`, `relative_import`, `defer_order`, `unreleased_acquire`,
  `markdown` and `static_alignment`. `lint.names` checks at compile time that the names a configuration holds still name
  something, so a rule cannot go quiet when what it guards is renamed.
- **complexity**: a cognitive-complexity scorer for every function and `test` block.
- **commit**: a Conventional Commits linter for commit messages, and a `pre-push` hook that runs it.
- **tla**: runs the TLC model checker over every TLA+ model under `spec/tla/`, and checks each
  configuration reaches the verdict it expects.
- **lean**: builds the Lean 4 project under `spec/lean/` with lake.

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

## Try an unpushed change

`zig build --fork=<path to a pepegrillo checkout>` builds the project against that checkout in
place of the pinned commit.

## Develop pepegrillo

- `zig build test` runs the lint and the complexity score over pepegrillo itself, every unit test,
  and the format check.
- `zig build hooks` installs the commit-message hook in this clone.

`CLAUDE.md` holds the conventions.
