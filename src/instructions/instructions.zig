//! A project's benchmark cases, held to the instructions each operation takes. A project names its
//! cases; the engine counts each one, compares its cost per operation with a baseline file the
//! project commits, and fails a case that grew or shrank past the project's threshold. A count is
//! the same on a busy runner as on a quiet one, which a time is not, so it can gate a commit.
//!
//! ```zig
//! // tools/instructions.zig
//! const pepegrillo = @import("pepegrillo");
//! pub fn main(init: std.process.Init) !void {
//!     return pepegrillo.instructions.main(init, .{
//!         .cases = &.{.{ .name = "cache_hit", .arguments = &.{"cache-hit"} }},
//!     });
//! }
//! ```
//!
//! Run:  instructions [--rewrite] <program>
//!
//! Each case runs `<program> <arguments...> <rounds>`: the program runs the case's operation
//! `rounds` times and exits 0. The engine counts a run of `rounds` twice and a run of twice as many
//! once, under cachegrind (`instructions_cachegrind.zig`); `instructions_measure.zig` turns the
//! three totals into a cost and a verdict. With `--rewrite` the engine writes what it counted to
//! the baseline (`instructions_baseline.zig`) instead of comparing.
//!
//! One line per case, in the shape `report_line.zig` defines: `note` when the case is within the
//! threshold, `error` when it grew or shrank past it, was unstable, or could not be counted. A case
//! whose run failed is followed by the end of that run's standard error.
//!
//! Exit status: 0 when every case is within the threshold, or the baseline was written; 1 when a
//! case is not, or the baseline and the configuration name different cases; 2 when nothing could
//! be judged: no counter, or a baseline that is missing, malformed, or counted by another counter,
//! Zig release or target.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const report_line = @import("../report_line.zig");
const Context = @import("../context.zig").Context;
const engine = @import("instructions_run.zig");

const baseline = @import("instructions_baseline.zig");
const cachegrind = @import("instructions_cachegrind.zig");
const measure = @import("instructions_measure.zig");

pub const Case = struct {
    /// The case's name in the baseline and in every line the engine prints: letters, digits, `_`
    /// and `-`.
    name: []const u8,
    /// What the program takes before the round count.
    arguments: []const []const u8 = &.{},
    /// Operations in the case's short run, when it needs other than the project's `rounds`.
    rounds: ?u64 = null,
};

pub const Config = struct {
    /// The cases, in the order the engine counts them and writes them.
    cases: []const Case,
    /// The baseline, from the working directory.
    baseline: []const u8 = "bench/instructions.zon",
    /// Operations in each case's short run. The long run takes twice as many.
    rounds: u64 = 1000,
    /// How far a case's cost per operation may move from the baseline's, in thousandths, before
    /// the case fails. 20 is 2%.
    threshold_per_mille: u64 = 20,
    /// valgrind, found on PATH unless the project names a path.
    valgrind_program: []const u8 = "valgrind",
};

/// Bytes in a case's name.
const name_len_max: usize = 64;
const output_buffer_len: usize = 4096;

/// Why a configuration cannot run, which the compile error names.
pub fn check_config(comptime project: Config) ?[]const u8 {
    if (project.cases.len == 0) return "cases names no case";
    if (project.threshold_per_mille == 0 or project.threshold_per_mille >= measure.per_mille_whole) {
        return "threshold_per_mille is not between 1 and 999";
    }
    for (project.cases, 0..) |case, index| {
        if (check_case_config(case, project.rounds)) |reason| return reason;
        for (project.cases[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, case.name)) return "two cases share a name";
        }
    }
    return null;
}

fn check_case_config(case: Case, project_rounds: u64) ?[]const u8 {
    if (case.name.len == 0 or case.name.len > name_len_max) return "a case's name is empty or longer than 64 bytes";
    for (case.name) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '_' and character != '-') {
            return "a case's name holds a byte other than a letter, a digit, _ or -";
        }
    }
    const rounds = case.rounds orelse project_rounds;
    if (rounds == 0 or rounds > baseline.rounds_max) return "a case's rounds are outside 1 to 2^32";
    return null;
}

pub fn main(init: std.process.Init, comptime project: Config) !void {
    comptime if (check_config(project)) |reason| @compileError(reason);
    const arena = init.arena.allocator();
    const all_arguments = try init.minimal.args.toSlice(arena);
    const given = if (all_arguments.len == 0) all_arguments else all_arguments[1..];
    var output_buffer: [output_buffer_len]u8 = undefined;
    var error_buffer: [output_buffer_len]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(init.io, &output_buffer);
    var errors = Io.File.stderr().writerStreaming(init.io, &error_buffer);
    const context: Context = .{ .arena = arena, .io = init.io, .environ = init.environ_map, .out = &out.interface, .errors = &errors.interface };
    const status = try run(&context, project, given);
    try errors.interface.flush();
    try out.interface.flush();
    std.process.exit(status);
}

/// Reads the command line, opens the counter, and runs. Returns the exit status.
pub fn run(context: *const Context, comptime project: Config, given: []const []const u8) !u8 {
    const invocation = engine.parse_arguments(given, project.baseline) catch {
        try report_line.write(context.errors, .{ .source = engine.rule }, .@"error", engine.rule, "usage: instructions [{s}] <program>", .{engine.rewrite_flag});
        return engine.exit_unusable;
    };
    const counter = cachegrind.Cachegrind.open(context.arena, context.io, project.valgrind_program) catch |failure| {
        try report_line.write(context.errors, .{ .source = project.baseline }, .@"error", engine.rule, "cannot count: {s} did not run ({t}); cachegrind needs valgrind, on Linux", .{ project.valgrind_program, failure });
        return engine.exit_unusable;
    };
    return engine.run_counted(context, project, &counter, &invocation);
}

test "the root exports these names alone" {
    try @import("../public_names.zig").expect(@This(), &.{
        "Case", "Config", "check_config", "main", "run",
    });
}

test {
    _ = baseline;
    _ = cachegrind;
    _ = measure;
    _ = engine;
    _ = @import("instructions_test.zig");
}
