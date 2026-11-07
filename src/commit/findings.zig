//! What one commit-lint run accumulates. Every rule calls `add`, `warn` or `record` once per
//! finding, and `write` prints the findings in the order they were recorded, one line each, in
//! the shape `report_line.zig` defines:
//!
//!     source: error: [rule-name] message
//!
//! The source is the commit sha in `--range` mode and the file path in `--message` mode. A finding
//! that refuses the commit prints as `error`, and one that only reports on it prints as `warning`.
//! The exit status reads `count_errors`, so a run with warnings alone is clean.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const report_line = @import("../report_line.zig");

/// How much a finding weighs: `error` refuses the commit, as it fails any tool's run, and
/// `warning` only reports on it.
const Severity = report_line.Severity;

pub const Finding = struct {
    /// The commit sha, or the message file path.
    source: []const u8,
    severity: Severity,
    rule: []const u8,
    message: []const u8,
};

pub const Findings = struct {
    arena: Allocator,
    /// Findings one run may record. One more is an error, never a dropped finding.
    findings_max: usize,
    items: std.ArrayList(Finding) = .empty,

    /// Records a finding that refuses the commit.
    pub fn add(
        self: *Findings,
        source: []const u8,
        rule: []const u8,
        comptime format: []const u8,
        arguments: anytype,
    ) !void {
        try self.record(source, .@"error", rule, format, arguments);
    }

    /// Records a finding that is reported and does not refuse the commit.
    pub fn warn(
        self: *Findings,
        source: []const u8,
        rule: []const u8,
        comptime format: []const u8,
        arguments: anytype,
    ) !void {
        try self.record(source, .warning, rule, format, arguments);
    }

    pub fn record(
        self: *Findings,
        source: []const u8,
        severity: Severity,
        rule: []const u8,
        comptime format: []const u8,
        arguments: anytype,
    ) !void {
        if (self.items.items.len >= self.findings_max) return error.TooManyFindings;
        try self.items.append(self.arena, .{
            .source = try self.arena.dupe(u8, source),
            .severity = severity,
            .rule = rule,
            .message = try std.fmt.allocPrint(self.arena, format, arguments),
        });
    }

    pub fn count(self: *const Findings) usize {
        return self.items.items.len;
    }

    /// Findings that refuse the commit. The exit status reads this, not `count`.
    pub fn count_errors(self: *const Findings) usize {
        var total: usize = 0;
        for (self.items.items) |finding| {
            if (finding.severity == .@"error") total += 1;
        }
        return total;
    }

    /// Writes every finding as one `source: severity: [rule] message` line.
    pub fn write(self: *const Findings, out: *Io.Writer) !void {
        for (self.items.items) |finding| {
            const location: report_line.Location = .{ .source = finding.source };
            try report_line.write(out, &location, finding.severity, finding.rule, "{s}", .{finding.message});
        }
    }
};

// Tests.

const testing = std.testing;

/// The cap the tests below give a `Findings`, small enough to reach.
const test_findings_max: usize = 2;

test "write prints source, severity, rule and message in the order recorded" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var findings: Findings = .{ .arena = arena_state.allocator(), .findings_max = 4 };
    try findings.add("abc1234", "subject-format", "the type is {s}", .{"wrong"});
    try findings.warn("abc1234", "scope-known", "the scope is {s}", .{"new"});
    var buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try findings.write(&writer);
    try testing.expectEqualStrings(
        "abc1234: error: [subject-format] the type is wrong\n" ++
            "abc1234: warning: [scope-known] the scope is new\n",
        writer.buffered(),
    );
}

test "count_errors counts errors and leaves warnings and notes out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var findings: Findings = .{ .arena = arena_state.allocator(), .findings_max = 4 };
    try findings.warn("a", "scope-known", "w", .{});
    try testing.expectEqual(1, findings.count());
    try testing.expectEqual(0, findings.count_errors());
    try findings.record("a", .note, "whitespace", "n", .{});
    try testing.expectEqual(0, findings.count_errors());
    try findings.record("a", .@"error", "whitespace", "v", .{});
    try testing.expectEqual(3, findings.count());
    try testing.expectEqual(1, findings.count_errors());
}

test "a finding past findings_max is an error, never dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var findings: Findings = .{ .arena = arena, .findings_max = test_findings_max };
    try findings.add("a", "whitespace", "one", .{});
    try findings.add("a", "whitespace", "two", .{});
    try testing.expectError(error.TooManyFindings, findings.add("a", "whitespace", "three", .{}));
    try testing.expectEqual(test_findings_max, findings.count());
}
