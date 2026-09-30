//! cachegrind, valgrind's tool that counts the instructions a program retires, as the engine's
//! counter. It needs no permission a hosted runner withholds, and it counts the same total for the
//! same program and input on every run, so a busy machine moves no count.
//!
//! The engine asks for instructions alone (`--cache-sim=no`) and no per-function file, and reads
//! the total from the summary valgrind writes to standard error when the program exits:
//!
//!     ==2843== I refs:        967,268
//!
//! valgrind hides AVX-512 and SVE from a program's CPU probe, so a program that picks its code path
//! at run time takes another path under the counter: a case names the path it measures.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// valgrind's options: cachegrind, counting instructions alone, writing no per-function file.
const tool_options = [_][]const u8{ "--tool=cachegrind", "--cache-sim=no", "--cachegrind-out-file=/dev/null" };
/// The option that asks valgrind for its release.
const version_option = "--version";
/// What `valgrind --version` prints before the release, as in `valgrind-3.22.0`.
const version_prefix = "valgrind-";
/// The counter's name in a baseline, before valgrind's release.
const label_prefix = "cachegrind ";
/// The prefix valgrind puts on every line of its own on standard error.
const summary_line_prefix = "==";
/// The summary field that holds the instructions a run retired, and the event it counts.
const refs_field = "refs:";
const refs_event = "I";
/// Bytes of a counted run's standard output and standard error kept. The summary is the end of
/// standard error, so a program that prints more than this fails its count.
const output_len_max: usize = 16 * 1024 * 1024;
/// Bytes of `valgrind --version`'s output kept.
const version_len_max: usize = 4096;

/// What one counted run gave: its total, or why it gave none.
pub const Count = union(enum) {
    total: u64,
    failed: Failure,
};

pub const Failure = struct {
    /// How the run ended, for the report.
    reason: []const u8,
    /// What the run wrote to standard error, whose end the report shows.
    output: []const u8,
};

pub const Cachegrind = struct {
    arena: Allocator,
    io: Io,
    valgrind_program: []const u8,
    /// `cachegrind` and valgrind's release, which a baseline records.
    label: []const u8,

    /// Asks valgrind for its release. Fails with `error.FileNotFound` when there is no valgrind.
    pub fn open(arena: Allocator, io: Io, valgrind_program: []const u8) !Cachegrind {
        const result = try std.process.run(arena, io, .{
            .argv = &.{ valgrind_program, version_option },
            .stdout_limit = .limited(version_len_max),
            .stderr_limit = .limited(version_len_max),
        });
        if (try end_reason(arena, result.term) != null) return error.UnknownVersion;
        return .{
            .arena = arena,
            .io = io,
            .valgrind_program = valgrind_program,
            .label = try label_of(arena, result.stdout),
        };
    }

    /// The instructions `program` retires when it runs with `arguments` and then `rounds`.
    pub fn count(self: Cachegrind, program: []const u8, arguments: []const []const u8, rounds: u64) !Count {
        const result = try std.process.run(self.arena, self.io, .{
            .argv = try argv(self.arena, self.valgrind_program, program, arguments, rounds),
            .stdout_limit = .limited(output_len_max),
            .stderr_limit = .limited(output_len_max),
        });
        if (try end_reason(self.arena, result.term)) |reason| return .{ .failed = .{ .reason = reason, .output = result.stderr } };
        const total = refs_of(result.stderr) orelse return .{ .failed = .{ .reason = "valgrind printed no instruction total", .output = result.stderr } };
        return .{ .total = total };
    }
};

/// The command that counts one run: valgrind and its options, then the program, its arguments and
/// the round count.
pub fn argv(
    arena: Allocator,
    valgrind_program: []const u8,
    program: []const u8,
    arguments: []const []const u8,
    rounds: u64,
) ![]const []const u8 {
    var command: std.ArrayList([]const u8) = .empty;
    try command.append(arena, valgrind_program);
    try command.appendSlice(arena, &tool_options);
    try command.append(arena, program);
    try command.appendSlice(arena, arguments);
    try command.append(arena, try std.fmt.allocPrint(arena, "{d}", .{rounds}));
    return command.items;
}

