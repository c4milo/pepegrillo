//! Tests of the unbounded-loop rule. Each fixture pins one shape from the header of
//! `unbounded_loop.zig`, under one of two configurations:
//!
//! - `EveryForever`: check 1 under `.always` and check 2, over every Zig file, with the default
//!   texts.
//! - `NamedLimit`: check 1 under `.unless_bounded_break` and check 3, over `src/` alone, with texts
//!   the configuration supplies.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const harness = @import("../harness.zig");
const report = @import("../report.zig");
const unbounded_loop = @import("unbounded_loop.zig");

const EveryForever = unbounded_loop.Rule(.{
    .scope = .{ .extensions = &.{".zig"} },
    .forever = .always,
    .unchanged_condition = true,
});

const without_break = "while (true) has no break; nothing ends the loop (handbook 8)";
const without_bound = "while (true) breaks on no named limit; use a limits value (handbook 8)";

const NamedLimit = unbounded_loop.Rule(.{
    .scope = .{ .extensions = &.{".zig"}, .include_directories = &.{"src"} },
    .forever = .unless_bounded_break,
    .length_read = true,
    .bound = .{ .segments = &.{"constants"}, .last_segment_suffixes = &.{"_max"} },
    .messages = .{
        .forever_without_break = without_break,
        .forever_without_bound = without_bound,
        .length_read = "reads {[read]s} against a literal; no limit (handbook 8)",
    },
});

const no_bound = "while (true) has no bound";

fn findings_of(
    arena: Allocator,
    comptime rule: type,
    path: []const u8,
    source: [:0]const u8,
) ![]const report.Finding {
    return harness.run(arena, rule, path, source);
}

fn expect_findings(
    comptime rule: type,
    path: []const u8,
    source: [:0]const u8,
    expected: []const []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), rule, path, source);
    try harness.expect_messages(findings, expected);
}

// Check 1 under `.always` and check 2.

test "always flags while (true) with or without a break" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), EveryForever, "src/store/page.zig",
        \\fn spin(done: bool) void {
        \\    while (true) {}
        \\    outer: while (true) {
        \\        if (done) break :outer;
        \\        if (index == constants.pages_max) break;
        \\    }
        \\}
    );
    try harness.expect_messages(findings, &.{ no_bound, no_bound });
    try testing.expectEqual(2, findings[0].line);
    try testing.expectEqual(5, findings[0].column);
    try testing.expectEqual(3, findings[1].line);
    try testing.expectEqual(12, findings[1].column);
}

test "unchanged_condition flags a bare identifier condition the body never assigns" {
    try expect_findings(EveryForever, "src/store/page.zig",
        \\fn serve(running: bool) void {
        \\    var count: u32 = 0;
        \\    while (running) {
        \\        count += 1;
        \\        work();
        \\    }
        \\}
    , &.{"while (running) has no break and the body never assigns running"});
}

test "unchanged_condition flags a field chain and a payload loop whose body ignores the payload" {
    try expect_findings(EveryForever, "src/store/page.zig",
        \\fn serve(self: *Self, queue: *Queue) void {
        \\    while (self.state.running) {
        \\        tick();
        \\    }
        \\    while (queue.head) |node| {
        \\        _ = node;
        \\        tick();
        \\    }
        \\}
    , &.{
        "while (self.state.running) has no break and the body never assigns self.state.running",
        "while (queue.head) has no break and the body never assigns queue.head",
    });
}

test "unchanged_condition passes a body that assigns the condition, a prefix or an extension" {
    try expect_findings(EveryForever, "src/store/page.zig",
        \\fn serve(self: *Self, running: bool, head: ?*Node) void {
        \\    while (running) {
        \\        running = false;
        \\    }
        \\    while (self.state.running) {
        \\        self.state = .{ .running = false };
        \\    }
        \\    while (self.state) {
        \\        self.state.running = false;
        \\    }
        \\    while (head) |node| : (head = node.next) {}
        \\    while (running) {
        \\        running, const other = pair();
        \\    }
        \\}
    , &.{});
}

test "unchanged_condition passes a break, an address taken, and a call through the root" {
    try expect_findings(EveryForever, "src/store/page.zig",
        \\fn serve(self: *Self, running: bool, queue: *Queue) void {
        \\    while (running) {
        \\        if (done()) break;
        \\    }
        \\    while (running) {
        \\        stop(&running);
        \\    }
        \\    while (self.running) {
        \\        self.step();
        \\    }
        \\    while (queue.head) |node| {
        \\        consume(queue, node);
        \\    }
        \\}
    , &.{});
}

test "unchanged_condition flags a loop whose only call names the root without a field access" {
    try expect_findings(EveryForever, "src/store/page.zig",
        \\fn serve(poll: bool) void {
        \\    while (poll) {
        \\        poll();
        \\    }
        \\}
    , &.{"while (poll) has no break and the body never assigns poll"});
}

