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

pub const baseline = @import("instructions_baseline.zig");
pub const cachegrind = @import("instructions_cachegrind.zig");
pub const measure = @import("instructions_measure.zig");

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

/// The rule name every line carries.
const rule = "instructions";
/// The flag that writes the baseline in place of checking it.
const rewrite_flag = "--rewrite";
/// Bytes in a case's name.
const name_len_max: usize = 64;
/// Lines of a failed run's standard error printed after the report of its case.
const failure_tail_lines: usize = 20;
/// A change in percent smaller than this prints as +0.0.
const change_shown_min: f64 = 0.05;
const exit_success: u8 = 0;
const exit_moved: u8 = 1;
const exit_unusable: u8 = 2;
const output_buffer_bytes: usize = 4096;

/// The target a count was taken on: the architecture and the operating system the engine runs on,
/// which a counted program runs on too.
const target_name = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);

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
    var output_buffer: [output_buffer_bytes]u8 = undefined;
    var error_buffer: [output_buffer_bytes]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(init.io, &output_buffer);
    var errors = Io.File.stderr().writerStreaming(init.io, &error_buffer);
    const context: Context = .{ .arena = arena, .io = init.io, .out = &out.interface, .errors = &errors.interface };
    const status = try start(context, project, given);
    try errors.interface.flush();
    try out.interface.flush();
    std.process.exit(status);
}

pub const Context = struct {
    arena: Allocator,
    io: Io,
    out: *Io.Writer,
    errors: *Io.Writer,
};

/// What one run of the engine does.
pub const Invocation = struct {
    /// Write the baseline in place of checking it.
    rewrite: bool,
    /// The benchmark program every case runs.
    program: []const u8,
    /// The baseline, from the working directory.
    baseline: []const u8,
};

/// Reads the command line, opens the counter, and runs. Returns the exit status.
pub fn start(context: Context, comptime project: Config, given: []const []const u8) !u8 {
    const invocation = parse_arguments(given, project.baseline) orelse {
        try report_line.write(context.errors, .{ .source = rule }, .@"error", rule, "usage: instructions [{s}] <program>", .{rewrite_flag});
        return exit_unusable;
    };
    const counter = cachegrind.Cachegrind.open(context.arena, context.io, project.valgrind_program) catch |failure| {
        try report_line.write(context.errors, .{ .source = project.baseline }, .@"error", rule, "cannot count: {s} did not run ({t}); cachegrind needs valgrind, on Linux", .{ project.valgrind_program, failure });
        return exit_unusable;
    };
    return run(context, project, counter, invocation);
}

/// The invocation the command line asks for, or null when it asks for none.
pub fn parse_arguments(given: []const []const u8, baseline_path: []const u8) ?Invocation {
    return switch (given.len) {
        1 => if (is_flag(given[0])) null else .{ .rewrite = false, .program = given[0], .baseline = baseline_path },
        2 => if (std.mem.eql(u8, given[0], rewrite_flag) and !is_flag(given[1]))
            .{ .rewrite = true, .program = given[1], .baseline = baseline_path }
        else
            null,
        else => null,
    };
}

fn is_flag(argument: []const u8) bool {
    return std.mem.startsWith(u8, argument, "-");
}

/// Checks every case against the baseline, or writes the baseline. `counter` has a `label`, and a
/// `count(program, arguments, rounds)` that returns a `cachegrind.Count`: the instructions one run
/// retired, or why it retired none.
pub fn run(context: Context, comptime project: Config, counter: anytype, invocation: Invocation) !u8 {
    const environment: baseline.Environment = .{ .counter = counter.label, .zig = builtin.zig_version_string, .target = target_name };
    if (invocation.rewrite) return rewrite(context, project, counter, invocation, environment);
    return check(context, project, counter, invocation, environment);
}

