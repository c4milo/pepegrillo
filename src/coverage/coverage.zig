//! A project's line coverage: the share of the lines in each of its directories that its test
//! binaries and other programs run. A project names its directories; the engine runs each program
//! under kcov (`coverage_kcov.zig`), merges the runs, and sums kcov's report for each directory
//! (`coverage_report.zig`).
//!
//! ```zig
//! // tools/coverage.zig
//! const pepegrillo = @import("pepegrillo");
//! pub fn main(init: std.process.Init) !void {
//!     return pepegrillo.coverage.main(init, .{
//!         .directories = &.{ "src/store", "src/wire" },
//!     });
//! }
//! ```
//!
//! Run:  coverage <program>...
//!
//! Each program runs with no argument, in the working directory. kcov reads the line table that
//! the compiler writes, so a program is built in Debug with `use_llvm = true`: Zig's own x86-64
//! backend writes an incomplete one. kcov finds the sources at the paths the compiler saw, so the
//! programs are built in the working directory of the run. Zig compiles only the functions that
//! code references, so a function that no test references has no line to count. A test that calls
//! `std.testing.refAllDecls` on a file makes its functions count.
//!
//! One line per directory, in the shape `report_line.zig` defines, then a total at `output`:
//!
//!     src/store: note: [coverage] 91.6% of 1204 lines
//!     zig-out/coverage: note: [coverage] total 88.4% of 3020 lines
//!
//! kcov writes its report in HTML to `output` too. The engine deletes `output` before each run,
//! because kcov adds a new run to the lines that an earlier run left there.
//!
//! Exit status: 0 when every program exited with status 0; 1 when a program did not, after the
//! report; 2 when nothing could be judged: no programs, no kcov or another release than the pin,
//! a directory that does not exist, or no line counted in any directory.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const report_line = @import("../report_line.zig");
const Context = @import("../context.zig").Context;
const write_tail = @import("../instructions/instructions_run.zig").write_tail;

const counter = @import("coverage_kcov.zig");
const report = @import("coverage_report.zig");

pub const Config = struct {
    /// The directories whose lines the engine counts, from the working directory: one line each.
    /// No directory holds another.
    directories: []const []const u8,
    /// Where kcov writes its runs and its report, from the working directory. The engine deletes
    /// it before each run.
    output: []const u8 = "zig-out/coverage",
    /// kcov, found on PATH unless the project names a path.
    kcov_program: []const u8 = "kcov",
    /// The major release of kcov the project pins. Another release can count other lines.
    kcov_release: u32 = 43,
};

const rule = report.rule;
/// The directory of the merged runs, under `output`.
const merged_directory = "merged";
/// kcov's report, under the merged directory.
const merged_report = "kcov-merged/coverage.json";
/// The prefix of each program's run directory, under `output`.
const run_prefix = "run-";
/// Bytes of kcov's report read.
const report_len_max: usize = 64 * 1024 * 1024;
const exit_success: u8 = 0;
const exit_failed: u8 = 1;
const exit_unusable: u8 = 2;
const output_buffer_len: usize = 4096;

/// Why a configuration cannot run, which the compile error names.
pub fn check_config(comptime project: Config) ?[]const u8 {
    if (project.directories.len == 0) return "directories names no directory";
    for (0..project.directories.len) |index| {
        if (check_directory(project, index)) |reason| return reason;
    }
    if (!below_working_directory(project.output)) return "output is not a relative path below the working directory";
    if (project.kcov_program.len == 0) return "kcov_program is empty";
    if (project.kcov_release == 0) return "kcov_release is 0";
    return null;
}

/// Why the directory at `index` cannot be counted, or null.
fn check_directory(comptime project: Config, index: usize) ?[]const u8 {
    const directory = project.directories[index];
    if (!below_working_directory(directory)) return "a directory is not a relative path below the working directory";
    if (std.mem.indexOfScalar(u8, directory, counter.path_separator) != null) return "a directory holds a comma, which kcov reads between two paths";
    for (project.directories[0..index]) |earlier| {
        if (holds(earlier, directory) or holds(directory, earlier)) return "one directory holds another, so a line would count twice";
    }
    if (holds(project.output, directory)) return "output holds a directory, and the engine deletes output";
    return null;
}

