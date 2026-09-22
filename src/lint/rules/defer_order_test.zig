//! Tests of the defer-order rule. Each fixture pins one shape from the header of
//! `defer_order.zig`, under a rule that reads every Zig file, except where a test names its own
//! configuration.

const std = @import("std");
const testing = std.testing;
const ast = @import("../ast.zig");
const harness = @import("../harness.zig");
const report = @import("../report.zig");
const defer_order = @import("defer_order.zig");

const Rule = defer_order.Rule(.{ .scope = .{ .extensions = &.{".zig"} } });

const reported = "a defer after a statement that can fail; anything acquired above it leaks when" ++
    " that statement returns";

fn expect_findings(
    comptime rule: type,
    source: [:0]const u8,
    expected: []const []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), rule, "src/store/page.zig", source);
    try harness.expect_messages(findings, expected);
}

// The statements that pass.

test "a defer that names what the statement above it produced is passed" {
    try expect_findings(Rule,
        \\fn run(path: []const u8) !void {
        \\    const file = try open(path);
        \\    defer file.close();
        \\}
    , &.{});
}

test "a defer that names the receiver the statement above it acted on is passed" {
    try expect_findings(Rule,
        \\fn run(options: Options) !void {
        \\    try loop.init(&machine, options);
        \\    defer loop.deinit();
        \\}
    , &.{});
}

test "each defer of a pair reads the statement above it and both are passed" {
    try expect_findings(Rule,
        \\fn run() !void {
        \\    const a = try open_a();
        \\    defer a.close();
        \\    const b = try open_b();
        \\    defer b.close();
        \\}
    , &.{});
}

test "a defer under a statement that cannot fail is passed" {
    try expect_findings(Rule,
        \\fn run() void {
        \\    const x = compute();
        \\    defer x.deinit();
        \\}
    , &.{});
}

test "a defer under a catch that supplies a value is passed" {
    try expect_findings(Rule,
        \\fn run() void {
        \\    const r = f() catch 0;
        \\    defer g();
        \\    _ = r;
        \\}
    , &.{});
}

test "a defer under another defer is passed, whatever stands under them" {
    try expect_findings(Rule,
        \\fn run(c: *Client) !void {
        \\    defer close_all();
        \\    defer drain(&loop);
        \\    try connect_all(c);
        \\}
    , &.{});
}

test "a defer that opens a block is passed" {
    try expect_findings(Rule,
        \\fn run() !void {
        \\    try prepare();
        \\    {
        \\        defer release();
        \\    }
        \\}
    , &.{});
}

test "a deferred expression that names nothing releases nothing and is passed" {
    try expect_findings(Rule,
        \\fn run(gpa: Allocator, len: usize) !*Task {
        \\    const task = try gpa.create(Task, len);
        \\    errdefer comptime unreachable;
        \\    return task;
        \\}
        \\fn close(client: *Client) !void {
        \\    try connect_all(client);
        \\    defer unreachable;
        \\}
    , &.{});
}

/// The arguments of a call that, with its callee, names one identifier more than
/// `max_deferred_identifiers` holds.
const many_names = blk: {
    var text: []const u8 = "a0";
    for (1..ast.max_deferred_identifiers) |index| {
        text = text ++ std.fmt.comptimePrint(", a{d}", .{index});
    }
    break :blk text;
};

test "a deferred expression that names more identifiers than the buffer holds is passed" {
    const source = "fn run(client: *Client) !void {\n" ++
        "    try connect_all(client);\n" ++
        "    defer release(" ++ many_names ++ ");\n" ++
        "}\n";
    try expect_findings(Rule, source, &.{});
}

// The statements that are reported.

test "a defer that shares no name with the fallible statement above it is reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, "src/store/page.zig",
        \\fn run(client: *Client) !void {
        \\    try connect_all(client);
        \\    defer close_all();
        \\}
    );
    try harness.expect_messages(findings, &.{reported});
    try testing.expectEqual(3, findings[0].line);
    try testing.expectEqual(5, findings[0].column);
}

