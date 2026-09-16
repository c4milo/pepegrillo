//! Cognitive-complexity linter for Zig source. A project's entry point forwards `main`:
//!
//! ```zig
//! pub fn main(init: std.process.Init) !void {
//!     return pepegrillo.complexity.main(init);
//! }
//! ```
//!
//! Run:  cognitive_complexity [--max N] [--list] PATH...
//!
//! Each PATH is a file, or a directory walked recursively for `.zig` files with `.zig-cache`,
//! `zig-out` and `.git` skipped. The tool parses each file with `std.zig.Ast`, scores every
//! function and every `test` block, and prints one line per declaration over the threshold,
//! sorted by path and then line, in the shape `report_line.zig` defines:
//!
//!     path:line:column: error: [cognitive-complexity] name scored SCORE (max N)
//!
//! `--list` prints a line for every declaration instead, highest score first, with `note` in
//! place of `error` for a declaration at or under the threshold. Each file that could not be read
//! or scored follows as `path: error: [not-scored] reason`, and one summary line ends the report.
//! The threshold is `default_max_score`, 15, unless `--max` names another; a score equal to the
//! threshold passes.
//!
//! Exit status: 0 when nothing is over the threshold and every file was scored, 1 when something
//! is over or a file was not scored, 2 on a malformed command line or a PATH that cannot be read.
//!
//! Definition: SonarSource Cognitive Complexity (G. Ann Campbell, v1.2), mapped onto Zig syntax
//! as follows. The scorer is `complexity_scorer.zig`, and a test pins every rule below.
//!
//! Structural increments. Each adds 1 plus the nesting level at that point, and the nesting level
//! rises by one inside its body:
//!   - `if`, as a statement or as an expression, with or without a payload capture
//!     (`if (optional) |value|`).
//!   - `switch`: 1 for the whole switch, never one per prong. Prong values and bodies sit one
//!     level deeper than the switch; prongs add no level of their own, and `inline` prongs and
//!     the `else` prong are ordinary prongs.
//!   - `for` and `while`, including `inline for` and `inline while`. The loop condition and
//!     inputs sit at the loop's own level; the body and the `while` continue expression sit one
//!     level deeper.
//!   - `catch`. Every `catch` has an operand, a block or an expression, with or without an
//!     `|err|` payload, so every `catch` is structural and its operand sits one level deeper.
//!   - `orelse` whose operand is a block. The block sits one level deeper.
//!
//! Increments that raise no nesting level. Each adds exactly 1:
//!   - `else` on an `if`, `for`, or `while`, statement or expression. Its body sits one level
//!     deeper, as the first branch's does.
//!   - `else if`: the `if` written after an `else` adds 1 in total, not 2, at any nesting level,
//!     and its body sits at the same level as the first `if`'s body.
//!   - `orelse` whose operand is not a block, such as `orelse return`.
//!   - `break` or `continue` that names a label. An unlabelled `break` or `continue` adds
//!     nothing.
//!   - Each sequence of like boolean operators: `a and b and c` adds 1, `a and b or c` adds 2
//!     because the operator changes, and parentheses start a new sequence, so `a and (b and c)`
//!     adds 2. `!` starts a new sequence the same way, because its operand is a new expression.
//!     A sequence is read from the parsed tree, by operator precedence, not token by token.
//!     `and` binds tighter than `or`, so `a or b and c or d` parses as `(a or (b and c)) or d`:
//!     one `or` sequence holding one `and` sequence, and the score is 2. Read token by token the
//!     operator changes twice and the score would be 3. The tree reading is the one
//!     SonarSource's own implementation uses, and it is the one pinned here.
//!   - Recursion: a call whose callee is a bare identifier equal to the enclosing function's name
//!     adds 1. A call through a field access (`self.name()`, `Self.name()`) adds nothing,
//!     because the tool has no type information to tell which function that names.
//!
//! Nesting. The level rises by one inside the body of every structural increment above, and
//! inside the body of a nested function. Zig allows a function declaration only as a container
//! member, so a nested function is one declared in a `struct`, `enum`, `union`, or `opaque` that
//! itself appears inside a function body. Such a function is scored twice: on its own, and as
//! part of the enclosing function one level deeper. Its parameter and return types count at the
//! enclosing level, and so do those of a function type such as `*const fn (u8) void` written in a
//! body.
//!
//! Constructs that add nothing and raise no level: `defer`, `errdefer`, `comptime` expressions
//! and blocks, `nosuspend`, labelled blocks, `try`, `unreachable`, `return`, `suspend`, `resume`,
//! `asm`, `.?`, `!`, error unions, and every plain expression.
//!
//! Declarations scored: every `fn` with a body, at the top level or as a member of any container
//! at any depth, including containers inside function bodies, inside parameter types, and inside
//! `return struct { ... }` expressions. An `extern` prototype has no body and is not scored.
//! `test` blocks are scored too, under the name the block carries with its quotes, or under
//! `test` when it has none: a test a reader cannot hold in their head checks whatever it happens
//! to do rather than what it says.
//!
//! Limits. A file is reported as not scored, never scored in part, when it does not parse, holds
//! more than `max_functions_per_file` declarations, nests deeper than `max_tree_depth` AST nodes,
//! or is larger than `max_source_bytes`.

const std = @import("std");
const Io = std.Io;

pub const scorer = @import("complexity_scorer.zig");
pub const report = @import("complexity_report.zig");

pub const FunctionScore = scorer.FunctionScore;
pub const ScoreError = scorer.ScoreError;
pub const score_source = scorer.score_source;
pub const max_functions_per_file = scorer.max_functions_per_file;
pub const max_tree_depth = scorer.max_tree_depth;

pub const Options = report.Options;
pub const Report = report.Report;
pub const parse_arguments = report.parse_arguments;
pub const print_report = report.print_report;
pub const default_max_score = report.default_max_score;
pub const max_source_bytes = report.max_source_bytes;
pub const exit_usage = report.exit_usage;

/// Command-line arguments the tool reads before giving up.
const max_arguments: usize = 1024;

/// Bytes buffered for standard output before a flush.
const output_buffer_bytes: usize = 16 * 1024;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const all_arguments = try init.minimal.args.toSlice(arena);
    if (all_arguments.len > max_arguments) return error.TooManyArguments;
    const arguments = if (all_arguments.len == 0) all_arguments else all_arguments[1..];
    const options = parse_arguments(arena, arguments) catch |failure| {
        std.debug.print("error: {s}\n", .{@errorName(failure)});
        report.print_usage();
        std.process.exit(exit_usage);
    };

    // A PATH the caller named and the tool cannot open is a usage error, not a score: exit 2
    // with the path, rather than a stack trace.
    var run: Report = .{
        .arena = arena,
        .io = init.io,
        .working_directory = report.paths.canonical_working_directory(arena, init.io),
    };
    for (options.paths) |path| run.lint_path(path) catch |failure| {
        std.debug.print("error: cannot read '{s}': {s}\n", .{ path, @errorName(failure) });
        std.process.exit(exit_usage);
    };

    var output_buffer: [output_buffer_bytes]u8 = undefined;
    // Streaming, not positional: a positional writer starts at offset 0 and overwrites earlier
    // output when standard output is redirected to a file.
    var writer = Io.File.stdout().writerStreaming(init.io, &output_buffer);
    const status = try print_report(&writer.interface, &run, options);
    std.process.exit(status);
}

test {
    _ = scorer;
    _ = report;
}
