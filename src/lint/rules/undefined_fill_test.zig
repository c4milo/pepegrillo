//! Tests for the undefined-fill rule: one fixture per shape the rule's header names.

const std = @import("std");
const testing = std.testing;
const harness = @import("../harness.zig");
const undefined_fill = @import("undefined_fill.zig");
const Config = undefined_fill.Config;

/// Every Zig file under `src`, with the defaults for everything else.
const everywhere: Config = .{ .scope = .{ .extensions = &.{".zig"}, .include_directories = &.{"src"} } };

const message = "is an array set to undefined, which Debug and ReleaseSafe fill on every call: " ++
    "write into the caller's memory, or declare it only where it is used";

fn expect_findings(comptime config: Config, path: []const u8, source: [:0]const u8, expected: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), undefined_fill.Rule(config), path, source);
    try harness.expect_messages(findings, expected);
}

test "undefined-fill reports a local array whose length is a name, and names its place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), undefined_fill.Rule(everywhere), "src/store/page.zig",
        \\const count = 32;
        \\fn drain() void {
        \\    var messages: [count]u64 = undefined;
        \\    var name: [count:0]u32 = undefined;
        \\    _ = .{ &messages, &name };
        \\}
    );
    try harness.expect_messages(findings, &.{ "var messages " ++ message, "var name " ++ message });
    try testing.expectEqual(3, findings[0].line);
    try testing.expectEqual(9, findings[0].column);
    try testing.expectEqualStrings("undefined-fill", findings[0].rule);
}

test "undefined-fill passes an array given a value, a const, a slice, a pointer and a scalar" {
    try expect_findings(everywhere, "src/store/page.zig",
        \\const count = 32;
        \\fn drain(source: *[count]u64) void {
        \\    var messages: [count]u64 = @splat(0);
        \\    const table: [count]u64 = undefined;
        \\    var slice: []u64 = undefined;
        \\    var pointer: *[count]u64 = undefined;
        \\    var total: u64 = undefined;
        \\    var copied = source.*;
        \\    var tagged: [count]u64 = .undefined;
        \\    _ = .{ &messages, table, &slice, &pointer, &total, &copied, &tagged };
        \\}
    , &.{});
}

test "undefined-fill passes a few elements written as a number, and reports one more" {
    try expect_findings(everywhere, "src/store/page.zig",
        \\fn few() void {
        \\    var events: [8]u64 = undefined;
        \\    var hex: [0x8]u8 = undefined;
        \\    _ = .{ &events, &hex };
        \\}
    , &.{});
    try expect_findings(everywhere, "src/store/page.zig",
        \\fn more() void {
        \\    var events: [9]u64 = undefined;
        \\    var hex: [0x40]u8 = undefined;
        \\    _ = .{ &events, &hex };
        \\}
    , &.{ "var events " ++ message, "var hex " ++ message });
    const strict: Config = .{ .scope = everywhere.scope, .literal_elements_max = 0, .bytes_min = 0 };
    try expect_findings(strict, "src/store/page.zig",
        \\fn one() void {
        \\    var event: [1]u64 = undefined;
        \\    _ = &event;
        \\}
    , &.{"var event " ++ message});
}

test "undefined-fill reads no test, no container member, and no file outside its scope" {
    try expect_findings(everywhere, "src/store/page.zig",
        \\const count = 32;
        \\var shared: [count]u64 = undefined;
        \\const Holder = struct { var inner: [count]u64 = undefined; };
        \\test "a fixture" {
        \\    var messages: [count]u64 = undefined;
        \\    _ = &messages;
        \\    const Helper = struct {
        \\        fn fill() void {
        \\            var slots: [count]u64 = undefined;
        \\            _ = &slots;
        \\        }
        \\    };
        \\    Helper.fill();
        \\}
    , &.{});
    // A struct declared inside a function has members, not locals; a function inside it has locals.
    try expect_findings(everywhere, "src/store/page.zig",
        \\const count = 32;
        \\fn outer() void {
        \\    const Inner = struct {
        \\        var member: [count]u64 = undefined;
        \\        fn inner() void {
        \\            var local: [count]u64 = undefined;
        \\            _ = &local;
        \\        }
        \\    };
        \\    _ = Inner;
        \\}
    , &.{"var local " ++ message});
    try expect_findings(everywhere, "tools/page.zig",
        \\fn drain() void {
        \\    var messages: [32]u64 = undefined;
        \\    _ = &messages;
        \\}
    , &.{});
}