/// The label a baseline records for the counter, from `valgrind --version`'s output.
pub fn label_of(arena: Allocator, version_output: []const u8) ![]const u8 {
    const first_line = std.mem.sliceTo(version_output, '\n');
    const line = std.mem.trim(u8, first_line, " \t\r");
    if (!std.mem.startsWith(u8, line, version_prefix)) return error.UnknownVersion;
    const release = line[version_prefix.len..];
    if (release.len == 0) return error.UnknownVersion;
    for (release) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '.' and character != '-') return error.UnknownVersion;
    }
    return std.mem.concat(arena, u8, &.{ label_prefix, release });
}

/// The total on the last `I refs:` line valgrind wrote, or null when it wrote none. A line the
/// program itself printed carries no `==` prefix and is skipped.
pub fn refs_of(standard_error: []const u8) ?u64 {
    var found: ?u64 = null;
    var lines = std.mem.splitScalar(u8, standard_error, '\n');
    while (lines.next()) |line| {
        if (refs_in(line)) |total| found = total;
    }
    return found;
}

/// The total on one summary line, as in `==2843== I refs:  967,268`; null for any other line.
fn refs_in(line: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, line, summary_line_prefix)) return null;
    const field = std.mem.indexOf(u8, line, refs_field) orelse return null;
    var names = std.mem.tokenizeScalar(u8, line[0..field], ' ');
    _ = names.next() orelse return null;
    const event = names.next() orelse return null;
    if (!std.mem.eql(u8, event, refs_event) or names.next() != null) return null;
    return grouped_number(std.mem.trim(u8, line[field + refs_field.len ..], " \t\r"));
}

/// A number printed with commas between groups of digits, as valgrind prints totals.
fn grouped_number(text: []const u8) ?u64 {
    var total: u64 = 0;
    var digits: usize = 0;
    for (text) |character| {
        if (character == ',') continue;
        if (!std.ascii.isDigit(character)) return null;
        total = std.math.mul(u64, total, 10) catch return null;
        total = std.math.add(u64, total, character - '0') catch return null;
        digits += 1;
    }
    return if (digits == 0) null else total;
}

/// How a run that did not exit with status 0 ended, or null for one that did.
pub fn end_reason(arena: Allocator, term: std.process.Child.Term) !?[]const u8 {
    return switch (term) {
        .exited => |code| if (code == 0) null else try std.fmt.allocPrint(arena, "the program exited with status {d}", .{code}),
        .signal => |signal| try std.fmt.allocPrint(arena, "the program ended on signal {d}", .{@intFromEnum(signal)}),
        .stopped => |signal| try std.fmt.allocPrint(arena, "the program stopped on signal {d}", .{@intFromEnum(signal)}),
        .unknown => |value| try std.fmt.allocPrint(arena, "the program ended in a way the system reports as {d}", .{value}),
    };
}

// Tests.

const testing = std.testing;

test "argv runs the program under cachegrind with its arguments and the round count last" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const command = try argv(arena_state.allocator(), "valgrind", "zig-out/bin/bench", &.{ "cache", "hit" }, 1000);
    const expected = [_][]const u8{
        "valgrind",          "--tool=cachegrind", "--cache-sim=no", "--cachegrind-out-file=/dev/null",
        "zig-out/bin/bench", "cache",             "hit",            "1000",
    };
    try testing.expectEqual(expected.len, command.len);
    for (expected, command) |want, got| try testing.expectEqualStrings(want, got);
}

test "label_of names cachegrind and valgrind's release, and refuses any other output" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("cachegrind 3.22.0", try label_of(arena, "valgrind-3.22.0\n"));
    try testing.expectEqualStrings("cachegrind 3.25.1.GIT", try label_of(arena, "valgrind-3.25.1.GIT\r\n"));
    try testing.expectError(error.UnknownVersion, label_of(arena, "3.22.0\n"));
    try testing.expectError(error.UnknownVersion, label_of(arena, "valgrind-\n"));
    try testing.expectError(error.UnknownVersion, label_of(arena, "valgrind-3.22 \"x\"\n"));
}

