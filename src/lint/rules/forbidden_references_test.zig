//! Tests for the forbidden-references rule: one fixture per shape the rule's header names, run
//! under five configurations that together use every matcher and switch.
//!
//! - `heap_by_name` forbids the heap by type names, container names and allocator methods.
//! - `clock_by_name` forbids the clock by chain, raw prefix, callee name and segment name, and
//!   excepts unit constants.
//! - `heap_by_parameter` forbids `std.heap`, the allocators of `std.testing`, and an allocator
//!   parameter, and cites a reason.
//! - `host_access` forbids the syscall, file, network, thread and process interfaces.
//! - `clock_whole` forbids the clock and the generators by prefix alone.

const std = @import("std");
const testing = std.testing;
const harness = @import("../harness.zig");
const report = @import("../report.zig");
const rule = @import("forbidden_references.zig");
const Config = rule.Config;

const heap_by_name: Config = .{
    .name = "heap",
    .scope = .{
        .extensions = &.{".zig"},
        .exclude_directories = &.{"tools"},
        .exclude_paths = &.{"src/corpus/generate.zig"},
        .exclude_basename_suffixes = &.{"_test.zig"},
    },
    .prefixes = &.{ "std.heap", "std.mem.Allocator" },
    .segment_names = &.{
        "Allocator",        "ArrayList",                 "ArrayListUnmanaged",
        "ArrayListAligned", "ArrayListAlignedUnmanaged",
    },
    .segment_suffixes = &.{ "HashMap", "HashMapUnmanaged" },
    .method_calls = .{
        .methods_on_any_receiver = &.{"allocator"},
        .methods_on_named_receivers = &.{ "alloc", "create", "destroy", "free" },
        .receiver_words = &.{ "alloc", "arena", "gpa" },
    },
    .parameter_types = .simple_prototypes_only,
};

const clock_by_name: Config = .{
    .name = "determinism",
    .scope = .{
        .extensions = &.{".zig"},
        .exclude_directories = &.{ "src/io/", "tools/" },
        .exclude_stem_segment = "_test",
    },
    .prefixes = &.{ "std.time", "std.Random", "std.crypto.random" },
    .raw_prefixes = &.{"std.posix.clock_"},
    .segment_names = &.{"Instant"},
    .exceptions = &.{.{
        .prefix = "std.time",
        .last_segment_prefixes = &.{ "ns_per_", "us_per_", "ms_per_", "s_per_" },
    }},
    .callee_names = &.{
        "getrandom", "clock_gettime", "nanoTimestamp", "milliTimestamp", "timestamp",
    },
    .parameter_types = .simple_prototypes_only,
};

const heap_reason = "the library holds no heap (rule 1)";

const heap_by_parameter: Config = .{
    .name = "heap",
    .scope = .{ .extensions = &.{".zig"}, .include_directories = &.{"src"} },
    .prefixes = &.{
        "std.heap",                       "std.testing.allocator",
        "std.testing.allocator_instance", "std.testing.failing_allocator",
        "std.testing.FailingAllocator",
    },
    .parameter_check = .{ .type_segment = "Allocator", .description = "an allocator parameter" },
    .reason = heap_reason,
};

const host_reason = "the library owns no I/O (rule 2)";

const host_access: Config = .{
    .name = "io",
    .scope = .{
        .extensions = &.{".zig"},
        .include_directories = &.{"src"},
        .exclude_directories = &.{"src/testing"},
    },
    .prefixes = &.{ "std.posix", "std.fs", "std.net", "std.Thread", "std.Io", "std.process" },
    .reason = host_reason,
};

const clock_reason = "time is a parameter (rule 4)";

const clock_whole: Config = .{
    .name = "determinism",
    .scope = .{ .extensions = &.{".zig"}, .include_directories = &.{"src"} },
    .prefixes = &.{ "std.time", "std.Random", "std.crypto.random" },
    .reason = clock_reason,
};