test "a catch that returns is a statement that can fail" {
    try expect_findings(Rule,
        \\fn run() !void {
        \\    const r = f() catch return error.Refused;
        \\    defer g();
        \\    _ = r;
        \\}
    , &.{reported});
}

test "a catch that breaks or continues is a statement that can fail" {
    try expect_findings(Rule,
        \\fn run() void {
        \\    while (next()) {
        \\        const r = f() catch break;
        \\        defer g();
        \\        _ = r;
        \\    }
        \\    while (next()) {
        \\        const r = f() catch continue;
        \\        defer g();
        \\        _ = r;
        \\    }
        \\}
    , &.{ reported, reported });
}

test "an errdefer is read as a defer is" {
    try expect_findings(Rule,
        \\fn run(client: *Client) !void {
        \\    try connect_all(client);
        \\    errdefer close_all();
        \\}
    , &.{reported});
}

test "an errdefer with a payload is read as a defer is" {
    try expect_findings(Rule,
        \\fn run(client: *Client) !void {
        \\    try connect_all(client);
        \\    errdefer |failure| report_failure(failure);
        \\}
    , &.{reported});
}

test "a defer in a nested block reads the statement above it in its own block" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, "src/store/page.zig",
        \\fn run() !void {
        \\    const handle = try open();
        \\    defer handle.close();
        \\    {
        \\        try prepare();
        \\        defer release();
        \\    }
        \\}
    );
    try harness.expect_messages(findings, &.{reported});
    try testing.expectEqual(6, findings[0].line);
}

test "a shared field segment counts, not the root of the chain alone" {
    try expect_findings(Rule,
        \\fn run(session: *Session) !void {
        \\    try session.buffer.fill();
        \\    defer other.buffer.free();
        \\}
    , &.{});
}

// The configuration and the files the rule reads.

test "the name, the message and the scope come from the configuration" {
    const Configured = defer_order.Rule(.{
        .name = "cleanup-order",
        .scope = .{ .extensions = &.{".zig"}, .include_directories = &.{"src"} },
        .message = "register the cleanup above the call that can fail",
    });
    const source: [:0]const u8 =
        \\fn run(client: *Client) !void {
        \\    try connect_all(client);
        \\    defer close_all();
        \\}
    ;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const inside = try harness.run(arena, Configured, "src/store/page.zig", source);
    try harness.expect_messages(inside, &.{"register the cleanup above the call that can fail"});
    try testing.expectEqualStrings("cleanup-order", inside[0].rule);
    const outside = try harness.run(arena, Configured, "tools/lint.zig", source);
    try harness.expect_messages(outside, &.{});
}

test "a file that does not parse is skipped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var context: report.Context = .{
        .arena = arena,
        .io = testing.io,
        .findings = .{ .arena = arena },
    };
    const source: [:0]const u8 =
        \\fn run( {
        \\    try connect_all(client);
        \\    defer close_all();
        \\}
    ;
    const file: report.File = .{ .path = "src/store/page.zig", .source = source, .tree = null };
    try Rule.check(&context, file);
    try testing.expectEqual(0, context.findings.count());
}

test "parameter_types decides whether a block in a two-parameter prototype is read" {
    const SimplePrototypes = defer_order.Rule(.{
        .scope = .{ .extensions = &.{".zig"} },
        .parameter_types = .simple_prototypes_only,
    });
    const source: [:0]const u8 =
        \\fn open(handle: @TypeOf(setup: {
        \\    try begin();
        \\    defer end();
        \\    break :setup handle_type;
        \\}), flags: u32) void {
        \\    _ = handle;
        \\    _ = flags;
        \\}
    ;
    try expect_findings(Rule, source, &.{reported});
    try expect_findings(SimplePrototypes, source, &.{});
}
