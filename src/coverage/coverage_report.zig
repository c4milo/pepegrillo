//! kcov's merged report, summed for each directory a project names. kcov writes one entry a file
//! in `coverage.json`, with the file's absolute path:
//!
//!     {"file": "/w/src/store/page.zig", "covered_lines": "3", "total_lines": "4"}
//!
//! kcov 43 writes the counts of a file as strings and the totals as numbers, so the engine reads a
//! count in either form. It adds each file to the directory that holds it, and leaves out a file
//! that no directory holds.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const report_line = @import("../report_line.zig");

/// The rule name every line carries.
pub const rule = "coverage";
/// Tenths of a percent in a whole.
const per_mille_whole: u64 = 1000;

/// The lines of one directory that kcov counted, and the lines that ran.
pub const Lines = struct {
    covered: u64 = 0,
    total: u64 = 0,
};

/// The lines of each root, in the order of `roots`. A root is a directory's absolute path, with no
/// separator at its end. Fails with `error.MalformedReport` when the text is not kcov's report.
pub fn sum(arena: Allocator, report_text: []const u8, roots: []const []const u8) ![]Lines {
    const lines = try arena.alloc(Lines, roots.len);
    @memset(lines, .{});
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, report_text, .{}) catch return error.MalformedReport;
    const files = field(parsed, "files") orelse return error.MalformedReport;
    if (files != .array) return error.MalformedReport;
    for (files.array.items) |file| {
        const path = field(file, "file") orelse return error.MalformedReport;
        if (path != .string) return error.MalformedReport;
        const counted = try lines_of(file);
        const index = root_of(roots, path.string) orelse continue;
        lines[index].covered += counted.covered;
        lines[index].total += counted.total;
    }
    return lines;
}

/// The counts of one file's entry.
fn lines_of(file: std.json.Value) !Lines {
    const covered = count_of(field(file, "covered_lines")) orelse return error.MalformedReport;
    const total = count_of(field(file, "total_lines")) orelse return error.MalformedReport;
    if (covered > total) return error.MalformedReport;
    return .{ .covered = covered, .total = total };
}

fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

/// A count written as a number or as a string of digits.
fn count_of(value: ?std.json.Value) ?u64 {
    return switch (value orelse return null) {
        .integer => |number| std.math.cast(u64, number),
        .string, .number_string => |text| std.fmt.parseInt(u64, text, 10) catch null,
        else => null,
    };
}

/// The index of the root that holds `path`, or null when none does.
fn root_of(roots: []const []const u8, path: []const u8) ?usize {
    for (roots, 0..) |root, index| {
        if (path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == std.fs.path.sep) return index;
    }
    return null;
}

/// Writes a line for each directory and a total at `output`. A directory with no line counted
/// gets a warning. Returns false when no directory had a line counted, which judges nothing.
pub fn write(out: *Io.Writer, directories: []const []const u8, lines: []const Lines, output: []const u8) !bool {
    var all: Lines = .{};
    for (directories, lines) |directory, counted| {
        all.covered += counted.covered;
        all.total += counted.total;
        if (counted.total == 0) {
            try report_line.write(out, &.{ .source = directory }, .warning, rule, "counted no line: no program compiled a function here", .{});
        } else {
            try write_share(out, directory, "", counted);
        }
    }
    if (all.total == 0) return false;
    try write_share(out, output, "total ", all);
    return true;
}

/// `91.2% of 1204 lines`, the share rounded down to a tenth of a percent, so that a total under
/// 100% never prints as 100.0%.
fn write_share(out: *Io.Writer, source: []const u8, label: []const u8, counted: Lines) !void {
    const per_mille = counted.covered * per_mille_whole / counted.total;
    try report_line.write(out, &.{ .source = source }, .note, rule, "{s}{d}.{d}% of {d} lines", .{
        label, per_mille / 10, per_mille % 10, counted.total,
    });
}

// Tests.

const testing = std.testing;

const report_fixture =
    \\{
    \\  "files": [
    \\    {"file": "/w/src/store/page.zig", "percent_covered": "66.67", "covered_lines": "6", "total_lines": "9"},
    \\    {"file": "/w/src/store/index.zig", "percent_covered": "50.00", "covered_lines": "1", "total_lines": "2"},
    \\    {"file": "/w/src/wire/frame.zig", "percent_covered": "75.00", "covered_lines": 3, "total_lines": 4},
    \\    {"file": "/w/src/wirefmt/frame.zig", "percent_covered": "0.00", "covered_lines": "0", "total_lines": "8"},
    \\    {"file": "/w/src/root.zig", "percent_covered": "100.00", "covered_lines": "1", "total_lines": "1"}
    \\  ],
    \\  "percent_covered": "62.50", "covered_lines": 11, "total_lines": 24
    \\}
;

test "sum adds each file to the directory that holds it, and leaves out the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const lines = try sum(arena_state.allocator(), report_fixture, &.{ "/w/src/store", "/w/src/wire", "/w/src/empty" });
    try testing.expectEqual(Lines{ .covered = 7, .total = 11 }, lines[0]);
    // `src/wirefmt` starts with the text `src/wire`, and is another directory.
    try testing.expectEqual(Lines{ .covered = 3, .total = 4 }, lines[1]);
    try testing.expectEqual(Lines{}, lines[2]);
}

test "sum refuses text that is not kcov's report" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const roots: []const []const u8 = &.{"/w/src"};
    try testing.expectError(error.MalformedReport, sum(arena, "{\"files\": [", roots));
    try testing.expectError(error.MalformedReport, sum(arena, "{\"total_lines\": 3}", roots));
    try testing.expectError(error.MalformedReport, sum(arena, "{\"files\": {}}", roots));
    try testing.expectError(error.MalformedReport, sum(arena, "{\"files\": [{\"covered_lines\": 1, \"total_lines\": 1}]}", roots));
    try testing.expectError(error.MalformedReport, sum(arena, "{\"files\": [{\"file\": \"/w/src/a.zig\", \"total_lines\": 1}]}", roots));
    try testing.expectError(error.MalformedReport, sum(arena, "{\"files\": [{\"file\": \"/w/src/a.zig\", \"covered_lines\": \"x\", \"total_lines\": 1}]}", roots));
    try testing.expectError(error.MalformedReport, sum(arena, "{\"files\": [{\"file\": \"/w/src/a.zig\", \"covered_lines\": -1, \"total_lines\": 1}]}", roots));
    try testing.expectError(error.MalformedReport, sum(arena, "{\"files\": [{\"file\": \"/w/src/a.zig\", \"covered_lines\": 2, \"total_lines\": 1}]}", roots));
}

test "write prints each directory's share, a warning for a directory with no line, and the total" {
    var buffer: [1024]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    const counted = try write(&out, &.{ "src/store", "src/wire", "src/empty" }, &.{
        .{ .covered = 1103, .total = 1204 },
        .{ .covered = 1999, .total = 2000 },
        .{},
    }, "zig-out/coverage");
    try testing.expect(counted);
    try testing.expectEqualStrings(
        \\src/store: note: [coverage] 91.6% of 1204 lines
        \\src/wire: note: [coverage] 99.9% of 2000 lines
        \\src/empty: warning: [coverage] counted no line: no program compiled a function here
        \\zig-out/coverage: note: [coverage] total 96.8% of 3204 lines
        \\
    , out.buffered());
}

test "write judges nothing when no directory had a line counted" {
    var buffer: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    try testing.expect(!try write(&out, &.{"src"}, &.{.{}}, "zig-out/coverage"));
    try testing.expectEqualStrings("src: warning: [coverage] counted no line: no program compiled a function here\n", out.buffered());
}
