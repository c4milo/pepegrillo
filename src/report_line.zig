//! The one line every pepegrillo tool prints per finding. The shape is the one the Zig compiler
//! prints for its own errors, so an editor or a CI log reader that understands `zig build` reads a
//! pepegrillo report the same way:
//!
//!     path:line:column: error: [rule] message
//!
//! A finding that has no line leaves out the line and the column: a commit sha, or a file that
//! could not be read, prints as `source: error: [rule] message`. A finding with a line always has
//! a column.

const std = @import("std");
const Io = std.Io;

/// How much a finding weighs. `error` fails the run, `warning` is reported and does not, and
/// `note` is information the caller asked for, such as a score under its threshold.
pub const Severity = enum {
    @"error",
    warning,
    note,

    pub fn text(self: Severity) []const u8 {
        return @tagName(self);
    }
};

/// Where a finding is: a path with a 1-based line and column, or a source with neither.
pub const Location = struct {
    source: []const u8,
    position: ?Position = null,
};

pub const Position = struct {
    /// 1-based line.
    line: usize,
    /// 1-based column.
    column: usize,
};

/// Writes one finding as one line, with the message formatted from `format` and `arguments`.
pub fn write(
    out: *Io.Writer,
    location: Location,
    severity: Severity,
    rule: []const u8,
    comptime format: []const u8,
    arguments: anytype,
) Io.Writer.Error!void {
    try out.writeAll(location.source);
    if (location.position) |position| {
        try out.print(":{d}:{d}", .{ position.line, position.column });
    }
    try out.print(": {s}: [{s}] ", .{ severity.text(), rule });
    try out.print(format, arguments);
    try out.writeAll("\n");
}

// Tests.

const testing = std.testing;

/// Writes one line into a fixed buffer and checks it.
fn expect_line(
    expected: []const u8,
    location: Location,
    severity: Severity,
    rule: []const u8,
    message: []const u8,
) !void {
    var buffer: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    try write(&out, location, severity, rule, "{s}", .{message});
    try testing.expectEqualStrings(expected, out.buffered());
}

test "a finding with a position prints path, line, column, severity, rule and message" {
    try expect_line(
        "src/store/page.zig:12:9: error: [heap] reference to std.heap\n",
        .{ .source = "src/store/page.zig", .position = .{ .line = 12, .column = 9 } },
        .@"error",
        "heap",
        "reference to std.heap",
    );
}

test "a finding without a position prints the source alone, and each severity prints its name" {
    try expect_line(
        "a07a15b: warning: [scope-known] the scope is new\n",
        .{ .source = "a07a15b" },
        .warning,
        "scope-known",
        "the scope is new",
    );
    try expect_line(
        "src/store/page.zig:3:1: note: [cognitive-complexity] parse scored 2 (max 15)\n",
        .{ .source = "src/store/page.zig", .position = .{ .line = 3, .column = 1 } },
        .note,
        "cognitive-complexity",
        "parse scored 2 (max 15)",
    );
}
