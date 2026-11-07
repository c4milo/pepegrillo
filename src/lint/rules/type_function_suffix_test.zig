//! Tests for the type-function-suffix rule: one fixture per shape the rule's header names.

const std = @import("std");
const testing = std.testing;
const harness = @import("../harness.zig");
const type_function_suffix = @import("type_function_suffix.zig");
const Config = type_function_suffix.Config;

/// Every Zig file, with the defaults for everything else.
const everywhere: Config = .{ .scope = .{ .extensions = &.{".zig"} } };

fn expect_findings(
    comptime config: Config,
    path: []const u8,
    source: [:0]const u8,
    expected: []const []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const rule = type_function_suffix.Rule(config);
    const findings = try harness.run(arena_state.allocator(), rule, path, source);
    try harness.expect_messages(findings, expected);
}

fn message(comptime function_name: []const u8, comptime stem: []const u8) []const u8 {
    return "pub fn " ++ function_name ++ " returns a type: name it " ++ stem ++
        ", for the thing it returns, as std names ArrayList and StaticBitSet";
}

test "type-function-suffix flags a public type function named with Of, and names its place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const rule = type_function_suffix.Rule(everywhere);
    const findings = try harness.run(arena_state.allocator(), rule, "src/store/ring.zig",
        \\const std = @import("std");
        \\pub fn RingOf(comptime capacity: u32) type {
        \\    return struct { items: [capacity]u32 };
        \\}
    );
    try harness.expect_messages(findings, &.{message("RingOf", "Ring")});
    try testing.expectEqual(2, findings[0].line);
    try testing.expectEqual(8, findings[0].column);
    try testing.expectEqualStrings("type-function-suffix", findings[0].rule);
}

test "type-function-suffix reads a type function inside a container and inside a function" {
    try expect_findings(everywhere, "src/store/page.zig",
        \\pub const pages = struct {
        \\    pub fn PageOf(comptime T: type) type {
        \\        return struct { item: T };
        \\    }
        \\};
        \\fn build() type {
        \\    const inner = struct {
        \\        pub fn QueueOf(comptime T: type) type {
        \\            return struct { item: T };
        \\        }
        \\    };
        \\    return inner.QueueOf(u8);
        \\}
    , &.{ message("PageOf", "Page"), message("QueueOf", "Queue") });
}

test "type-function-suffix reads a return type in parentheses" {
    try expect_findings(everywhere, "src/store/proof.zig",
        \\pub fn ProofOf(comptime T: type) (type) {
        \\    return struct { item: T };
        \\}
        \\pub fn CheckOf(comptime T: type) ((type)) {
        \\    return struct { item: T };
        \\}
    , &.{ message("ProofOf", "Proof"), message("CheckOf", "Check") });
}

test "type-function-suffix passes a private one, a value function, a bare suffix, another name" {
    try expect_findings(everywhere, "src/store/page.zig",
        \\fn RingOf(comptime capacity: u32) type {
        \\    return [capacity]u8;
        \\}
        \\pub fn sizeOf(comptime T: type) usize {
        \\    return @sizeOf(T);
        \\}
        \\pub fn Of(comptime T: type) type {
        \\    return T;
        \\}
        \\pub fn Ring(comptime capacity: u32) type {
        \\    return [capacity]u8;
        \\}
        \\pub fn ProofOff(comptime T: type) type {
        \\    return T;
        \\}
    , &.{});
}

test "type-function-suffix takes the suffixes, the scope and the name its configuration gives" {
    const configured: Config = .{
        .name = "type-name",
        .scope = .{ .extensions = &.{".zig"}, .include_directories = &.{"src"} },
        .suffixes = &.{ "Of", "Type" },
    };
    const source =
        \\pub fn RingType(comptime capacity: u32) type {
        \\    return [capacity]u8;
        \\}
    ;
    try expect_findings(configured, "tools/ring.zig", source, &.{});
    try expect_findings(everywhere, "src/ring.zig", source, &.{});
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const rule = type_function_suffix.Rule(configured);
    const findings = try harness.run(arena_state.allocator(), rule, "src/ring.zig", source);
    try harness.expect_messages(findings, &.{message("RingType", "Ring")});
    try testing.expectEqualStrings("type-name", findings[0].rule);
}
