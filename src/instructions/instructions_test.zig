//! Tests of the instructions engine: the command line, the configuration, and each verdict `run`
//! reaches, counted by a counter that charges a fixed setup and a cost per operation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const instructions = @import("instructions.zig");

const testing = std.testing;

const project: instructions.Config = .{
    .cases = &.{
        .{ .name = "cache_hit", .arguments = &.{"hit"} },
        .{ .name = "query_build", .arguments = &.{ "build", "long" }, .rounds = 250 },
    },
};

const Cost = struct { argument: []const u8, per_operation: u64 };

const costs_fixture = [_]Cost{
    .{ .argument = "hit", .per_operation = 153 },
    .{ .argument = "build", .per_operation = 1200 },
};

/// A counter that charges `setup` for a run and a cost per operation, by the case's first argument.
const FakeCounter = struct {
    label: []const u8 = "cachegrind 3.22.0",
    costs: []const Cost = &costs_fixture,
    setup: u64 = 40_000,
    /// Added to the second of a case's two short runs.
    jitter: u64 = 0,
    /// The long run counts less than the short ones.
    long_less: bool = false,
    runs: *u64,

    pub fn count(self: FakeCounter, program: []const u8, arguments: []const []const u8, rounds: u64) !instructions.cachegrind.Count {
        std.debug.assert(std.mem.eql(u8, program, "bench"));
        self.runs.* += 1;
        const cost = self.cost_of(arguments[0]) orelse return .{ .failed = .{
            .reason = "the program exited with status 1",
            .output = "==7== Command: bench build long 250\nbench: no case named build\n",
        } };
        // A case counts short, short again, then long: the third of every three runs is long.
        const place = self.runs.* % 3;
        if (place == 0 and self.long_less) return .{ .total = self.setup - 1 };
        const noise = if (place == 2) self.jitter else 0;
        return .{ .total = self.setup + cost * rounds + noise };
    }

    fn cost_of(self: FakeCounter, argument: []const u8) ?u64 {
        for (self.costs) |cost| {
            if (std.mem.eql(u8, cost.argument, argument)) return cost.per_operation;
        }
        return null;
    }
};

/// What a run printed, on standard output and standard error.
const Printed = struct {
    out_buffer: [8192]u8 = undefined,
    errors_buffer: [8192]u8 = undefined,
    out: Io.Writer = undefined,
    errors: Io.Writer = undefined,

    fn reset(self: *Printed) void {
        self.out = .fixed(&self.out_buffer);
        self.errors = .fixed(&self.errors_buffer);
    }

    fn printed(self: *const Printed, text: []const u8) bool {
        return std.mem.indexOf(u8, self.out.buffered(), text) != null or
            std.mem.indexOf(u8, self.errors.buffered(), text) != null;
    }
};

/// A baseline path inside a test's own directory.
fn baseline_path(arena: Allocator, tmp: *const testing.TmpDir) ![]const u8 {
    return std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/instructions.zon", .{tmp.sub_path});
}

/// Runs the engine once, checking or writing the baseline in `tmp`, and returns its exit status.
fn run_once(arena: Allocator, tmp: *const testing.TmpDir, counter: FakeCounter, rewrite: bool, printed: *Printed) !u8 {
    printed.reset();
    const context: instructions.Context = .{ .arena = arena, .io = testing.io, .out = &printed.out, .errors = &printed.errors };
    const invocation: instructions.Invocation = .{ .rewrite = rewrite, .program = "bench", .baseline = try baseline_path(arena, tmp) };
    return instructions.run(context, project, counter, invocation);
}

fn read_baseline(arena: Allocator, tmp: *const testing.TmpDir) ![]const u8 {
    return tmp.dir.readFileAlloc(testing.io, "instructions.zon", arena, .limited(64 * 1024));
}

test "parse_arguments reads a program, or --rewrite and a program, and nothing else" {
    const check = instructions.parse_arguments(&.{"zig-out/bin/bench"}, "bench/instructions.zon").?;
    try testing.expect(!check.rewrite);
    try testing.expectEqualStrings("zig-out/bin/bench", check.program);
    try testing.expectEqualStrings("bench/instructions.zon", check.baseline);
    try testing.expect(instructions.parse_arguments(&.{ "--rewrite", "bench" }, "b.zon").?.rewrite);
    const refused = [_][]const []const u8{
        &.{},                     &.{"--rewrite"},          &.{ "bench", "--rewrite" },
        &.{ "--rewrite", "--x" }, &.{ "--check", "bench" }, &.{ "a", "b", "c" },
    };
    for (refused) |given| try testing.expectEqual(null, instructions.parse_arguments(given, "b.zon"));
}