fn findings_of(
    arena: std.mem.Allocator,
    comptime config: Config,
    path: []const u8,
    source: [:0]const u8,
) ![]const report.Finding {
    return harness.run(arena, rule.Rule(config), path, source);
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

const passing_fixture: [:0]const u8 =
    \\const std = @import("std");
    \\const limits = @import("limits.zig");
    \\
    \\pub const Page = struct {
    \\    slots: [limits.slots_per_page_max]Slot,
    \\    pub fn init(self: *Page, count: u32) void {
    \\        for (self.slots[0..count]) |*slot| slot.* = .{};
    \\    }
    \\    pub fn parse_header(bytes: []const u8) !Header {
    \\        if (bytes.len < header_len) return error.ShortBuffer;
    \\        return .{ .length = std.mem.readInt(u24, bytes[0..3], .big) };
    \\    }
    \\    pub fn on_sent(self: *Page, now_ns: u64, id: []const u8) void {
    \\        self.timeout_ns = now_ns + self.probe_timeout_ns;
    \\        self.id = id;
    \\    }
    \\};
    \\
    \\pub const page_bytes = @sizeOf(Page);
    \\
    \\test "a test declares its scratch memory" {
    \\    var scratch: [64]u8 = @splat(0);
    \\    try std.testing.expectEqual(0, scratch[0]);
    \\}
;

test "a file that names nothing forbidden passes every configuration" {
    const path = "src/store/page.zig";
    try expect_findings(heap_by_name, path, passing_fixture, &.{});
    try expect_findings(clock_by_name, path, passing_fixture, &.{});
    try expect_findings(heap_by_parameter, path, passing_fixture, &.{});
    try expect_findings(host_access, path, passing_fixture, &.{});
    try expect_findings(clock_whole, path, passing_fixture, &.{});
}

test "check 1 reports a prefix chain once, whole, at its first token" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), heap_by_name, "src/a.zig",
        \\const page = std.heap.page_allocator;
        \\fn take(allocator: std.mem.Allocator) void {
        \\    _ = allocator;
        \\}
    );
    try harness.expect_messages(findings, &.{
        "reference to std.heap.page_allocator",
        "reference to std.mem.Allocator",
    });
    try testing.expectEqual(1, findings[0].line);
    try testing.expectEqual(14, findings[0].column);
}

test "check 1 reports segment names and every segment suffix" {
    try expect_findings(heap_by_name, "src/a.zig",
        \\const List = std.ArrayList(u8);
        \\const Bare: ArrayListUnmanaged(u8) = .empty;
        \\const Map = std.AutoHashMap(u32, u32);
        \\const StringMap = std.StringHashMapUnmanaged(u32);
        \\const Alias = Allocator;
        \\const Error = Allocator.Error;
    , &.{
        "reference to std.ArrayList",
        "reference to ArrayListUnmanaged",
        "reference to std.AutoHashMap",
        "reference to std.StringHashMapUnmanaged",
        "reference to Allocator",
        "reference to Allocator.Error",
    });
}

test "check 3 reports a getter on any receiver and a method on a named receiver" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), heap_by_name, "src/a.zig",
        \\fn use(arena: anytype, gpa: anytype, self: anytype) !void {
        \\    const a = arena.allocator();
        \\    const bytes = try gpa.alloc(u8, 1);
        \\    const one = try self.arena.create(u8);
        \\    self.gpa.destroy(one);
        \\    a.free(bytes);
        \\}
    );
    try harness.expect_messages(findings, &.{
        "reference to allocator",
        "reference to alloc",
        "reference to create",
        "reference to destroy",
    });
    try testing.expectEqual(2, findings[0].line);
    try testing.expectEqual(21, findings[0].column);
    // The finding names the method, so the chain check 1 reports is not a duplicate of it.
    const chained = "const b = std.heap.page_allocator.alloc(u8, 1);";
    try expect_findings(heap_by_name, "src/a.zig", chained, &.{
        "reference to std.heap.page_allocator.alloc",
        "reference to alloc",
    });
}

test "check 3 leaves a slot free-list and every other receiver alone" {
    try expect_findings(heap_by_name, "src/a.zig",
        \\fn use(list: anytype, journal: anytype, dir: anytype) !void {
        \\    list.free(3);
        \\    journal.free_list.free(9);
        \\    _ = try list.allocate();
        \\    _ = try dir.createFile("x", .{});
        \\    _ = allocator();
        \\    _ = alloc(u8, journal.free_slots);
        \\}
    , &.{});
}

