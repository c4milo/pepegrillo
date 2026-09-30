//! The baseline: what each case's operations cost when the file was last written, and what
//! counted them. A project commits it, and it changes only in a commit that says why.
//!
//! ```zig
//! // What each case's operations cost, written by pepegrillo's instructions tool.
//! .{
//!     .counter = "cachegrind 3.22.0",
//!     .zig = "0.16.0",
//!     .target = "aarch64-linux",
//!     .cases = .{
//!         .{ .name = "cache_hit", .rounds = 1000, .instructions = 153000 },
//!     },
//! }
//! ```
//!
//! `instructions` is what the case's long run counted past its short one: the cost of `rounds`
//! operations. The counter, the Zig release and the target each change a count, so a baseline
//! taken under others is not compared; it is written anew.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const report_line = @import("../report_line.zig");
const measure = @import("instructions_measure.zig");

/// The most rounds a case may take, so that products of counts, rounds and thousandths fit in 128
/// bits (`instructions_measure.zig`).
pub const rounds_max: u64 = 1 << 32;
/// Bytes of a baseline read.
const baseline_len_max: usize = 1024 * 1024;
/// The suffix a baseline is written to before it is renamed into place, so a write cut short
/// never leaves half a baseline.
const partial_suffix = ".part";
/// The comment a written baseline starts with.
const header_comment =
    \\// What each case's operations cost, written by pepegrillo's instructions tool. Write it anew
    \\// with --rewrite, in a commit that says why the counts moved.
    \\
;

/// What a count depends on besides the code: the counter, the Zig release and the target.
pub const Environment = struct {
    counter: []const u8,
    zig: []const u8,
    target: []const u8,

    pub fn eql(self: Environment, other: Environment) bool {
        return std.mem.eql(u8, self.counter, other.counter) and
            std.mem.eql(u8, self.zig, other.zig) and
            std.mem.eql(u8, self.target, other.target);
    }
};

/// One case's line in the baseline.
pub const Entry = struct {
    name: []const u8,
    rounds: u64,
    instructions: u64,

    pub fn measurement(self: Entry) measure.Measurement {
        return .{ .rounds = self.rounds, .instructions = self.instructions };
    }
};

/// The file's contents, as ZON.
pub const File = struct {
    counter: []const u8,
    zig: []const u8,
    target: []const u8,
    cases: []const Entry,

    pub fn environment(self: File) Environment {
        return .{ .counter = self.counter, .zig = self.zig, .target = self.target };
    }

    pub fn entry(self: File, name: []const u8) ?Entry {
        for (self.cases) |candidate| {
            if (std.mem.eql(u8, candidate.name, name)) return candidate;
        }
        return null;
    }
};

/// Why a baseline cannot be used, and where in it.
pub const Problem = struct {
    message: []const u8,
    position: ?report_line.Position = null,
};

pub const Read = union(enum) {
    /// The file, and its text, which gives each case's position.
    baseline: struct { file: File, source: []const u8 },
    missing,
    malformed: Problem,
};

/// Reads and checks the baseline at `path`.
pub fn read(arena: Allocator, io: Io, path: []const u8) !Read {
    const source = Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(baseline_len_max), .of(u8), 0) catch |failure| switch (failure) {
        error.FileNotFound => return .missing,
        else => return failure,
    };
    var diagnostics: std.zon.parse.Diagnostics = .{};
    const file = std.zon.parse.fromSliceAlloc(File, arena, source, &diagnostics, .{}) catch |failure| switch (failure) {
        error.ParseZon => return .{ .malformed = try first_parse_error(arena, &diagnostics) },
        error.OutOfMemory => return failure,
    };
    if (try check(arena, file, source)) |problem| return .{ .malformed = problem };
    return .{ .baseline = .{ .file = file, .source = source } };
}

fn first_parse_error(arena: Allocator, diagnostics: *const std.zon.parse.Diagnostics) !Problem {
    var errors = diagnostics.iterateErrors();
    const first = errors.next() orelse return .{ .message = "is not valid ZON" };
    const location = first.getLocation(diagnostics);
    return .{
        .message = try std.fmt.allocPrint(arena, "{f}", .{first.fmtMessage(diagnostics)}),
        .position = .{ .line = location.line + 1, .column = location.column + 1 },
    };
}

/// The first entry a baseline cannot hold, or null when every entry is sound.
fn check(arena: Allocator, file: File, source: []const u8) !?Problem {
    for (file.cases, 0..) |candidate, index| {
        const reason: ?[]const u8 = if (candidate.rounds == 0 or candidate.rounds > rounds_max)
            try std.fmt.allocPrint(arena, "takes {d} rounds, outside 1 to {d}", .{ candidate.rounds, rounds_max })
        else if (candidate.instructions == 0)
            "counts no instructions, which no comparison can grow from"
        else if (named_before(file.cases[0..index], candidate.name))
            "is counted twice"
        else
            null;
        if (reason) |why| return .{
            .message = try std.fmt.allocPrint(arena, "case {s} {s}", .{ candidate.name, why }),
            .position = position_of(source, candidate.name),
        };
    }
    return null;
}

fn named_before(earlier: []const Entry, name: []const u8) bool {
    for (earlier) |candidate| {
        if (std.mem.eql(u8, candidate.name, name)) return true;
    }
    return false;
}

