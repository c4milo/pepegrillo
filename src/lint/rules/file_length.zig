//! file-length: a hand-written file stays at or under `max_lines` lines, so a reader can hold one
//! file in one sitting.
//!
//! Over every file in `scope`, the rule counts lines the way an editor numbers them: one per
//! newline, plus one for a last line with no newline. It reports a file over the limit once, at
//! the first line past the limit, with `{lines} lines, over the {max_lines}-line limit` followed
//! by `message_suffix`.

const std = @import("std");
const report = @import("../report.zig");
const Scope = @import("../scope.zig").Scope;
const text = @import("../text.zig");

/// The line limit a configuration gets when it names none.
pub const default_max_lines: u32 = 500;

pub const Config = struct {
    /// The rule name findings are reported under and `--rule` selects.
    name: []const u8 = "file-length",
    /// The files the rule reads.
    scope: Scope,
    /// The most lines a file may hold.
    max_lines: u32 = default_max_lines,
    /// Printed after the finding: `; split the file`.
    message_suffix: []const u8 = "",
};

/// The rule for one configuration: a type with the `name` and `check` the driver dispatches to.
pub fn Rule(comptime config: Config) type {
    comptime std.debug.assert(config.name.len != 0);
    comptime std.debug.assert(config.max_lines != 0);
    return struct {
        pub const name = config.name;

        pub fn check(context: *report.Context, file: report.File) !void {
            if (!config.scope.applies(file.path)) return;
            const lines = text.count_lines(file.source);
            if (lines <= config.max_lines) return;
            try context.findings.add(
                name,
                file.path,
                config.max_lines + 1,
                1,
                "{d} lines, over the {d}-line limit{s}",
                .{ lines, config.max_lines, config.message_suffix },
            );
        }
    };
}

// Tests.

const testing = std.testing;
const harness = @import("../harness.zig");

/// One line of a fixture. A comment line, so that a fixture is also a file that parses.
const fixture_line = "//\n";

const limit = default_max_lines;
const at_limit: [:0]const u8 = fixture_line ** limit;
const over_limit: [:0]const u8 = fixture_line ** (limit + 1);

/// Reads `.zig` and `.sh` files anywhere but `spec/`, with no suffix.
const anywhere = Rule(.{
    .scope = .{ .extensions = &.{ ".zig", ".sh" }, .exclude_directories = &.{"spec/"} },
});

/// Reads `.zig` and `.sh` files under three directories, and tells the reader what to do.
const in_directories = Rule(.{
    .scope = .{
        .extensions = &.{ ".zig", ".sh" },
        .include_directories = &.{ "src", "tools", "build" },
    },
    .message_suffix = "; split the file",
});

fn expect_findings(
    comptime rule: type,
    path: []const u8,
    source: [:0]const u8,
    expected: []const []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), rule, path, source);
    try harness.expect_messages(findings, expected);
    for (findings) |finding| try testing.expectEqual(limit + 1, finding.line);
}

test "file-length passes a file at the limit and flags one line over it, at that line" {
    try expect_findings(anywhere, "src/store/page.zig", at_limit, &.{});
    try expect_findings(anywhere, "src/store/page.zig", over_limit, &.{
        "501 lines, over the 500-line limit",
    });
    try expect_findings(in_directories, "src/store/page.zig", at_limit, &.{});
    try expect_findings(in_directories, "src/store/page.zig", over_limit, &.{
        "501 lines, over the 500-line limit; split the file",
    });
}

test "file-length counts a last line with no newline" {
    const unterminated: [:0]const u8 = fixture_line ** limit ++ "//";
    try expect_findings(anywhere, "tools/run.sh", unterminated, &.{
        "501 lines, over the 500-line limit",
    });
}

test "file-length reads the name and the limit a configuration gives" {
    const short = Rule(.{
        .name = "short-files",
        .scope = .{ .extensions = &.{".zig"} },
        .max_lines = 2,
    });
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), short, "src/a.zig", "//\n//\n//\n");
    try harness.expect_messages(findings, &.{"3 lines, over the 2-line limit"});
    try testing.expectEqualStrings("short-files", findings[0].rule);
    try testing.expectEqual(3, findings[0].line);
    try testing.expectEqualStrings("file-length", anywhere.name);
}

test "file-length reads the files its scope names and no others" {
    try expect_findings(anywhere, "tools/linux_test.sh", over_limit, &.{
        "501 lines, over the 500-line limit",
    });
    try expect_findings(anywhere, "build.zig", over_limit, &.{
        "501 lines, over the 500-line limit",
    });
    try expect_findings(anywhere, "spec/model/Store.tla", over_limit, &.{});
    try expect_findings(anywhere, "spec/model/check.sh", over_limit, &.{});
    try expect_findings(anywhere, "docs/formats.md", over_limit, &.{});

    try expect_findings(in_directories, "./tools/lint/main.zig", over_limit, &.{
        "501 lines, over the 500-line limit; split the file",
    });
    try expect_findings(in_directories, "build/modules.zig", over_limit, &.{
        "501 lines, over the 500-line limit; split the file",
    });
    try expect_findings(in_directories, "build.zig", over_limit, &.{});
    try expect_findings(in_directories, "bench/run.sh", over_limit, &.{});
    try expect_findings(in_directories, "docs/guide.md", over_limit, &.{});
}