test "no configuration reports a name that merely resembles one it forbids" {
    const path = "src/store/page.zig";
    try expect_findings(heap_by_name, path,
        \\const heap_size = constants.std_heap_bytes;
        \\const Allocation = struct { slot: u32 };
        \\const map = self.ArrayListLike;
    , &.{});
    try expect_findings(clock_by_name, path,
        \\const timeout = std.timer.ns_per_ms;
        \\const instant_count = self.Instants;
        \\const r = std.RandomAccess.open();
        \\const t = std.posix.clockwork();
    , &.{});
    try expect_findings(heap_by_parameter, path,
        \\fn one(allocation: Allocations) void {}
        \\fn two(bytes: []u8, pool: pools.ArenaAllocator) void {}
        \\const heap_limit = constants.std_heap_bytes;
    , &.{});
    try expect_findings(host_access, path,
        \\const bytes = constants.std_posix_bytes;
        \\const other = std.posixish.socket;
        \\const mine = self.std.posix;
        \\const written = std.fmt.bufPrint(&buffer, "{d}", .{1});
    , &.{});
    try expect_findings(clock_whole, path,
        \\const timeout_ns = constants.probe_timeout_ns;
        \\const hash = std.crypto.hash.sha2.Sha256;
        \\const elapsed = now_ns - self.last_sent_ns;
    , &.{});
}

test "checks 1 and 2 report clock chains, clock calls, entropy and Instant" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), clock_by_name, "src/store/a.zig",
        \\const timer = std.time.Timer;
        \\const now = std.time.timestamp();
        \\const Prng = std.Random.DefaultPrng;
        \\const byte = std.crypto.random.int(u8);
        \\const a = std.posix.clock_gettime(.MONOTONIC);
        \\const b = posix.clock_gettime(.MONOTONIC);
        \\const c = getrandom(&buffer);
        \\const d = time.Instant.now();
        \\const e = clock.nanoTimestamp();
        \\const f = clock.milliTimestamp();
    );
    try harness.expect_messages(findings, &.{
        "reference to std.time.Timer",
        "reference to std.time.timestamp",
        "reference to std.Random.DefaultPrng",
        "reference to std.crypto.random.int",
        "reference to std.posix.clock_gettime",
        "reference to posix.clock_gettime",
        "reference to getrandom",
        "reference to time.Instant.now",
        "reference to clock.nanoTimestamp",
        "reference to clock.milliTimestamp",
    });
    try testing.expectEqual(2, findings[1].line);
    try testing.expectEqual(13, findings[1].column);
}

test "check 2 reads a name only as a callee and reports a chain check 1 reports once" {
    try expect_findings(clock_by_name, "src/store/header.zig",
        \\const offset_timestamp = 80;
        \\fn copy(header: *Header, values: Values) void {
        \\    header.timestamp = values.timestamp;
        \\    const timestamp: u64 = header.timestamp;
        \\    _ = timestamp;
        \\}
        \\const zero = &.{"timestamp"};
    , &.{});
    try expect_findings(clock_by_name, "src/store/a.zig",
        \\const now = std.time.nanoTimestamp();
    , &.{"reference to std.time.nanoTimestamp"});
}

const unit_fixture: [:0]const u8 =
    \\const tick = std.time.ns_per_ms;
    \\const day = std.time.s_per_day;
    \\fn now() i128 {
    \\    return std.time.nanoTimestamp();
    \\}
;

test "an exception allows unit constants, and without one they are findings" {
    try expect_findings(clock_by_name, "src/store/a.zig", unit_fixture, &.{
        "reference to std.time.nanoTimestamp",
    });
    try expect_findings(clock_whole, "src/store/a.zig", unit_fixture, &.{
        "reference to std.time.ns_per_ms: " ++ clock_reason,
        "reference to std.time.s_per_day: " ++ clock_reason,
        "reference to std.time.nanoTimestamp: " ++ clock_reason,
    });
}

