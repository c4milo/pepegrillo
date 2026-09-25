//! Tests for the global-state rule: one fixture per shape the rule's header names.

const std = @import("std");
const testing = std.testing;
const harness = @import("../harness.zig");
const global_state = @import("global_state.zig");
const Config = global_state.Config;

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
    const findings = try harness.run(arena_state.allocator(), global_state.Rule(config), path, source);
    try harness.expect_messages(findings, expected);
}

test "global-state flags a shared var at the top level, exported or not, and names its place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), global_state.Rule(everywhere), "src/a.zig",
        \\const std = @import("std");
        \\var count: u32 = 0;
        \\pub var ready: bool = false;
        \\export var seen: u32 = 0;
    );
    try harness.expect_messages(findings, &.{
        "var count is state every thread shares: make it threadlocal, or hand it in",
        "var ready is state every thread shares: make it threadlocal, or hand it in",
        "var seen is state every thread shares: make it threadlocal, or hand it in",
    });
    try testing.expectEqual(2, findings[0].line);
    try testing.expectEqual(5, findings[0].column);
    try testing.expectEqualStrings("global-state", findings[0].rule);
}

test "global-state flags a var in a container declared inside a function or a test" {
    try expect_findings(everywhere, "src/a.zig",
        \\fn text() []const u8 {
        \\    const out = struct {
        \\        var buffer: [16]u8 = undefined;
        \\    };
        \\    return &out.buffer;
        \\}
        \\test "a holder" {
        \\    const Holder = union { var inside: u32 = 0; };
        \\    _ = Holder;
        \\}
    , &.{
        "var buffer is state every thread shares: make it threadlocal, or hand it in",
        "var inside is state every thread shares: make it threadlocal, or hand it in",
    });
}

test "global-state passes a thread's own, an extern, a const and a function's local" {
    try expect_findings(everywhere, "src/a.zig",
        \\threadlocal var mine: u32 = 0;
        \\pub threadlocal var stream: ?*u32 = null;
        \\extern var environ: [*:null]?[*:0]u8;
        \\const fixed: u32 = 0;
        \\fn step() void {
        \\    var local: u32 = 0;
        \\    local += 1;
        \\}
    , &.{});
}

test "global-state reads only its scope, under the name its configuration gives" {
    const sources: Config = .{
        .name = "shared-state",
        .scope = .{ .extensions = &.{".zig"}, .include_directories = &.{"src"} },
    };
    try expect_findings(sources, "tools/a.zig", "var count: u32 = 0;", &.{});
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), global_state.Rule(sources), "src/a.zig", "var count: u32 = 0;");
    try testing.expectEqual(1, findings.len);
    try testing.expectEqualStrings("shared-state", findings[0].rule);
}
