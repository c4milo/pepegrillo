//! Tests for the static-alignment rule: one fixture per shape the rule's header names.

const std = @import("std");
const testing = std.testing;
const harness = @import("../harness.zig");
const static_alignment = @import("static_alignment.zig");
const Config = static_alignment.Config;

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
    const rule = static_alignment.Rule(config);
    const findings = try harness.run(arena_state.allocator(), rule, path, source);
    try harness.expect_messages(findings, expected);
}

test "static-alignment flags a named type, an array or optional of one by its element, and a call" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), static_alignment.Rule(everywhere), "src/a.zig",
        \\const Holder = struct { small: u8, memory: [100]u8 align(64) };
        \\var holder: Holder = undefined;
        \\pub var loop: backend.Loop = undefined;
        \\var slots: [4]Holder = undefined;
        \\var maybe: ?Holder = null;
        \\var counter: std.atomic.Value(u32) = .init(0);
    );
    try harness.expect_messages(findings, &.{
        "var holder declares no alignment: write align(@alignOf(Holder))",
        "var loop declares no alignment: write align(@alignOf(backend.Loop))",
        "var slots declares no alignment: write align(@alignOf(Holder))",
        "var maybe declares no alignment: write align(@alignOf(Holder))",
        "var counter declares no alignment: write align(@alignOf(std.atomic.Value(u32)))",
    });
    try testing.expectEqual(2, findings[0].line);
    try testing.expectEqual(5, findings[0].column);
    try testing.expectEqualStrings("static-alignment", findings[0].rule);
}

test "static-alignment passes primitives, pointers, slices, arrays of them, and a stated alignment" {
    try expect_findings(everywhere, "src/a.zig",
        \\var count: u32 = 0;
        \\var ready: bool = false;
        \\var bytes: [4096]u8 = undefined;
        \\var sizes: [2][3]usize = undefined;
        \\var maybe_count: ?i64 = null;
        \\var pointer: *Holder = undefined;
        \\var maybe_pointer: ?*const Holder = null;
        \\var list: []const Holder = &.{};
        \\var holder: Holder align(@alignOf(Holder)) = undefined;
        \\var buffer: [64]u8 align(64) = undefined;
        \\extern var environ: [*:null]?[*:0]u8;
        \\extern var shared: Holder;
        \\const constant: Holder = .{};
    , &.{});
}

test "static-alignment reads the vars of a struct, a union and a struct inside a function or test" {
    try expect_findings(everywhere, "src/a.zig",
        \\const Outer = struct {
        \\    var inner: Holder = undefined;
        \\    field: Holder,
        \\};
        \\const Choice = union(enum) {
        \\    one: u8,
        \\    var chosen: Holder = undefined;
        \\};
        \\fn run() void {
        \\    var local: Holder = undefined;
        \\    _ = &local;
        \\    const Log = struct {
        \\        var entries: [4]Entry = undefined;
        \\    };
        \\    _ = Log;
        \\}
        \\test "a log" {
        \\    const Other = struct {
        \\        var seen: Holder = undefined;
        \\    };
        \\    _ = Other;
        \\}
    , &.{
        "var inner declares no alignment: write align(@alignOf(Holder))",
        "var chosen declares no alignment: write align(@alignOf(Holder))",
        "var entries declares no alignment: write align(@alignOf(Entry))",
        "var seen declares no alignment: write align(@alignOf(Holder))",
    });
}

test "static-alignment asks a var with no declared type for both" {
    try expect_findings(everywhere, "src/a.zig",
        \\var signals = std.atomic.Value(u32).init(0);
    , &.{
        "var signals declares no type, so its alignment cannot be stated: declare both",
    });
}

test "static-alignment reads only its scope, under the name the configuration gives" {
    const named: Config = .{
        .name = "global-alignment",
        .scope = .{ .extensions = &.{".zig"}, .exclude_directories = &.{"tools/"} },
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = "var holder: Holder = undefined;";
    const outside = try harness.run(arena, static_alignment.Rule(named), "tools/a.zig", source);
    try testing.expectEqual(0, outside.len);
    const inside = try harness.run(arena, static_alignment.Rule(named), "src/a.zig", source);
    try testing.expectEqual(1, inside.len);
    try testing.expectEqualStrings("global-alignment", inside[0].rule);
}