test "a reason follows every finding of a prefix configuration" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), clock_whole, "src/store/a.zig",
        \\pub fn on_sent(self: *Page, id: Id) void {
        \\    self.last_sent_ns = std.time.nanoTimestamp();
        \\    self.timeout_ns = self.last_sent_ns + 3 * std.time.ns_per_ms;
        \\    self.id = std.crypto.random.int(u64);
        \\    var generator = std.Random.DefaultPrng.init(0);
        \\    self.jitter = generator.random().int(u8);
        \\    _ = id;
        \\}
    );
    try harness.expect_messages(findings, &.{
        "reference to std.time.nanoTimestamp: " ++ clock_reason,
        "reference to std.time.ns_per_ms: " ++ clock_reason,
        "reference to std.crypto.random.int: " ++ clock_reason,
        "reference to std.Random.DefaultPrng.init: " ++ clock_reason,
    });
    try testing.expectEqual(2, findings[0].line);
    try testing.expectEqual(5, findings[3].line);
}

test "check 1 reports host access in a body, and stops a chain at a call" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), host_access, "src/net/serve.zig",
        \\pub fn serve(port: u16) !void {
        \\    const address = try std.net.Address.parseIp("127.0.0.1", port);
        \\    const socket = try std.posix.socket(2, 1, 0);
        \\    const thread = try std.Thread.spawn(.{}, run, .{socket});
        \\    const file = try std.fs.cwd().openFile("x", .{});
        \\    _ = .{ address, thread, file };
        \\}
    );
    try harness.expect_messages(findings, &.{
        "reference to std.net.Address.parseIp: " ++ host_reason,
        "reference to std.posix.socket: " ++ host_reason,
        "reference to std.Thread.spawn: " ++ host_reason,
        "reference to std.fs.cwd: " ++ host_reason,
    });
    try testing.expectEqual(2, findings[0].line);
    try testing.expectEqual(25, findings[0].column);
}

const parameter_fixture: [:0]const u8 =
    \\fn send(socket: std.posix.socket_t, file: std.fs.File, count: u32) void {}
    \\fn wait(until: std.Io.Timestamp) std.process.Child {}
    \\const listener = std.net.Server;
    \\const worker = std.Thread;
;

test "the walk reads parameter types according to parameter_types" {
    try expect_findings(host_access, "src/net/a.zig", parameter_fixture, &.{
        "reference to std.posix.socket_t: " ++ host_reason,
        "reference to std.fs.File: " ++ host_reason,
        "reference to std.Io.Timestamp: " ++ host_reason,
        "reference to std.process.Child: " ++ host_reason,
        "reference to std.net.Server: " ++ host_reason,
        "reference to std.Thread: " ++ host_reason,
    });
    const simple: Config = comptime modified: {
        var config = host_access;
        config.parameter_types = .simple_prototypes_only;
        break :modified config;
    };
    try expect_findings(simple, "src/net/a.zig", parameter_fixture ++
        \\
        \\fn close(socket: std.posix.socket_t) callconv(.c) std.fs.File {}
    , &.{
        "reference to std.Io.Timestamp: " ++ host_reason,
        "reference to std.process.Child: " ++ host_reason,
        "reference to std.net.Server: " ++ host_reason,
        "reference to std.Thread: " ++ host_reason,
        "reference to std.fs.File: " ++ host_reason,
    });
}

test "check 4 reports an allocator parameter on any function, init included" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), heap_by_parameter, "src/a.zig",
        \\const arena_type = std.heap.ArenaAllocator;
        \\
        \\pub fn read(allocator: std.mem.Allocator, bytes: []const u8) !usize {
        \\    return bytes.len;
        \\}
        \\pub const Pool = struct {
        \\    pub fn init(allocator: std.mem.Allocator, count: u32) !Pool {
        \\        return .{ .slots = try allocator.alloc(Slot, count) };
        \\    }
        \\};
    );
    try harness.expect_messages(findings, &.{
        "reference to std.heap.ArenaAllocator: " ++ heap_reason,
        "read takes an allocator parameter: " ++ heap_reason,
        "init takes an allocator parameter: " ++ heap_reason,
    });
    try testing.expectEqual(1, findings[0].line);
    try testing.expectEqual(3, findings[1].line);
    try testing.expectEqual(24, findings[1].column);
}

