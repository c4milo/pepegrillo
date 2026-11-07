//! A project's exported functions, held to the safety check sites each one reaches in a ReleaseSafe
//! build. A check inside a vector loop can stop the loop from staying vector, and a count of the
//! check sites shows a change that adds one. A project builds the objects it names as assembly
//! (`-femit-asm`, or `getEmittedAsm()` in its build), and pins each symbol's count in a table it
//! commits. The engine fails when a count differs from its pin, in either direction.
//!
//! ```zig
//! // tools/checkfree.zig
//! const pepegrillo = @import("pepegrillo");
//! pub fn main(init: std.process.Init) !void {
//!     return pepegrillo.checkfree.main(init, .{
//!         .prefix = "lib_",
//!         .table = "tools/checkfree_sites.zig",
//!         .pins = &.{.{ .symbol = "lib_crc32_avx2", .sites = 5 }},
//!     });
//! }
//! ```
//!
//! Run:  checkfree [--record] <file.s>...
//!
//! `checkfree_assembly.zig` reads each file and counts. With `--record` the engine prints the
//! table the files give, one Zig line a symbol, to standard output.
//!
//! One line per finding, in the shape `report_line.zig` defines, at the table: a symbol whose count
//! differs from its pin, a symbol with no pin, and a pin that no file exports.
//!
//! Exit status: 0 when every count equals its pin; 1 when one does not, or a symbol and a pin do
//! not match; 2 when nothing could be judged: wrong arguments or a file that could not be read.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const report_line = @import("../report_line.zig");

pub const assembly = @import("checkfree_assembly.zig");

pub const Pin = struct {
    /// An exported symbol, which starts with the configuration's `prefix`.
    symbol: []const u8,
    /// The check sites it reaches.
    sites: u32,
};

pub const Config = struct {
    /// The symbols, each with its count.
    pins: []const Pin,
    /// The prefix of every exported symbol the engine counts.
    prefix: []const u8,
    /// The file that holds the pins, from the working directory, where every finding points.
    table: []const u8,
    /// The panic functions not counted, by the end of their names: Zig's failed assertion, which
    /// stays in a ReleaseSafe build by design.
    excluded: []const []const u8 = &.{".reachedUnreachable"},
};

/// The rule name every line carries.
const rule = "checkfree";
/// The flag that prints the table in place of checking it.
const record_flag = "--record";
const exit_success: u8 = 0;
const exit_differs: u8 = 1;
const exit_unusable: u8 = 2;
const output_buffer_len: usize = 4096;

/// Why a configuration cannot run, which the compile error names.
pub fn check_config(comptime project: Config) ?[]const u8 {
    if (project.prefix.len == 0) return "prefix is empty";
    for (project.pins, 0..) |pin, index| {
        if (!std.mem.startsWith(u8, pin.symbol, project.prefix)) return "a pin's symbol does not start with prefix";
        for (project.pins[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.symbol, pin.symbol)) return "two pins share a symbol";
        }
    }
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
    const status = try run(arena, init.io, project, given, &out.interface, &errors.interface);
    try errors.interface.flush();
    try out.interface.flush();
    std.process.exit(status);
}

/// Reads the files the command line names, counts, and compares. Returns the exit status.
pub fn run(arena: Allocator, io: Io, comptime project: Config, given: []const []const u8, out: *Io.Writer, errors: *Io.Writer) !u8 {
    const record = given.len > 0 and std.mem.eql(u8, given[0], record_flag);
    const paths = given[@intFromBool(record)..];
    if (paths.len == 0) {
        try report_line.write(errors, .{ .source = rule }, .@"error", rule, "usage: checkfree [{s}] <file.s>...", .{record_flag});
        return exit_unusable;
    }
    var found: std.ArrayList(Pin) = .empty;
    for (paths) |path| {
        const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |failure| {
            try report_line.write(errors, .{ .source = path }, .@"error", rule, "cannot read: {s}", .{@errorName(failure)});
            return exit_unusable;
        };
        try count_file(arena, project, text, &found);
    }
    if (record) {
        for (found.items) |each| try out.print("    .{{ .symbol = \"{s}\", .sites = {d} }},\n", .{ each.symbol, each.sites });
    }
    return if (try report(project, found.items, errors)) exit_differs else exit_success;
}

