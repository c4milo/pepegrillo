//! Tests of the unreleased-acquire rule. Each fixture pins one shape from the header of
//! `unreleased_acquire.zig`, under a rule configured the way a project configures it: with the
//! names its own tree acquires by.

const std = @import("std");
const testing = std.testing;
const harness = @import("../harness.zig");
const report = @import("../report.zig");
const unreleased_acquire = @import("unreleased_acquire.zig");

pub const Rule = unreleased_acquire.Rule(.{
    .scope = .{ .extensions = &.{".zig"} },
    .acquire_prefixes = &.{ "open_", "create" },
    .acquire_suffixes = &.{"_init"},
});

pub fn reported(comptime acquired: []const u8) []const u8 {
    return acquired ++ " is acquired here and a statement under it can fail, and no defer" ++
        " releases " ++ acquired;
}

pub fn expect_findings(
    comptime rule: type,
    source: [:0]const u8,
    expected: []const []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), rule, "src/store/page.zig", source);
    try harness.expect_messages(findings, expected);
}

// The acquires that are reported.

test "an acquire with no release and a fallible statement under it is reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, "src/store/page.zig",
        \\fn run(path: []const u8) !void {
        \\    const socket = try open_socket(path);
        \\    try bind(socket);
        \\    try listen(socket);
        \\}
    );
    try harness.expect_messages(findings, &.{reported("socket")});
    try testing.expectEqual(2, findings[0].line);
    try testing.expectEqual(5, findings[0].column);
}

test "a release by a plain call under a fallible statement is reported" {
    try expect_findings(Rule,
        \\fn run(path: []const u8) !void {
        \\    const file = try open_file(path);
        \\    try write(file, "x");
        \\    close_now(file);
        \\}
    , &.{reported("file")});
}

test "an acquire released only on the path that succeeds is reported once per acquire" {
    try expect_findings(Rule,
        \\fn run(path: []const u8) !void {
        \\    const first = try open_file(path);
        \\    const second = try open_file(path);
        \\    try join(first, second);
        \\    close_now(first);
        \\    close_now(second);
        \\}
    , &.{ reported("first"), reported("second") });
}

test "an acquire named by a suffix is read as one named by a prefix is" {
    try expect_findings(Rule,
        \\fn run(options: Options) !void {
        \\    const pool = try buffer_init(options);
        \\    try warm(pool);
        \\}
    , &.{reported("pool")});
}

// The acquires that pass.

test "a defer or an errdefer naming the value passes it, whatever it calls" {
    // `teardown` is in neither release list, so these pass by the defer and not by the window.
    try expect_findings(Rule,
        \\fn run(path: []const u8) !void {
        \\    const socket = try open_socket(path);
        \\    defer teardown(socket);
        \\    try bind(socket);
        \\}
        \\fn hold(path: []const u8) !void {
        \\    const socket = try open_socket(path);
        \\    errdefer teardown(socket);
        \\    try bind(socket);
        \\}
    , &.{});
}

test "a defer that names another value does not pass the acquire" {
    try expect_findings(Rule,
        \\fn run(path: []const u8) !void {
        \\    const socket = try open_socket(path);
        \\    defer teardown(other);
        \\    try bind(socket);
        \\}
    , &.{reported("socket")});
}

test "a release reached with nothing fallible between it and the acquire passes" {
    try expect_findings(Rule,
        \\fn run(path: []const u8) !void {
        \\    const probe = try open_socket(path);
        \\    close_now(probe);
        \\    try run_the_rest();
        \\}
    , &.{});
}

test "a value the block returns passes: the caller owns it" {
    try expect_findings(Rule,
        \\fn run(path: []const u8) !Socket {
        \\    const socket = try open_socket(path);
        \\    try bind(socket);
        \\    return socket;
        \\}
        \\fn wrapped(path: []const u8) !Connection {
        \\    const socket = try open_socket(path);
        \\    try bind(socket);
        \\    return .{ .socket = socket };
        \\}
    , &.{});
}