test "undefined-fill passes a variable the configuration allows, in its own file only" {
    const allowing: Config = .{
        .scope = everywhere.scope,
        .allowed = &.{.{ .path = "src/store/page.zig", .variable = "receipts" }},
    };
    const source =
        \\const changes_max = 256;
        \\fn apply_early() void {
        \\    var receipts: [changes_max]u64 = undefined;
        \\    var others: [changes_max]u64 = undefined;
        \\    _ = .{ &receipts, &others };
        \\}
    ;
    try expect_findings(allowing, "src/store/page.zig", source, &.{"var others " ++ message});
    try expect_findings(allowing, "src/store/log.zig", source, &.{ "var receipts " ++ message, "var others " ++ message });
}

test "undefined-fill stops at the testing import only when asked, and at no other name for it" {
    const source =
        \\const std = @import("std");
        \\const count = 32;
        \\fn drain() void {
        \\    var messages: [count]u64 = undefined;
        \\    _ = &messages;
        \\}
        \\const testing = std.testing;
        \\fn fixture() void {
        \\    var slots: [count]u64 = undefined;
        \\    _ = &slots;
        \\}
    ;
    try expect_findings(everywhere, "src/store/page.zig", source, &.{ "var messages " ++ message, "var slots " ++ message });
    const stopping: Config = .{ .scope = everywhere.scope, .stop_at_testing_import = true };
    try expect_findings(stopping, "src/store/page.zig", source, &.{"var messages " ++ message});
    const other_lines = [_][:0]const u8{
        "pub const testing = @import(\"page_testing.zig\");",
        "const checks = std.testing;",
        "var testing = std.testing;",
    };
    inline for (other_lines) |line| {
        try expect_findings(stopping, "src/store/page.zig", "const std = @import(\"std\");\n" ++ line ++
            \\
            \\fn drain() void {
            \\    var messages: [32]u64 = undefined;
            \\    _ = &messages;
            \\}
        , &.{"var messages " ++ message});
    }
}

test "undefined-fill passes an array its declaration shows under 64 bytes, and reports one of 64" {
    try expect_findings(everywhere, "src/store/page.zig",
        \\const digest_length = 32;
        \\fn small() void {
        \\    var name: [16]u8 = undefined;
        \\    var line: [31:0]u8 = undefined;
        \\    var digest: [digest_length]u8 = undefined;
        \\    var halves: [15]u24 = undefined;
        \\    var flags: [63]bool = undefined;
        \\    var sums: [15]u32 = undefined;
        \\    var weights: [15]f32 = undefined;
        \\    var shorts: [31]i16 = undefined;
        \\    _ = .{ &name, &line, &digest, &halves, &flags, &sums, &weights, &shorts };
        \\}
    , &.{});
    try expect_findings(everywhere, "src/store/page.zig",
        \\const digest_length = 64;
        \\fn large() void {
        \\    var name: [64]u8 = undefined;
        \\    var line: [63:0]u8 = undefined;
        \\    var digest: [digest_length]u8 = undefined;
        \\    var halves: [16]u24 = undefined;
        \\    var sums: [16]u32 = undefined;
        \\    var words: [9]u64 = undefined;
        \\    var sizes: [9]usize = undefined;
        \\    var halfs: [32]f16 = undefined;
        \\    _ = .{ &name, &line, &digest, &halves, &sums, &words, &sizes, &halfs };
        \\}
    , &.{
        "var name " ++ message, "var line " ++ message,  "var digest " ++ message, "var halves " ++ message,
        "var sums " ++ message, "var words " ++ message, "var sizes " ++ message,  "var halfs " ++ message,
    });
    const sizeless: Config = .{ .scope = everywhere.scope, .bytes_min = 0 };
    try expect_findings(sizeless, "src/store/page.zig",
        \\fn small() void {
        \\    var name: [16]u8 = undefined;
        \\    _ = &name;
        \\}
    , &.{"var name " ++ message});
}

test "undefined-fill reports a length or an element type it cannot size, and a name set two ways" {
    try expect_findings(everywhere, "src/store/page.zig",
        \\const constants = @import("constants.zig");
        \\const Event = struct { tag: u8 };
        \\fn unknown(items: []const u8) void {
        \\    const count = items.len;
        \\    var events: [16]Event = undefined;
        \\    var magic: [constants.magic_len]u8 = undefined;
        \\    var counted: [count]u8 = undefined;
        \\    _ = .{ &events, &magic, &counted };
        \\}
        \\fn few() void {
        \\    const count = 16;
        \\    var slots: [count]u8 = undefined;
        \\    _ = &slots;
        \\}
        \\fn wide() void {
        \\    const width = 128;
        \\    var column: [width]u8 = undefined;
        \\    _ = &column;
        \\}
        \\fn narrow() void {
        \\    const width = 8;
        \\    var row: [width]u8 = undefined;
        \\    _ = &row;
        \\}
    , &.{
        "var events " ++ message, "var magic " ++ message,  "var counted " ++ message,
        "var slots " ++ message,  "var column " ++ message, "var row " ++ message,
    });
}
