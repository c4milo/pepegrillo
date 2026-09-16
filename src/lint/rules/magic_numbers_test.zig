//! Tests for the magic-numbers rule: one fixture per shape the rule's header names, and one per
//! configuration switch.

const std = @import("std");
const testing = std.testing;
const harness = @import("../harness.zig");
const report = @import("../report.zig");
const magic_numbers = @import("magic_numbers.zig");
const Config = magic_numbers.Config;

/// Every Zig file but tooling and constants files, reading parameter types as a walk that skips
/// multi-parameter prototypes does.
const outside_constants: Config = .{
    .scope = .{
        .extensions = &.{".zig"},
        .exclude_basenames = &.{"constants.zig"},
        .exclude_directories = &.{"tools/"},
    },
    .parameter_types = .simple_prototypes_only,
};

/// Every Zig file, with the defaults for everything else.
const everywhere: Config = .{ .scope = .{ .extensions = &.{".zig"} } };

fn findings_of(
    arena: std.mem.Allocator,
    comptime config: Config,
    path: []const u8,
    source: [:0]const u8,
) ![]const report.Finding {
    return harness.run(arena, magic_numbers.Rule(config), path, source);
}

fn expect_findings(
    comptime config: Config,
    path: []const u8,
    source: [:0]const u8,
    expected: []const []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), config, path, source);
    try harness.expect_messages(findings, expected);
}

test "magic-numbers flags an integer over 1 in a var, an array type and a shift" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), outside_constants, "src/a.zig",
        \\const two = 2;
        \\var count: u32 = 2;
        \\var bytes: [4]u8 = undefined;
        \\const bit = 1 << 3;
    );
    try harness.expect_messages(findings, &.{
        "integer literal 2",
        "integer literal 4",
        "integer literal 3",
    });
    try testing.expectEqual(2, findings[0].line);
    try testing.expectEqual(3, findings[1].line);
    try testing.expectEqual(13, findings[1].column);
    try testing.expectEqualStrings("magic-numbers", findings[0].rule);
}

test "magic-numbers flags hex, underscored and oversized literals as written" {
    try expect_findings(outside_constants, "src/a.zig",
        \\fn f(x: u128) u128 {
        \\    return (x & 0xFF) + 1_000_000 + 0x1_0000_0000_0000_0000 - 7;
        \\}
    , &.{
        "integer literal 0xFF",
        "integer literal 1_000_000",
        "integer literal 0x1_0000_0000_0000_0000",
        "integer literal 7",
    });
}

test "magic-numbers does not flag 0, 1 or a float" {
    try expect_findings(outside_constants, "src/a.zig",
        \\const zero = 0;
        \\const one = 1;
        \\const half = 0.5;
        \\const big_float = 2.5e3;
        \\var bit = 1 << 1;
        \\var ratio = 0.25 * 4.0e2;
    , &.{});
}

test "magic-numbers treats a const with one literal as a name, and a var or expression as inline" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), outside_constants, "src/a.zig",
        \\const max_entries: u32 = 4096;
        \\const negative = -7;
        \\var mutable: u32 = 4096;
        \\const doubled = 4096 * 2;
        \\fn f() u32 {
        \\    const local = 64;
        \\    return local + 3;
        \\}
        \\const sized: [16]u8 = 5;
    );
    try harness.expect_messages(findings, &.{
        "integer literal 4096",
        "integer literal 4096",
        "integer literal 2",
        "integer literal 3",
        "integer literal 16",
    });
    try testing.expectEqual(3, findings[0].line);
}

test "magic-numbers treats enum members and struct defaults as names and skips comptime blocks" {
    try expect_findings(outside_constants, "src/a.zig",
        \\const Command = enum(u8) { reserved = 0, prepare = 1, prepare_ok = 2, negative = -3 };
        \\const Options = struct { retries: [4]u8 = 3, window: [8]u8, doubled: u8 = 2 * 3 };
        \\comptime {
        \\    std.debug.assert(@sizeOf(Options) == 9);
        \\}
    , &.{ "integer literal 4", "integer literal 8", "integer literal 2", "integer literal 3" });
}

const test_block_fixture: [:0]const u8 =
    \\fn f() u32 {
    \\    return 42;
    \\}
    \\test "block" {
    \\    try std.testing.expectEqual(42, f());
    \\}
    \\comptime {
    \\    std.debug.assert(@sizeOf(u32) == 4);
    \\}
;

test "magic-numbers skips test and comptime blocks as its switches say" {
    try expect_findings(outside_constants, "src/a.zig", test_block_fixture, &.{
        "integer literal 42",
    });
    const reads_tests: Config = comptime modified: {
        var config = everywhere;
        config.skip_test_blocks = false;
        break :modified config;
    };
    try expect_findings(reads_tests, "src/a.zig", test_block_fixture, &.{
        "integer literal 42",
        "integer literal 42",
    });
    const reads_comptime: Config = comptime modified: {
        var config = everywhere;
        config.skip_comptime_blocks = false;
        break :modified config;
    };
    try expect_findings(reads_comptime, "src/a.zig", test_block_fixture, &.{
        "integer literal 42",
        "integer literal 4",
    });
}

test "magic-numbers allows every literal up to largest_allowed_literal" {
    const larger: Config = comptime modified: {
        var config = everywhere;
        config.largest_allowed_literal = 4096;
        config.name = "named-limits";
        break :modified config;
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), larger, "src/a.zig",
        \\var a: [4096]u8 = undefined;
        \\var b: [4097]u8 = undefined;
    );
    try harness.expect_messages(findings, &.{"integer literal 4097"});
    try testing.expectEqualStrings("named-limits", findings[0].rule);
}

const parameter_fixture: [:0]const u8 =
    \\fn one(bytes: [4]u8) [5]u8 {}
    \\fn two(bytes: [6]u8, count: u32) [7]u8 {}
    \\fn three(bytes: [8]u8) callconv(.c) [9]u8 {}
;

test "magic-numbers reads parameter types as parameter_types says" {
    try expect_findings(everywhere, "src/a.zig", parameter_fixture, &.{
        "integer literal 4",
        "integer literal 5",
        "integer literal 6",
        "integer literal 7",
        "integer literal 8",
        "integer literal 9",
    });
    try expect_findings(outside_constants, "src/a.zig", parameter_fixture, &.{
        "integer literal 4",
        "integer literal 5",
        "integer literal 7",
        "integer literal 9",
    });
}

test "magic-numbers reads the files its scope names and no others" {
    const source = "var limit: u32 = 4096;";
    try expect_findings(outside_constants, "src/store/constants.zig", source, &.{});
    try expect_findings(outside_constants, "constants.zig", source, &.{});
    try expect_findings(outside_constants, "tools/lint/a.zig", source, &.{});
    try expect_findings(outside_constants, "docs/a.md", source, &.{});
    try expect_findings(outside_constants, "src/store/my_constants.zig", source, &.{
        "integer literal 4096",
    });
}