fn check(context: Context, comptime project: Config, counter: anytype, invocation: Invocation, environment: baseline.Environment) !u8 {
    const whole: report_line.Location = .{ .source = invocation.baseline };
    const file, const source = switch (try baseline.read(context.arena, context.io, invocation.baseline)) {
        .baseline => |found| .{ found.file, found.source },
        .missing => {
            try report_line.write(context.errors, whole, .@"error", rule, "missing: write it with {s}", .{rewrite_flag});
            return exit_unusable;
        },
        .malformed => |problem| {
            try report_line.write(context.errors, .{ .source = invocation.baseline, .position = problem.position }, .@"error", rule, "{s}", .{problem.message});
            return exit_unusable;
        },
    };
    if (!file.environment().eql(environment)) {
        try report_line.write(context.errors, whole, .@"error", rule, "was counted by {s} under Zig {s} on {s}, and this run counts by {s} under Zig {s} on {s}: write it anew with {s}", .{
            file.counter, file.zig, file.target, environment.counter, environment.zig, environment.target, rewrite_flag,
        });
        return exit_unusable;
    }
    var status = exit_success;
    for (project.cases) |case| {
        if (!try check_case(context, project, counter, invocation, case, file, source)) status = exit_moved;
    }
    if (try report_unnamed(context, project, invocation, file, source)) status = exit_moved;
    return status;
}

/// Counts one case and reports it against the baseline. True when it is within the threshold.
fn check_case(
    context: Context,
    comptime project: Config,
    counter: anytype,
    invocation: Invocation,
    case: Case,
    file: baseline.File,
    source: []const u8,
) !bool {
    const location: report_line.Location = .{ .source = invocation.baseline, .position = baseline.position_of(source, case.name) };
    const entry = file.entry(case.name) orelse {
        try report_line.write(context.out, location, .@"error", rule, "holds no count for case {s}: write it anew with {s}", .{ case.name, rewrite_flag });
        return false;
    };
    const measurement = try counted(context, project, counter, invocation.program, case, location) orelse return false;
    const before = entry.measurement();
    const verdict = measure.judge(before, measurement, project.threshold_per_mille);
    try report_verdict(context.out, location, case.name, before, measurement, verdict, project.threshold_per_mille);
    return verdict == .within;
}

/// The case's cost, or null after reporting why it has none.
fn counted(
    context: Context,
    comptime project: Config,
    counter: anytype,
    program: []const u8,
    case: Case,
    location: report_line.Location,
) !?measure.Measurement {
    const rounds = case.rounds orelse project.rounds;
    const totals = switch (try totals_of(counter, program, case.arguments, rounds)) {
        .totals => |found| found,
        .failed => |failure| {
            try report_line.write(context.out, location, .@"error", rule, "{s} could not be counted: {s}", .{ case.name, failure.reason });
            try write_tail(context.errors, failure.output);
            return null;
        },
    };
    switch (measure.measurement_of(totals, rounds, project.threshold_per_mille)) {
        .measured => |measurement| return measurement,
        .unstable => |disagreement| try report_line.write(context.out, location, .@"error", rule, "{s} is unstable: two runs of {d} rounds differed by {d} instructions; a counted case does the same work on every run", .{ case.name, rounds, disagreement }),
        .long_run_shorter => try report_line.write(context.out, location, .@"error", rule, "{s} counted fewer instructions over {d} rounds than over {d}; the program runs one operation per round", .{ case.name, rounds * 2, rounds }),
    }
    return null;
}

/// What a case's three runs counted, or why one counted nothing.
const Runs = union(enum) {
    totals: measure.Totals,
    failed: cachegrind.Failure,
};

/// A case's three runs: `rounds` twice, then twice as many. Stops at the first run that fails.
fn totals_of(counter: anytype, program: []const u8, arguments: []const []const u8, rounds: u64) !Runs {
    const lengths = [_]u64{ rounds, rounds, rounds * 2 };
    var totals: [lengths.len]u64 = undefined;
    for (lengths, &totals) |length, *total| {
        switch (try counter.count(program, arguments, length)) {
            .total => |counted_total| total.* = counted_total,
            .failed => |failure| return .{ .failed = failure },
        }
    }
    return .{ .totals = .{ .short = totals[0], .short_again = totals[1], .long = totals[2] } };
}