test "check_config refuses a configuration the engine cannot run" {
    try testing.expectEqual(null, instructions.check_config(project));
    const refused = [_]instructions.Config{
        .{ .cases = &.{} },
        .{ .cases = &.{.{ .name = "a" }}, .threshold_per_mille = 0 },
        .{ .cases = &.{.{ .name = "a" }}, .threshold_per_mille = 1000 },
        .{ .cases = &.{.{ .name = "" }} },
        .{ .cases = &.{.{ .name = "cache hit" }} },
        .{ .cases = &.{.{ .name = "a" ** 65 }} },
        .{ .cases = &.{ .{ .name = "a" }, .{ .name = "a" } } },
        .{ .cases = &.{.{ .name = "a" }}, .rounds = 0 },
        .{ .cases = &.{.{ .name = "a", .rounds = instructions.baseline.rounds_max + 1 }} },
    };
    inline for (refused) |config| try testing.expect(instructions.check_config(config) != null);
    try testing.expectEqual(null, instructions.check_config(.{ .cases = &.{.{ .name = "a" ** 64, .rounds = 1 << 32 }} }));
}

test "a rewrite writes every case's cost, and a check of the same code passes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var runs: u64 = 0;
    var printed: Printed = .{};
    try testing.expectEqual(0, try run_once(arena, &tmp, .{ .runs = &runs }, true, &printed));
    try testing.expect(printed.printed("instructions.zon:8:12: note: [instructions] cache_hit: wrote 153.0 instructions per operation"));
    try testing.expect(printed.printed("query_build: wrote 1200.0 instructions per operation"));
    const written = try read_baseline(arena, &tmp);
    try testing.expect(std.mem.indexOf(u8, written, ".{ .name = \"query_build\", .rounds = 250, .instructions = 300000 },") != null);
    try testing.expectEqual(0, try run_once(arena, &tmp, .{ .runs = &runs }, false, &printed));
    try testing.expect(printed.printed("instructions.zon:8:12: note: [instructions] cache_hit: 153.0 instructions per operation, +0.0% from 153.0, within 2.0%"));
    try testing.expectEqual(12, runs);
}

test "a case that grew past the threshold fails, and one that grew to it passes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var runs: u64 = 0;
    var printed: Printed = .{};
    const was = [_]Cost{ .{ .argument = "hit", .per_operation = 150 }, costs_fixture[1] };
    try testing.expectEqual(0, try run_once(arena, &tmp, .{ .costs = &was, .runs = &runs }, true, &printed));
    const at_threshold = [_]Cost{ .{ .argument = "hit", .per_operation = 153 }, costs_fixture[1] };
    try testing.expectEqual(0, try run_once(arena, &tmp, .{ .costs = &at_threshold, .runs = &runs }, false, &printed));
    const past = [_]Cost{ .{ .argument = "hit", .per_operation = 154 }, costs_fixture[1] };
    try testing.expectEqual(1, try run_once(arena, &tmp, .{ .costs = &past, .runs = &runs }, false, &printed));
    try testing.expect(printed.printed("instructions.zon:8:12: error: [instructions] cache_hit grew to 154.0 instructions per operation, +2.7% from 150.0, past 2.0%"));
    try testing.expect(printed.printed("note: [instructions] query_build: 1200.0 instructions per operation"));
}

test "a case that shrank past the threshold fails and asks for a rewrite" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var runs: u64 = 0;
    var printed: Printed = .{};
    try testing.expectEqual(0, try run_once(arena, &tmp, .{ .runs = &runs }, true, &printed));
    const cheaper = [_]Cost{ costs_fixture[0], .{ .argument = "build", .per_operation = 1100 } };
    try testing.expectEqual(1, try run_once(arena, &tmp, .{ .costs = &cheaper, .runs = &runs }, false, &printed));
    try testing.expect(printed.printed("query_build shrank to 1100.0 instructions per operation, -8.3% from 1200.0, past 2.0%: write the baseline anew with --rewrite to keep the gain"));
}

test "an unstable case fails, and a rewrite that meets one leaves the baseline as it was" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var runs: u64 = 0;
    var printed: Printed = .{};
    try testing.expectEqual(0, try run_once(arena, &tmp, .{ .runs = &runs }, true, &printed));
    const before = try read_baseline(arena, &tmp);
    // cache_hit's room is 153,000 * 20 / 1000 = 3,060, and a tenth of it 306; query_build's is 600.
    const noisy: FakeCounter = .{ .jitter = 500, .runs = &runs };
    try testing.expectEqual(1, try run_once(arena, &tmp, noisy, false, &printed));
    try testing.expect(printed.printed("cache_hit is unstable: two runs of 1000 rounds differed by 500 instructions"));
    try testing.expect(printed.printed("query_build: 1200.0 instructions per operation"));
    try testing.expectEqual(1, try run_once(arena, &tmp, noisy, true, &printed));
    try testing.expect(printed.printed("error: [instructions] not written: 1 of 2 cases could not be counted"));
    try testing.expectEqualStrings(before, try read_baseline(arena, &tmp));
}

test "a long run that counts less than a short one fails its case" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var runs: u64 = 0;
    var printed: Printed = .{};
    try testing.expectEqual(1, try run_once(arena, &tmp, .{ .long_less = true, .runs = &runs }, true, &printed));
    try testing.expect(printed.printed("cache_hit counted fewer instructions over 2000 rounds than over 1000"));
}

