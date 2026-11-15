//! kcov, the counter: it reads a program's DWARF line table, stops the program once at each line,
//! and writes which lines ran. It needs no rebuild of the program, and it runs on Linux.
//!
//! The engine runs each program into a directory of its own, then merges the directories with
//! `kcov --merge`. A merge counts a line once when two programs run it, and it writes
//! `kcov-merged/coverage.json` for one program as for several.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const end_reason = @import("../instructions/instructions_cachegrind.zig").end_reason;

/// The option that asks kcov for its release.
const version_option = "--version";
/// What `kcov --version` prints before the release, as in `kcov 43+dfsg-2`.
const version_prefix = "kcov ";
/// The option that limits the count to the files under the paths it names, separated by commas.
const include_option = "--include-path=";
/// The option that merges the directories of several runs.
const merge_option = "--merge";
/// The separator kcov reads between two include paths.
pub const path_separator = ',';
/// Bytes of a run's standard output and standard error kept. A test binary prints a line a test.
const output_len_max: usize = 16 * 1024 * 1024;
/// Bytes of `kcov --version`'s output kept.
const version_len_max: usize = 4096;

/// How one kcov run ended: null when it exited with status 0, or why it did not, with what it
/// wrote to standard error.
pub const Failure = struct {
    reason: []const u8,
    output: []const u8,
};

pub const Kcov = struct {
    arena: Allocator,
    io: Io,
    program: []const u8,

    /// The major release that `kcov --version` prints. Fails with `error.FileNotFound` when there
    /// is no kcov, and with `error.UnknownVersion` when its output names no release.
    pub fn release(self: *const Kcov) !u32 {
        const result = try std.process.run(self.arena, self.io, .{
            .argv = &.{ self.program, version_option },
            .stdout_limit = .limited(version_len_max),
            .stderr_limit = .limited(version_len_max),
        });
        if (try end_reason(self.arena, result.term) != null) return error.UnknownVersion;
        return release_of(result.stdout) orelse error.UnknownVersion;
    }

    /// Runs `program` under kcov, which writes the lines it ran under `roots` to `directory`.
    pub fn count(self: *const Kcov, roots: []const []const u8, directory: []const u8, program: []const u8) !?Failure {
        return self.ended(try run_argv(self.arena, self.program, roots, directory, program));
    }

    /// Merges the run directories into `directory`.
    pub fn merge(self: *const Kcov, directory: []const u8, runs: []const []const u8) !?Failure {
        return self.ended(try merge_argv(self.arena, self.program, directory, runs));
    }

    fn ended(self: *const Kcov, command: []const []const u8) !?Failure {
        const result = try std.process.run(self.arena, self.io, .{
            .argv = command,
            .stdout_limit = .limited(output_len_max),
            .stderr_limit = .limited(output_len_max),
        });
        const reason = try end_reason(self.arena, result.term) orelse return null;
        return .{ .reason = reason, .output = result.stderr };
    }
};

/// The major release in `kcov --version`'s output: 43 from upstream's `kcov v43` and from
/// Debian's `kcov 43+dfsg-2`; null for any other output.
pub fn release_of(version_output: []const u8) ?u32 {
    const line = std.mem.trim(u8, std.mem.sliceTo(version_output, '\n'), " \t\r");
    if (!std.mem.startsWith(u8, line, version_prefix)) return null;
    var rest = line[version_prefix.len..];
    if (rest.len > 0 and rest[0] == 'v') rest = rest[1..];
    var digits: usize = 0;
    while (digits < rest.len and std.ascii.isDigit(rest[digits])) digits += 1;
    if (digits == 0) return null;
    return std.fmt.parseInt(u32, rest[0..digits], 10) catch null;
}

/// The command that counts one program: kcov, the paths it counts, its directory and the program.
pub fn run_argv(
    arena: Allocator,
    kcov_program: []const u8,
    roots: []const []const u8,
    directory: []const u8,
    program: []const u8,
) ![]const []const u8 {
    var include: std.ArrayList(u8) = .empty;
    try include.appendSlice(arena, include_option);
    for (roots, 0..) |root, index| {
        if (index > 0) try include.append(arena, path_separator);
        try include.appendSlice(arena, root);
    }
    return arena.dupe([]const u8, &.{ kcov_program, include.items, directory, program });
}

/// The command that merges the run directories into one.
pub fn merge_argv(arena: Allocator, kcov_program: []const u8, directory: []const u8, runs: []const []const u8) ![]const []const u8 {
    var command: std.ArrayList([]const u8) = .empty;
    try command.appendSlice(arena, &.{ kcov_program, merge_option, directory });
    try command.appendSlice(arena, runs);
    return command.items;
}

// Tests.

const testing = std.testing;

test "release_of reads the major release of upstream's and Debian's kcov" {
    try testing.expectEqual(43, release_of("kcov v43\n"));
    try testing.expectEqual(43, release_of("kcov 43+dfsg-2\n"));
    try testing.expectEqual(42, release_of("kcov 42\r\n"));
    try testing.expectEqual(null, release_of("kcov\n"));
    try testing.expectEqual(null, release_of("kcov vx\n"));
    try testing.expectEqual(null, release_of("valgrind-3.22.0\n"));
    try testing.expectEqual(null, release_of("kcov 99999999999\n"));
}

test "run_argv joins the roots with commas before the directory and the program" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const command = try run_argv(arena_state.allocator(), "kcov", &.{ "/w/src/store", "/w/src/wire" }, "out/run-1", "zig-out/bin/test");
    const expected = [_][]const u8{ "kcov", "--include-path=/w/src/store,/w/src/wire", "out/run-1", "zig-out/bin/test" };
    try testing.expectEqual(expected.len, command.len);
    for (expected, command) |want, got| try testing.expectEqualStrings(want, got);
}

test "merge_argv names the merged directory, then every run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const command = try merge_argv(arena_state.allocator(), "kcov", "out/merged", &.{ "out/run-1", "out/run-2" });
    const expected = [_][]const u8{ "kcov", "--merge", "out/merged", "out/run-1", "out/run-2" };
    try testing.expectEqual(expected.len, command.len);
    for (expected, command) |want, got| try testing.expectEqualStrings(want, got);
}
