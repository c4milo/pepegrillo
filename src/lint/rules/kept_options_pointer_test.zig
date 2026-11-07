//! Tests for the kept-options-pointer rule: one fixture per shape the rule's header names.

const std = @import("std");
const testing = std.testing;
const harness = @import("../harness.zig");
const kept_options_pointer = @import("kept_options_pointer.zig");
const Config = kept_options_pointer.Config;

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
    const rule = kept_options_pointer.Rule(config);
    const findings = try harness.run(arena_state.allocator(), rule, path, source);
    try harness.expect_messages(findings, expected);
}

fn message(
    comptime function_name: []const u8,
    comptime parameter: []const u8,
    comptime field: []const u8,
) []const u8 {
    return function_name ++ " keeps the *const parameter " ++ parameter ++ " in ." ++ field ++
        " after it returns: copy what it keeps";
}

test "kept-options-pointer flags a field of self set to the pointer, and names its place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const rule = kept_options_pointer.Rule(everywhere);
    const findings = try harness.run(arena_state.allocator(), rule, "src/store/page.zig",
        \\const Options = struct { size: u32 };
        \\pub const Page = struct {
        \\    options: *const Options,
        \\    pub fn init(self: *Page, options: *const Options) void {
        \\        self.options = options;
        \\    }
        \\};
    );
    try harness.expect_messages(findings, &.{message("init", "options", "options")});
    try testing.expectEqual(5, findings[0].line);
    try testing.expectEqual(24, findings[0].column);
    try testing.expectEqualStrings("kept-options-pointer", findings[0].rule);
}

test "kept-options-pointer flags self.* and a returned literal, nested literals and addresses" {
    try expect_findings(everywhere, "src/store/page.zig",
        \\const Limits = struct { count_max: u32 };
        \\const Options = struct { limits: Limits };
        \\pub const Page = struct {
        \\    limits: *const Limits,
        \\    inner: struct { options: *const Options },
        \\    pub fn init(self: *Page, options: *const Options) void {
        \\        self.* = .{ .limits = &options.limits, .inner = .{ .options = options } };
        \\    }
        \\};
        \\pub const Slot = struct {
        \\    options: *const Options,
        \\    pub fn init(self: *Slot, scratch: *u32, options: *const Options) void {
        \\        scratch.* = 0;
        \\        self.options = options;
        \\    }
        \\};
        \\pub const Ring = struct {
        \\    options: *const Options,
        \\    pub fn init(options: *const Options) Ring {
        \\        if (options.limits.count_max == 0) return Ring{ .options = options };
        \\        return .{ .options = options };
        \\    }
        \\};
    , &.{
        message("init", "options", "limits"),
        message("init", "options", "options"),
        message("init", "options", "options"),
        message("init", "options", "options"),
        message("init", "options", "options"),
    });
}

test "kept-options-pointer passes a copy, a field value, a local, a private init, another name" {
    try expect_findings(everywhere, "src/store/page.zig",
        \\const Options = struct { size: u32 };
        \\pub const Page = struct {
        \\    options: Options,
        \\    size: u32,
        \\    other: *const Options,
        \\    pub fn init(self: *Page, options: *const Options) void {
        \\        self.* = .{ .options = options.*, .size = options.size, .other = &self.options };
        \\        self.size = options.size;
        \\    }
        \\    fn init_private(self: *Page, options: *const Options) void {
        \\        self.other = options;
        \\    }
        \\    pub fn reset(self: *Page, options: *const Options) void {
        \\        self.other = options;
        \\    }
        \\};
        \\pub const Table = struct {
        \\    rows: []const u32,
        \\    options: *const Options,
        \\    handle: *const *const Options,
        \\    pub fn init(self: *Table, rows: []const u32, options: *Options) void {
        \\        self.rows = rows;
        \\        self.options = options;
        \\    }
        \\};
        \\pub const Handle = struct {
        \\    handle: *const *const Options,
        \\    pub fn init(self: *Handle, options: *const Options) void {
        \\        self.handle = &options;
        \\    }
        \\};
        \\fn init(self: *Page, options: *const Options) void {
        \\    self.other = options;
        \\}
        \\pub const Ring = struct {
        \\    other: *const Options,
        \\    pub fn init(self: *Ring, options: *const Options) void {
        \\        var local: *const Options = undefined;
        \\        local = options;
        \\        self.other = &self.other.*;
        \\    }
        \\};
    , &.{});
}

test "kept-options-pointer leaves a nested container's functions to the container walk" {
    // The inner names repeat the outer ones, which Zig refuses and the parser does not, so a walk
    // that read the inner body as the outer one would report the assignment twice.
    try expect_findings(everywhere, "src/store/page.zig",
        \\const Options = struct { size: u32 };
        \\pub const Page = struct {
        \\    pub fn init(self: *Page, options: *const Options) void {
        \\        const Inner = struct {
        \\            other: *const Options,
        \\            pub fn init(self: *@This(), options: *const Options) void {
        \\                self.other = options;
        \\            }
        \\        };
        \\        _ = Inner;
        \\        _ = self;
        \\        _ = options;
        \\    }
        \\};
    , &.{message("init", "options", "other")});
}

test "kept-options-pointer reads the names, the scope and the rule name its configuration gives" {
    const configured: Config = .{
        .name = "kept-pointer",
        .scope = .{ .extensions = &.{".zig"}, .include_directories = &.{"src"} },
        .function_names = &.{ "init", "start" },
    };
    const source =
        \\const Options = struct { size: u32 };
        \\pub const Page = struct {
        \\    other: *const Options,
        \\    pub fn start(self: *Page, options: *const Options) void {
        \\        self.other = options;
        \\    }
        \\};
    ;
    try expect_findings(configured, "tools/page.zig", source, &.{});
    try expect_findings(everywhere, "src/page.zig", source, &.{});
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const rule = kept_options_pointer.Rule(configured);
    const findings = try harness.run(arena_state.allocator(), rule, "src/page.zig", source);
    try harness.expect_messages(findings, &.{message("start", "options", "other")});
    try testing.expectEqualStrings("kept-pointer", findings[0].rule);
}