fn count_file(arena: Allocator, comptime project: Config, text: []const u8, found: *std.ArrayList(Pin)) !void {
    const parsed = try assembly.parse(arena, text, project.prefix);
    for (parsed.symbols.items) |symbol| {
        const sites = try assembly.count(arena, &parsed, symbol.root, project.excluded);
        try found.append(arena, .{ .symbol = symbol.name, .sites = sites });
    }
}

/// Writes a finding for each symbol whose count differs from its pin, and for each pin no file
/// exports. Returns whether there was one.
pub fn report(comptime project: Config, found: []const Pin, errors: *Io.Writer) !bool {
    var differs = false;
    const location: report_line.Location = .{ .source = project.table };
    for (found) |each| {
        const pin = pinned(project.pins, each.symbol);
        if (pin != null and pin.? == each.sites) continue;
        if (pin) |sites| {
            try report_line.write(errors, location, .@"error", rule, "{s} reaches {d} check sites; the table pins {d}", .{ each.symbol, each.sites, sites });
        } else {
            try report_line.write(errors, location, .@"error", rule, "{s} reaches {d} check sites and has no pin", .{ each.symbol, each.sites });
        }
        differs = true;
    }
    for (project.pins) |pin| {
        if (pinned(found, pin.symbol) != null) continue;
        try report_line.write(errors, location, .@"error", rule, "no file exports {s}", .{pin.symbol});
        differs = true;
    }
    return differs;
}

/// The count a list gives a symbol, or null.
fn pinned(pins: []const Pin, symbol: []const u8) ?u32 {
    for (pins) |pin| {
        if (std.mem.eql(u8, pin.symbol, symbol)) return pin.sites;
    }
    return null;
}

// Tests.

const testing = std.testing;

const test_project: Config = .{
    .prefix = "lib_",
    .table = "tools/checkfree_sites.zig",
    .pins = &.{ .{ .symbol = "lib_direct", .sites = 1 }, .{ .symbol = "lib_kernel_avx2", .sites = 4 } },
};

test "check_config refuses an empty prefix, a pin outside it and a repeated pin" {
    try testing.expectEqual(null, check_config(test_project));
    try testing.expect(check_config(.{ .prefix = "", .table = "t", .pins = &.{} }) != null);
    try testing.expect(check_config(.{ .prefix = "lib_", .table = "t", .pins = &.{.{ .symbol = "other", .sites = 0 }} }) != null);
    const twice: Pin = .{ .symbol = "lib_a", .sites = 0 };
    try testing.expect(check_config(.{ .prefix = "lib_", .table = "t", .pins = &.{ twice, twice } }) != null);
}

fn expect_report(found: []const Pin, expected: []const u8) !void {
    var buffer: [output_buffer_len]u8 = undefined;
    var errors: Io.Writer = .fixed(&buffer);
    try testing.expectEqual(expected.len != 0, try report(test_project, found, &errors));
    try testing.expectEqualStrings(expected, errors.buffered());
}

test "report refuses a count that differs, an unpinned symbol and a pin no file exports" {
    const matched = [_]Pin{ .{ .symbol = "lib_direct", .sites = 1 }, .{ .symbol = "lib_kernel_avx2", .sites = 4 } };
    try expect_report(&matched, "");
    try expect_report(&.{ matched[0], .{ .symbol = "lib_kernel_avx2", .sites = 5 } }, "tools/checkfree_sites.zig: error: [checkfree] lib_kernel_avx2 reaches 5 check sites; the table pins 4\n");
    try expect_report(&.{ matched[0], matched[1], .{ .symbol = "lib_new", .sites = 0 } }, "tools/checkfree_sites.zig: error: [checkfree] lib_new reaches 0 check sites and has no pin\n");
    try expect_report(matched[1..], "tools/checkfree_sites.zig: error: [checkfree] no file exports lib_direct\n");
}

test "the sample's symbols give the test project's pins" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var found: std.ArrayList(Pin) = .empty;
    try count_file(arena_state.allocator(), test_project, assembly.sample, &found);
    try expect_report(found.items, "");
}

test {
    _ = assembly;
}