test "unchanged_condition passes a call through the payload capture or passing it" {
    try expect_findings(EveryForever, "src/store/page.zig",
        \\fn serve(self: *Self, queue: *Queue) void {
        \\    while (self.link.head) |node| {
        \\        node.visit();
        \\    }
        \\    while (queue.head) |node| {
        \\        consume(node);
        \\    }
        \\    while (queue.head) |*node| {
        \\        node.unlink();
        \\    }
        \\}
    , &.{});
}

test "unchanged_condition passes a condition that is not a bare identifier or chain" {
    try expect_findings(EveryForever, "src/store/page.zig",
        \\fn serve(iterator: anytype, raw: anytype, n: u32) void {
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {}
        \\    while (iterator.next()) |item| _ = item;
        \\    while (!raw.done) {}
        \\    while (false) {}
        \\}
    , &.{});
}

test "a scope of every Zig file reads tools too, and no other file kind" {
    const source = "fn spin() void {\n    while (true) {}\n}";
    try expect_findings(EveryForever, "tools/lint.zig", source, &.{no_bound});
    try expect_findings(EveryForever, "docs/guide.md", source, &.{});
}

// Check 1 under `.unless_bounded_break` and check 3.

test "unless_bounded_break and length_read pass loops a named limit bounds" {
    try expect_findings(NamedLimit, "src/store/page.zig",
        \\const constants = @import("constants.zig");
        \\pub fn read_entries(self: *Page, reader: *Reader) !void {
        \\    var read: u32 = 0;
        \\    while (reader.remaining() > 0) {
        \\        if (read == constants.entry_count_max) return error.TooManyEntries;
        \\        try self.apply(try reader.read_entry());
        \\        read += 1;
        \\    }
        \\}
        \\pub fn drain(self: *Page) void {
        \\    var index: u32 = 0;
        \\    while (true) {
        \\        if (index == constants.slots_per_page_max) break;
        \\        self.slots[index].reset();
        \\        index += 1;
        \\    }
        \\}
    , &.{});
}

test "length_read and unless_bounded_break flag a length read and a while (true) with no break" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), NamedLimit, "src/store/page.zig",
        \\pub fn read_entries(self: *Page, reader: *Reader) !void {
        \\    while (reader.remaining() > 0) {
        \\        try self.apply(try reader.read_entry());
        \\    }
        \\}
        \\pub fn spin(self: *Page) void {
        \\    while (true) {
        \\        self.step();
        \\    }
        \\}
    );
    try harness.expect_messages(findings, &.{
        "reads reader.remaining against a literal; no limit (handbook 8)",
        without_break,
    });
    try testing.expectEqual(2, findings[0].line);
    try testing.expectEqual(7, findings[1].line);
}

test "unless_bounded_break flags a while (true) whose break rests on no named limit" {
    try expect_findings(NamedLimit, "src/store/page.zig",
        \\pub fn drain(self: *Page, reader: *Reader) void {
        \\    while (true) {
        \\        const entry = reader.next() orelse break;
        \\        self.apply(entry);
        \\    }
        \\}
    , &.{without_bound});
}

test "length_read flags a length field compared to a literal on either side" {
    try expect_findings(NamedLimit, "src/store/table.zig",
        \\pub fn decode(self: *Table, chunk: []const u8) void {
        \\    while (chunk.len != 0) {
        \\        chunk = self.entry(chunk);
        \\    }
        \\    while (0 < self.entries.count()) {
        \\        self.evict();
        \\    }
        \\}
    , &.{
        "reads chunk.len against a literal; no limit (handbook 8)",
        "reads self.entries.count against a literal; no limit (handbook 8)",
    });
}

test "length_read leaves every other condition alone" {
    try expect_findings(NamedLimit, "src/store/page.zig",
        \\pub fn scan(iterator: anytype, count: u32, done: bool, running: bool) void {
        \\    var index: u32 = 0;
        \\    while (index < count) : (index += 1) {}
        \\    while (iterator.next()) |item| _ = item;
        \\    while (!done) {}
        \\    while (false) {}
        \\    for (0..count) |i| _ = i;
        \\    while (index < buffer.len) : (index += 1) {}
        \\    while (running) {}
        \\    while (entries.len > limit) {}
        \\}
    , &.{});
}

test "a bound segment clears a loop whatever its last name" {
    try expect_findings(NamedLimit, "src/store/page.zig",
        \\pub fn reassemble(self: *Page) void {
        \\    while (true) {
        \\        if (self.depth == constants.reassembly_depth) break;
        \\        self.step();
        \\    }
        \\}
    , &.{});
}

test "a bound suffix clears a loop without the bound segment, in the continue expression" {
    try expect_findings(NamedLimit, "src/store/page.zig",
        \\pub fn drain(self: *Page, reader: *Reader) void {
        \\    var read: u32 = 0;
        \\    while (reader.remaining() > 0) : (read = @min(read + 1, ranges_max)) {
        \\        self.step();
        \\    }
        \\}
    , &.{});
}

test "a scope of src reads src alone" {
    const source = "fn spin() void {\n    while (true) {}\n}";
    try expect_findings(NamedLimit, "tools/lint.zig", source, &.{});
    try expect_findings(NamedLimit, "build/modules.zig", source, &.{});
    try expect_findings(NamedLimit, "./src/store/page.zig", source, &.{without_break});
}