test "pass_returned off reports the value the block returns" {
    const Strict = unreleased_acquire.Rule(.{
        .scope = .{ .extensions = &.{".zig"} },
        .acquire_prefixes = &.{"open_"},
        .pass_returned = false,
    });
    try expect_findings(Strict,
        \\fn run(path: []const u8) !Socket {
        \\    const socket = try open_socket(path);
        \\    try bind(socket);
        \\    return socket;
        \\}
    , &.{reported("socket")});
}

test "an acquire with nothing fallible under it passes" {
    try expect_findings(Rule,
        \\fn run(path: []const u8) !void {
        \\    const socket = try open_socket(path);
        \\    bind(socket);
        \\    close_now(socket);
        \\}
    , &.{});
}

test "a statement that is not an acquire of a name the lists hold passes" {
    try expect_findings(Rule,
        \\fn run(path: []const u8) !void {
        \\    const socket = try connect(path);
        \\    try bind(socket);
        \\}
        \\fn plain(path: []const u8) !void {
        \\    const socket = open_socket(path);
        \\    try bind(socket);
        \\}
        \\fn indirect(path: []const u8) !void {
        \\    const socket = try open_socket;
        \\    try bind(socket);
        \\}
    , &.{});
}

test "the empty lists a fresh configuration carries report nothing" {
    const Inert = unreleased_acquire.Rule(.{ .scope = .{ .extensions = &.{".zig"} } });
    try expect_findings(Inert,
        \\fn run(path: []const u8) !void {
        \\    const socket = try open_socket(path);
        \\    try bind(socket);
        \\}
    , &.{});
}

test "a defer in a nested block is not a defer of the block above" {
    try expect_findings(Rule,
        \\fn run(path: []const u8) !void {
        \\    const socket = try open_socket(path);
        \\    try bind(socket);
        \\    {
        \\        defer close_now(socket);
        \\    }
        \\}
    , &.{reported("socket")});
}

test "a release named by no list leaves the whole block in the window" {
    const NoReleases = unreleased_acquire.Rule(.{
        .scope = .{ .extensions = &.{".zig"} },
        .acquire_prefixes = &.{"open_"},
        .release_prefixes = &.{},
        .release_suffixes = &.{},
    });
    const source: [:0]const u8 =
        \\fn run(path: []const u8) !void {
        \\    const probe = try open_socket(path);
        \\    close_now(probe);
        \\    try run_the_rest();
        \\}
    ;
    try expect_findings(Rule, source, &.{});
    try expect_findings(NoReleases, source, &.{reported("probe")});
}

// The configuration and the files the rule reads.

test "the name, the message and the scope come from the configuration" {
    const Configured = unreleased_acquire.Rule(.{
        .name = "leaked-handle",
        .scope = .{ .extensions = &.{".zig"}, .include_directories = &.{"src"} },
        .acquire_prefixes = &.{"open_"},
        .message = "{[acquired]s} is never released on the path that fails",
    });
    const source: [:0]const u8 =
        \\fn run(path: []const u8) !void {
        \\    const socket = try open_socket(path);
        \\    try bind(socket);
        \\}
    ;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const inside = try harness.run(arena, Configured, "src/store/page.zig", source);
    try harness.expect_messages(inside, &.{"socket is never released on the path that fails"});
    try testing.expectEqualStrings("leaked-handle", inside[0].rule);
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
        \\    const socket = try open_socket(path);
        \\    try bind(socket);
        \\}
    ;
    const file: report.File = .{ .path = "src/store/page.zig", .source = source, .tree = null };
    try Rule.check(&context, file);
    try testing.expectEqual(0, context.findings.count());
}

test "parameter_types decides whether a block in a two-parameter prototype is read" {
    const SimplePrototypes = unreleased_acquire.Rule(.{
        .scope = .{ .extensions = &.{".zig"} },
        .acquire_prefixes = &.{"open_"},
        .parameter_types = .simple_prototypes_only,
    });
    const source: [:0]const u8 =
        \\fn read(handle: @TypeOf(setup: {
        \\    const socket = try open_socket(path);
        \\    try bind(socket);
        \\    break :setup socket;
        \\}), flags: u32) void {
        \\    _ = handle;
        \\    _ = flags;
        \\}
    ;
    try expect_findings(Rule, source, &.{reported("socket")});
    try expect_findings(SimplePrototypes, source, &.{});
}