/// Where a case's entry is: its `.name` field, found in the text the baseline was read from.
/// Null when the entry is written in some other way than the tool writes it.
pub fn position_of(source: []const u8, name: []const u8) ?report_line.Position {
    var needle_buffer: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buffer, ".name = \"{s}\"", .{name}) catch return null;
    const offset = std.mem.indexOf(u8, source, needle) orelse return null;
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |newline| newline + 1 else 0;
    return .{
        .line = std.mem.count(u8, source[0..offset], "\n") + 1,
        .column = offset - line_start + 1,
    };
}

/// The text of a baseline holding `entries`, counted under `environment`.
pub fn render(arena: Allocator, environment: Environment, entries: []const Entry) ![]const u8 {
    var text: Io.Writer.Allocating = .init(arena);
    const out = &text.writer;
    try out.writeAll(header_comment);
    try out.print(".{{\n    .counter = \"{f}\",\n", .{std.zig.fmtString(environment.counter)});
    try out.print("    .zig = \"{f}\",\n", .{std.zig.fmtString(environment.zig)});
    try out.print("    .target = \"{f}\",\n    .cases = .{{\n", .{std.zig.fmtString(environment.target)});
    for (entries) |written| {
        try out.print("        .{{ .name = \"{f}\", .rounds = {d}, .instructions = {d} }},\n", .{
            std.zig.fmtString(written.name), written.rounds, written.instructions,
        });
    }
    try out.writeAll("    },\n}\n");
    return text.written();
}

/// Writes `text` to `path` through a partial file renamed into place.
pub fn write(arena: Allocator, io: Io, path: []const u8, text: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    const partial = try std.mem.concat(arena, u8, &.{ path, partial_suffix });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = partial, .data = text });
    try Io.Dir.cwd().rename(partial, Io.Dir.cwd(), path, io);
}

// Tests.

const testing = std.testing;

const environment_fixture: Environment = .{ .counter = "cachegrind 3.22.0", .zig = "0.16.0", .target = "aarch64-linux" };

/// Writes `text` as a baseline in a directory of its own and reads it back.
fn read_text(arena: Allocator, tmp: *testing.TmpDir, text: []const u8) !Read {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "instructions.zon", .data = text });
    const path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/instructions.zon", .{tmp.sub_path});
    return read(arena, testing.io, path);
}

test "render writes a baseline that read gives back, with each case's position" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const entries = [_]Entry{
        .{ .name = "cache_hit", .rounds = 1000, .instructions = 153_000 },
        .{ .name = "query-build", .rounds = 250, .instructions = 1_234_567 },
    };
    const text = try render(arena, environment_fixture, &entries);
    const result = try read_text(arena, &tmp, text);
    const file = result.baseline.file;
    try testing.expect(file.environment().eql(environment_fixture));
    try testing.expectEqual(2, file.cases.len);
    try testing.expectEqualDeep(entries[1], file.entry("query-build").?);
    try testing.expectEqual(null, file.entry("cache-miss"));
    try testing.expectEqual(report_line.Position{ .line = 8, .column = 12 }, position_of(result.baseline.source, "cache_hit").?);
    try testing.expectEqual(null, position_of(result.baseline.source, "cache"));
}

test "read tells a missing baseline from a malformed one, and points at the fault" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const missing_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/none.zon", .{tmp.sub_path});
    try testing.expect(try read(arena, testing.io, missing_path) == .missing);
    const malformed = try read_text(arena, &tmp, ".{\n    .counter = 3,\n}\n");
    try testing.expectEqual(2, malformed.malformed.position.?.line);
}

test "read refuses zero rounds, rounds past the limit, no instructions and a case counted twice" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const faults = [_]struct { entries: []const Entry, reason: []const u8 }{
        .{ .entries = &.{.{ .name = "a", .rounds = 0, .instructions = 5 }}, .reason = "case a takes 0 rounds" },
        .{ .entries = &.{.{ .name = "a", .rounds = rounds_max + 1, .instructions = 5 }}, .reason = "case a takes 4294967297 rounds" },
        .{ .entries = &.{.{ .name = "a", .rounds = 10, .instructions = 0 }}, .reason = "case a counts no instructions" },
        .{ .entries = &.{
            .{ .name = "a", .rounds = 10, .instructions = 5 },
            .{ .name = "a", .rounds = 10, .instructions = 6 },
        }, .reason = "case a is counted twice" },
    };
    for (faults) |fault| {
        const result = try read_text(arena, &tmp, try render(arena, environment_fixture, fault.entries));
        try testing.expect(std.mem.startsWith(u8, result.malformed.message, fault.reason));
        try testing.expectEqual(8, result.malformed.position.?.line);
    }
    const at_limit = [_]Entry{.{ .name = "a", .rounds = rounds_max, .instructions = 5 }};
    try testing.expect(try read_text(arena, &tmp, try render(arena, environment_fixture, &at_limit)) == .baseline);
}

test "Environment.eql compares the counter, the Zig release and the target" {
    try testing.expect(environment_fixture.eql(environment_fixture));
    var other = environment_fixture;
    other.counter = "cachegrind 3.23.0";
    try testing.expect(!environment_fixture.eql(other));
    other = environment_fixture;
    other.zig = "0.17.0";
    try testing.expect(!environment_fixture.eql(other));
    other = environment_fixture;
    other.target = "x86_64-linux";
    try testing.expect(!environment_fixture.eql(other));
}

test "write replaces a baseline through a partial file and leaves none behind" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/bench/instructions.zon", .{tmp.sub_path});
    try write(arena, testing.io, path, "first\n");
    try write(arena, testing.io, path, "second\n");
    const written = try Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(64));
    try testing.expectEqualStrings("second\n", written);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "bench/instructions.zon.part", .{}));
}
