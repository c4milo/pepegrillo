# pepegrillo

pepegrillo is the developer tooling a Zig 0.16 project runs from its build to hold its tree to its
own rules. It has three tools:

- **lint**: a driver that walks the tree and runs rules over Zig and Markdown files, and generic
  rules a project configures: `forbidden_references`, `file_length`, `magic_numbers`,
  `denied_words`, `unbounded_loop`, `relative_import`, `defer_order` and `markdown`.
- **complexity**: a cognitive-complexity scorer for every function and `test` block.
- **commit**: a Conventional Commits linter for commit messages, and a `pre-push` hook that runs it.

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

## Try an unpushed change

`zig build --fork=<path to a pepegrillo checkout>` builds the project against that checkout in
place of the pinned commit.

## Develop pepegrillo

- `zig build test` runs the lint and the complexity score over pepegrillo itself, every unit test,
  and the format check.
- `zig build hooks` installs the commit-message hook in this clone.

`CLAUDE.md` holds the conventions.