test "check 4 finds wrapped types, each parameter, and a function type without a name" {
    try expect_findings(heap_by_parameter, "src/a.zig",
        \\fn one(allocator: *const std.mem.Allocator) void {}
        \\fn two(allocator: ?Allocator) void {}
        \\fn three(allocators: []const mem.Allocator) void {}
        \\pub const Pool = struct {
        \\    pub fn grow(self: *Pool, allocator: Allocator, second: Allocator) void {}
        \\};
        \\pub const Provider = struct {
        \\    start: *const fn (allocator: Allocator) void,
        \\};
    , &.{
        "one takes an allocator parameter: " ++ heap_reason,
        "two takes an allocator parameter: " ++ heap_reason,
        "three takes an allocator parameter: " ++ heap_reason,
        "grow takes an allocator parameter: " ++ heap_reason,
        "grow takes an allocator parameter: " ++ heap_reason,
        "an anonymous function type takes an allocator parameter: " ++ heap_reason,
    });
}

test "check 1 reports the allocators of std.testing a configuration lists" {
    try expect_findings(heap_by_parameter, "src/wire/decode.zig",
        \\test "decode" {
        \\    const one = std.testing.allocator;
        \\    const two = std.testing.failing_allocator;
        \\    var three = std.testing.FailingAllocator.init(one, .{});
        \\    const four = std.testing.allocator_instance;
        \\    try std.testing.expect(true);
        \\}
    , &.{
        "reference to std.testing.allocator: " ++ heap_reason,
        "reference to std.testing.failing_allocator: " ++ heap_reason,
        "reference to std.testing.FailingAllocator.init: " ++ heap_reason,
        "reference to std.testing.allocator_instance: " ++ heap_reason,
    });
}

test "each configuration reads the files its scope names and no others" {
    const heap = "const page = std.heap.page_allocator;";
    const heap_finding = "reference to std.heap.page_allocator";
    try expect_findings(heap_by_name, "src/corpus/other.zig", heap, &.{heap_finding});
    try expect_findings(heap_by_name, "tools/lint/main.zig", heap, &.{});
    try expect_findings(heap_by_name, "./src/corpus/generate.zig", heap, &.{});
    try expect_findings(heap_by_name, "src/store/journal_crash_test.zig", heap, &.{});
    try expect_findings(heap_by_name, "docs/a.md", heap, &.{});

    const clock = "const now = std.time.timestamp();";
    const clock_finding = "reference to std.time.timestamp";
    try expect_findings(clock_by_name, "./src/sim/disk.zig", clock, &.{clock_finding});
    try expect_findings(clock_by_name, "src/iota/a.zig", clock, &.{clock_finding});
    try expect_findings(clock_by_name, "src/store/journal_testing.zig", clock, &.{clock_finding});
    try expect_findings(clock_by_name, "src/io/linux.zig", clock, &.{});
    try expect_findings(clock_by_name, "src/store/journal_crash_test_torn.zig", clock, &.{});

    try expect_findings(heap_by_parameter, "./src/testing/endpoint.zig", heap, &.{
        heap_finding ++ ": " ++ heap_reason,
    });
    try expect_findings(heap_by_parameter, "build/modules.zig", heap, &.{});
    try expect_findings(clock_whole, "src/testing/endpoint.zig", clock, &.{
        clock_finding ++ ": " ++ clock_reason,
    });
    try expect_findings(clock_whole, "tools/graph.zig", clock, &.{});

    const socket = "const socket = std.posix.socket;";
    try expect_findings(host_access, "src/net/a.zig", socket, &.{
        "reference to std.posix.socket: " ++ host_reason,
    });
    try expect_findings(host_access, "./src/testing/deep/endpoint.zig", socket, &.{});
    try expect_findings(host_access, "tools/graph.zig", socket, &.{});
}