/// Whether `path` is relative and names a directory below the working directory, with no `.` or
/// `..` and no empty part.
fn below_working_directory(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/') return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

/// Whether `inner` is `outer` or a path below it.
fn holds(outer: []const u8, inner: []const u8) bool {
    if (!std.mem.startsWith(u8, inner, outer)) return false;
    return inner.len == outer.len or inner[outer.len] == '/';
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

/// Runs the programs the command line names under kcov, and reports each directory's share of
/// lines. Returns the exit status.
pub fn run(context: *const Context, comptime project: Config, given: []const []const u8) !u8 {
    if (given.len == 0) {
        try report_line.write(context.errors, &.{ .source = rule }, .@"error", rule, "usage: coverage <program>...", .{});
        return exit_unusable;
    }
    const kcov: counter.Kcov = .{ .arena = context.arena, .io = context.io, .program = project.kcov_program };
    if (!try pinned(context, project, &kcov)) return exit_unusable;
    const roots = try roots_of(context, project) orelse return exit_unusable;
    const io = context.io;
    Io.Dir.cwd().deleteTree(io, project.output) catch {};
    try Io.Dir.cwd().createDirPath(io, project.output);
    const runs = try context.arena.alloc([]const u8, given.len);
    var all_exited = true;
    for (given, runs, 1..) |program, *directory, number| {
        directory.* = try std.fmt.allocPrint(context.arena, "{s}/{s}{d}", .{ project.output, run_prefix, number });
        const failure = try kcov.count(roots, directory.*, program) orelse continue;
        all_exited = false;
        try report_failure(context, program, &failure);
    }
    const lines = try merged_lines(context, project, &kcov, roots, runs) orelse return exit_unusable;
    if (!try report.write(context.out, project.directories, lines, project.output)) {
        try report_line.write(context.errors, &.{ .source = project.output }, .@"error", rule, "counted no line in any directory: build each program with use_llvm = true, in this working directory", .{});
        return exit_unusable;
    }
    return if (all_exited) exit_success else exit_failed;
}

/// Whether kcov is there at the release the project pins. Reports why it is not.
fn pinned(context: *const Context, comptime project: Config, kcov: *const counter.Kcov) !bool {
    const source: report_line.Location = .{ .source = project.kcov_program };
    const release = kcov.release() catch |failure| switch (failure) {
        error.FileNotFound => {
            try report_line.write(context.errors, &source, .@"error", rule, "no kcov there; install kcov {d}", .{project.kcov_release});
            return false;
        },
        error.UnknownVersion => {
            try report_line.write(context.errors, &source, .@"error", rule, "kcov --version names no release", .{});
            return false;
        },
        else => return failure,
    };
    if (release == project.kcov_release) return true;
    try report_line.write(context.errors, &source, .@"error", rule, "kcov {d} is installed, and the project pins kcov {d}", .{ release, project.kcov_release });
    return false;
}

/// The absolute path of each directory, as the compiler writes the paths that kcov reads. Null,
/// after the report, when a directory cannot be resolved.
fn roots_of(context: *const Context, comptime project: Config) !?[]const []const u8 {
    const roots = try context.arena.alloc([]const u8, project.directories.len);
    for (project.directories, roots) |directory, *root| {
        const source: report_line.Location = .{ .source = directory };
        root.* = Io.Dir.cwd().realPathFileAlloc(context.io, directory, context.arena) catch |failure| {
            try report_line.write(context.errors, &source, .@"error", rule, "cannot resolve: {s}", .{@errorName(failure)});
            return null;
        };
        if (std.mem.indexOfScalar(u8, root.*, counter.path_separator) != null) {
            try report_line.write(context.errors, &source, .@"error", rule, "its absolute path holds a comma, which kcov reads between two paths", .{});
            return null;
        }
    }
    return roots;
}

/// Merges the runs and sums kcov's report for each root. Null, after the report, when kcov wrote
/// no report the engine can read.
fn merged_lines(
    context: *const Context,
    comptime project: Config,
    kcov: *const counter.Kcov,
    roots: []const []const u8,
    runs: []const []const u8,
) !?[]report.Lines {
    const merged = try std.fs.path.join(context.arena, &.{ project.output, merged_directory });
    if (try kcov.merge(merged, runs)) |failure| {
        try report_line.write(context.errors, &.{ .source = project.kcov_program }, .@"error", rule, "kcov --merge failed: {s}", .{failure.reason});
        try write_tail(context.errors, failure.output);
        return null;
    }
    const path = try std.fs.path.join(context.arena, &.{ merged, merged_report });
    const source: report_line.Location = .{ .source = path };
    const text = Io.Dir.cwd().readFileAlloc(context.io, path, context.arena, .limited(report_len_max)) catch |failure| {
        try report_line.write(context.errors, &source, .@"error", rule, "cannot read kcov's report: {s}", .{@errorName(failure)});
        return null;
    };
    return report.sum(context.arena, text, roots) catch |failure| switch (failure) {
        error.MalformedReport => {
            try report_line.write(context.errors, &source, .@"error", rule, "is not a kcov report", .{});
            return null;
        },
        else => return failure,
    };
}

fn report_failure(context: *const Context, source: []const u8, failure: *const counter.Failure) !void {
    try report_line.write(context.errors, &.{ .source = source }, .@"error", rule, "{s} under kcov", .{failure.reason});
    try write_tail(context.errors, failure.output);
}

test {
    _ = counter;
    _ = report;
    _ = @import("coverage_test.zig");
}

test "the root exports these names alone" {
    try @import("../public_names.zig").expect(@This(), &.{ "Config", "check_config", "main", "run" });
}