test "refs_of reads valgrind's total, commas dropped, whatever the spacing" {
    const current =
        \\==2843== Cachegrind, a high-precision tracing profiler
        \\==2843== Command: ./bench hash 1000
        \\==2843==
        \\==2843== I refs:        967,268
        \\
    ;
    try testing.expectEqual(967268, refs_of(current));
    try testing.expectEqual(1120268, refs_of("==77== I   refs:      1,120,268\n"));
    try testing.expectEqual(12, refs_of("==77== I refs: 12"));
}

test "refs_of skips what the program printed and takes valgrind's last total" {
    const mixed =
        \\I refs: 5
        \\==9== I refs: 10
        \\==9== D refs: 99
        \\cache hit I refs: 7
        \\==9== I refs: 20
        \\
    ;
    try testing.expectEqual(20, refs_of(mixed));
    try testing.expectEqual(20, refs_of("==9== I refs: 20\nhit I refs: 7\n"));
    try testing.expectEqual(null, refs_of("==9== I refs:\n==9== D refs: 4\nI refs: 3\n"));
    try testing.expectEqual(null, refs_of("==9== I refs: 1.5e6\n"));
    try testing.expectEqual(null, refs_of("==9== I refs: 99,999,999,999,999,999,999\n"));
}

/// What a script that stands in for valgrind does: for `--version` it prints `version` and exits
/// with `version_status`; for a count it writes `summary` to standard error and exits with `status`.
const StandIn = struct {
    version: []const u8 = "valgrind-3.99.0",
    version_status: u8 = 0,
    summary: []const u8 = "",
    status: u8 = 0,
};

/// Writes a script that does what `stand_in` says, and returns its path.
fn write_stand_in(tmp: *testing.TmpDir, arena: Allocator, name: []const u8, stand_in: StandIn) ![]const u8 {
    const script = try std.fmt.allocPrint(arena,
        \\#!/bin/sh
        \\if [ "$1" = "--version" ]; then echo '{s}'; exit {d}; fi
        \\printf '%s' '{s}' >&2
        \\exit {d}
        \\
    , .{ stand_in.version, stand_in.version_status, stand_in.summary, stand_in.status });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = script, .flags = .{ .permissions = .executable_file } });
    return std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

test "open reads valgrind's release, and count gives a run's total or why it has none" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const counting = try write_stand_in(&tmp, arena, "counting", .{ .summary = "==42== Command: bench hit 1000\n==42== I refs:        1,234,567\n" });
    const counter = try Cachegrind.open(arena, testing.io, counting);
    try testing.expectEqualStrings("cachegrind 3.99.0", counter.label);
    try testing.expectEqual(1_234_567, (try counter.count("bench", &.{"hit"}, 1000)).total);
    const failing = try write_stand_in(&tmp, arena, "failing", .{ .summary = "bench: no case named hit\n", .status = 3 });
    const failed = (try (try Cachegrind.open(arena, testing.io, failing)).count("bench", &.{"hit"}, 1000)).failed;
    try testing.expectEqualStrings("the program exited with status 3", failed.reason);
    try testing.expectEqualStrings("bench: no case named hit\n", failed.output);
    const silent = try write_stand_in(&tmp, arena, "silent", .{ .summary = "==42== Command: bench hit 1000\n" });
    const empty = (try (try Cachegrind.open(arena, testing.io, silent)).count("bench", &.{"hit"}, 1000)).failed;
    try testing.expectEqualStrings("valgrind printed no instruction total", empty.reason);
    // It names a release, and fails: the status alone refuses it.
    const broken = try write_stand_in(&tmp, arena, "broken", .{ .version_status = 1 });
    try testing.expectError(error.UnknownVersion, Cachegrind.open(arena, testing.io, broken));
}

test "end_reason passes status 0 alone, and names how any other run ended" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(null, try end_reason(arena, .{ .exited = 0 }));
    try testing.expectEqualStrings("the program exited with status 127", (try end_reason(arena, .{ .exited = 127 })).?);
    try testing.expectEqualStrings("the program ended in a way the system reports as 11", (try end_reason(arena, .{ .unknown = 11 })).?);
}