/// The last `failure_tail_lines` lines of a failed run's standard error.
fn write_tail(errors: *Io.Writer, output: []const u8) !void {
    var start_index = output.len;
    var lines: usize = 0;
    while (start_index > 0 and lines <= failure_tail_lines) : (start_index -= 1) {
        if (output[start_index - 1] == '\n') lines += 1;
    }
    try errors.writeAll(output[start_index..]);
}

fn report_verdict(
    out: *Io.Writer,
    location: report_line.Location,
    name: []const u8,
    before: measure.Measurement,
    now: measure.Measurement,
    verdict: measure.Verdict,
    threshold_per_mille: u64,
) !void {
    const change = measure.change_percent(before, now);
    const sign = if (change <= -change_shown_min) "-" else "+";
    const values = .{ name, now.per_operation(), sign, @abs(change), before.per_operation(), measure.percent_of(threshold_per_mille) };
    switch (verdict) {
        .within => try report_line.write(out, location, .note, rule, "{s}: {d:.1} instructions per operation, {s}{d:.1}% from {d:.1}, within {d:.1}%", values),
        .grew => try report_line.write(out, location, .@"error", rule, "{s} grew to {d:.1} instructions per operation, {s}{d:.1}% from {d:.1}, past {d:.1}%", values),
        .shrank => try report_line.write(out, location, .@"error", rule, "{s} shrank to {d:.1} instructions per operation, {s}{d:.1}% from {d:.1}, past {d:.1}%: write the baseline anew with " ++ rewrite_flag ++ " to keep the gain", values),
    }
}

/// Reports every baseline entry that names no configured case. True when there is one.
fn report_unnamed(context: Context, comptime project: Config, invocation: Invocation, file: baseline.File, source: []const u8) !bool {
    var found = false;
    for (file.cases) |entry| {
        if (named(project, entry.name)) continue;
        const location: report_line.Location = .{ .source = invocation.baseline, .position = baseline.position_of(source, entry.name) };
        try report_line.write(context.out, location, .@"error", rule, "counts case {s}, which the configuration does not name: write it anew with {s}", .{ entry.name, rewrite_flag });
        found = true;
    }
    return found;
}

fn named(comptime project: Config, name: []const u8) bool {
    for (project.cases) |case| {
        if (std.mem.eql(u8, case.name, name)) return true;
    }
    return false;
}

/// Counts every case and writes the baseline, unless a case could not be counted.
fn rewrite(context: Context, comptime project: Config, counter: anytype, invocation: Invocation, environment: baseline.Environment) !u8 {
    var entries: std.ArrayList(baseline.Entry) = .empty;
    for (project.cases) |case| {
        if (try rewritten(context, project, counter, invocation, case)) |entry| try entries.append(context.arena, entry);
    }
    if (entries.items.len != project.cases.len) {
        try report_line.write(context.errors, .{ .source = invocation.baseline }, .@"error", rule, "not written: {d} of {d} cases could not be counted", .{ project.cases.len - entries.items.len, project.cases.len });
        return exit_moved;
    }
    const text = try baseline.render(context.arena, environment, entries.items);
    try baseline.write(context.arena, context.io, invocation.baseline, text);
    for (entries.items) |entry| {
        const location: report_line.Location = .{ .source = invocation.baseline, .position = baseline.position_of(text, entry.name) };
        try report_line.write(context.out, location, .note, rule, "{s}: wrote {d:.1} instructions per operation", .{ entry.name, entry.measurement().per_operation() });
    }
    return exit_success;
}

/// One case's entry for a new baseline, or null after reporting why it has none.
fn rewritten(context: Context, comptime project: Config, counter: anytype, invocation: Invocation, case: Case) !?baseline.Entry {
    const location: report_line.Location = .{ .source = invocation.baseline };
    const measurement = try counted(context, project, counter, invocation.program, case, location) orelse return null;
    if (measurement.instructions == 0) {
        try report_line.write(context.out, location, .@"error", rule, "{s} counted no instructions per operation; the program runs one operation per round", .{case.name});
        return null;
    }
    return .{ .name = case.name, .rounds = measurement.rounds, .instructions = measurement.instructions };
}

test {
    _ = baseline;
    _ = cachegrind;
    _ = measure;
    _ = @import("instructions_test.zig");
}