// The switches. One fixture holds every shape the two configurations above disagree on.

const disagreements: [:0]const u8 =
    \\fn serve(self: *Page, reader: *Reader, running: bool) void {
    \\    while (true) {
    \\        if (self.index == constants.slots_max) break;
    \\    }
    \\    while (true) {
    \\        const entry = reader.next() orelse break;
    \\        self.apply(entry);
    \\    }
    \\    while (running) {
    \\        tick();
    \\    }
    \\    while (reader.remaining() > 0) {
    \\        tick();
    \\    }
    \\}
;

test "the two configurations read the disagreement fixture each their own way" {
    try expect_findings(EveryForever, "src/store/page.zig", disagreements, &.{
        no_bound,
        no_bound,
        "while (running) has no break and the body never assigns running",
    });
    try expect_findings(NamedLimit, "src/store/page.zig", disagreements, &.{
        without_bound,
        "reads reader.remaining against a literal; no limit (handbook 8)",
    });
}

test "every check off reports nothing" {
    const Off = unbounded_loop.Rule(.{ .scope = .{ .extensions = &.{".zig"} } });
    try expect_findings(Off, "src/store/page.zig", disagreements, &.{});
    try testing.expectEqualStrings("unbounded-loop", Off.name);
}

test "the default texts, the rule name, the bound and the length readers come from the config" {
    const Custom = unbounded_loop.Rule(.{
        .name = "loop-bound",
        .scope = .{ .extensions = &.{".zig"} },
        .forever = .unless_bounded_break,
        .length_read = true,
        .bound = .{ .segments = &.{"limits"} },
        .length_reader_names = &.{"pending"},
    });
    try testing.expectEqualStrings("loop-bound", Custom.name);
    try expect_findings(Custom, "src/store/page.zig",
        \\fn serve(queue: *Queue, reader: *Reader) void {
        \\    while (true) {}
        \\    while (true) {
        \\        if (queue.slots_max == 0) break;
        \\    }
        \\    while (true) {
        \\        if (limits.slots == 0) break;
        \\    }
        \\    while (queue.pending() > 0) {}
        \\    while (reader.remaining() > 0) {}
        \\}
    , &.{
        "while (true) has no break; nothing ends the loop",
        "while (true) breaks on no named bound",
        "the condition reads queue.pending against a literal and the loop names no bound",
    });
}

// Parameter types.

const EveryForeverSimplePrototypes = unbounded_loop.Rule(.{
    .scope = .{ .extensions = &.{".zig"} },
    .forever = .always,
    .unchanged_condition = true,
    .parameter_types = .simple_prototypes_only,
});

const NamedLimitSimplePrototypes = unbounded_loop.Rule(.{
    .scope = .{ .extensions = &.{".zig"}, .include_directories = &.{"src"} },
    .forever = .unless_bounded_break,
    .bound = .{ .segments = &.{"constants"} },
    .messages = .{ .forever_without_break = without_break },
    .parameter_types = .simple_prototypes_only,
});

test "parameter_types decides whether a loop in a two-parameter prototype is read" {
    const source =
        \\fn read(first: @TypeOf(while (true) {}), second: u8) void {
        \\    _ = first;
        \\    _ = second;
        \\}
    ;
    const path = "src/store/page.zig";
    try expect_findings(EveryForever, path, source, &.{no_bound});
    try expect_findings(EveryForeverSimplePrototypes, path, source, &.{});
}

test "parameter_types reaches the body scan of check 2" {
    // The only assignment to `self.running` sits in the parameter type of a two-parameter
    // prototype. Reading it, the body may change the condition; not reading it, the body cannot.
    const source =
        \\fn spin(self: *Spinner) void {
        \\    while (self.running) {
        \\        const Stop = struct {
        \\            fn stop(flag: @TypeOf(blk: {
        \\                self.running = false;
        \\                break :blk 0;
        \\            }), code: u8) void {
        \\                _ = flag;
        \\                _ = code;
        \\            }
        \\        };
        \\        _ = Stop;
        \\    }
        \\}
    ;
    const path = "src/store/page.zig";
    try expect_findings(EveryForever, path, source, &.{});
    try expect_findings(EveryForeverSimplePrototypes, path, source, &.{
        "while (self.running) has no break and the body never assigns self.running",
    });
}

test "parameter_types reaches the loop scan of the named-limit check" {
    // The only `break` sits in the parameter type of a two-parameter prototype.
    const source =
        \\fn spin() void {
        \\    while (true) {
        \\        const Stop = struct {
        \\            fn stop(flag: @TypeOf(blk: {
        \\                break :blk constants.stop_code;
        \\            }), code: u8) void {
        \\                _ = flag;
        \\                _ = code;
        \\            }
        \\        };
        \\        _ = Stop;
        \\    }
        \\}
    ;
    const path = "src/store/page.zig";
    try expect_findings(NamedLimitSimplePrototypes, path, source, &.{without_break});
}