test "a missing baseline, a malformed one, and one counted elsewhere are not judged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var runs: u64 = 0;
    var printed: Printed = .{};
    try testing.expectEqual(2, try run_once(arena, &tmp, .{ .runs = &runs }, false, &printed));
    try testing.expect(printed.printed("instructions.zon: error: [instructions] missing: write it with --rewrite"));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "instructions.zon", .data = ".{\n    .counter = 3,\n}\n" });
    try testing.expectEqual(2, try run_once(arena, &tmp, .{ .runs = &runs }, false, &printed));
    try testing.expect(printed.printed("instructions.zon:2:"));
    try testing.expectEqual(0, try run_once(arena, &tmp, .{ .runs = &runs }, true, &printed));
    const counted_before = runs;
    try testing.expectEqual(2, try run_once(arena, &tmp, .{ .label = "cachegrind 3.23.0", .runs = &runs }, false, &printed));
    try testing.expect(printed.printed("was counted by cachegrind 3.22.0 under Zig "));
    try testing.expect(printed.printed("and this run counts by cachegrind 3.23.0 under Zig "));
    try testing.expectEqual(counted_before, runs);
}

/// Writes a baseline with every case, then replaces `old` in it with `new`.
fn edit_baseline(arena: Allocator, tmp: *const testing.TmpDir, runs: *u64, old: []const u8, new: []const u8) !void {
    var printed: Printed = .{};
    try testing.expectEqual(0, try run_once(arena, tmp, .{ .runs = runs }, true, &printed));
    const written = try read_baseline(arena, tmp);
    try testing.expect(std.mem.indexOf(u8, written, old) != null);
    const edited = try std.mem.replaceOwned(u8, arena, written, old, new);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "instructions.zon", .data = edited });
}

test "a case the baseline lacks fails, and the others are still judged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var runs: u64 = 0;
    var printed: Printed = .{};
    try edit_baseline(arena, &tmp, &runs, "        .{ .name = \"query_build\", .rounds = 250, .instructions = 300000 },\n", "");
    try testing.expectEqual(1, try run_once(arena, &tmp, .{ .runs = &runs }, false, &printed));
    try testing.expect(printed.printed("error: [instructions] holds no count for case query_build: write it anew with --rewrite"));
    try testing.expect(printed.printed("cache_hit: 153.0 instructions per operation"));
}

test "an entry no case names fails, and the cases are still judged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var runs: u64 = 0;
    var printed: Printed = .{};
    try edit_baseline(arena, &tmp, &runs, "    },\n}\n", "        .{ .name = \"query_old\", .rounds = 10, .instructions = 50 },\n    },\n}\n");
    try testing.expectEqual(1, try run_once(arena, &tmp, .{ .runs = &runs }, false, &printed));
    try testing.expect(printed.printed("instructions.zon:10:12: error: [instructions] counts case query_old, which the configuration does not name"));
    try testing.expect(printed.printed("cache_hit: 153.0 instructions per operation"));
    try testing.expect(printed.printed("query_build: 1200.0 instructions per operation"));
}

test "a case the counter cannot count fails with the reason, and the others are still judged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var runs: u64 = 0;
    var printed: Printed = .{};
    try testing.expectEqual(0, try run_once(arena, &tmp, .{ .runs = &runs }, true, &printed));
    try testing.expectEqual(1, try run_once(arena, &tmp, .{ .costs = costs_fixture[0..1], .runs = &runs }, false, &printed));
    try testing.expect(printed.printed("query_build could not be counted: the program exited with status 1"));
    try testing.expect(std.mem.endsWith(u8, printed.errors.buffered(), "bench: no case named build\n"));
    try testing.expect(printed.printed("cache_hit: 153.0 instructions per operation"));
}

test "a rewrite refuses a case that counts no instructions per operation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var runs: u64 = 0;
    var printed: Printed = .{};
    const free = [_]Cost{ .{ .argument = "hit", .per_operation = 0 }, costs_fixture[1] };
    try testing.expectEqual(1, try run_once(arena, &tmp, .{ .costs = &free, .runs = &runs }, true, &printed));
    try testing.expect(printed.printed("cache_hit counted no instructions per operation"));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "instructions.zon", .{}));
}

test "start refuses a command line it cannot read, and a counter that does not run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var printed: Printed = .{};
    printed.reset();
    const context: instructions.Context = .{ .arena = arena_state.allocator(), .io = testing.io, .out = &printed.out, .errors = &printed.errors };
    try testing.expectEqual(2, try instructions.start(context, project, &.{}));
    try testing.expect(printed.printed("instructions: error: [instructions] usage: instructions [--rewrite] <program>"));
    const absent: instructions.Config = .{ .cases = project.cases, .valgrind_program = "pepegrillo-test-no-such-valgrind" };
    try testing.expectEqual(2, try instructions.start(context, absent, &.{"bench"}));
    try testing.expect(printed.printed("bench/instructions.zon: error: [instructions] cannot count: pepegrillo-test-no-such-valgrind did not run (FileNotFound)"));
}
