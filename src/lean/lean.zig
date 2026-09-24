//! A project's Lean 4 proofs, built with lake. A project states where its Lean project is; the
//! engine checks the project pins its toolchain and runs lake there.
//!
//! ```zig
//! // tools/lean.zig
//! const pepegrillo = @import("pepegrillo");
//! pub fn main(init: std.process.Init) !void {
//!     return pepegrillo.lean.main(init, .{});
//! }
//! ```
//!
//! Run:  lean
//!
//! Runs `lake build` in the Lean directory, with lake's own output on the terminal, because a
//! build can run for minutes. The directory must hold `lean-toolchain`, which elan reads to pick
//! the Lean release, so the release is pinned by the project and never by whatever is installed.
//! lake is found on PATH, or where elan installs it, `$HOME/.elan/bin/lake`.
//!
//! Exit status: 0 when the build succeeded; 1 when it failed; 2 when there is no pinned Lean
//! project or no lake.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const report_line = @import("../report_line.zig");

pub const Config = struct {
    /// The Lean project, from the working directory.
    directory: []const u8 = "spec/lean",
    /// What lake is asked to do.
    lake_arguments: []const []const u8 = &.{"build"},
};

/// The rule name every line carries.
const rule = "lean";
/// The file elan reads for the Lean release a project pins.
pub const toolchain_file = "lean-toolchain";
const lake_program = "lake";
/// Where elan installs lake, under `$HOME`.
const elan_lake = ".elan/bin/lake";
const home_variable = "HOME";
const exit_success: u8 = 0;
const exit_failed: u8 = 1;
const exit_unusable: u8 = 2;
const output_buffer_bytes: usize = 4096;

pub fn main(init: std.process.Init, comptime project: Config) !void {
    const arena = init.arena.allocator();
    var error_buffer: [output_buffer_bytes]u8 = undefined;
    var errors = Io.File.stderr().writerStreaming(init.io, &error_buffer);
    const status = try run(arena, init.io, init.environ_map, project, &errors.interface);
    try errors.interface.flush();
    std.process.exit(status);
}

/// Builds the Lean project, and returns the exit status.
pub fn run(arena: Allocator, io: Io, environ: *const std.process.Environ.Map, comptime project: Config, errors: *Io.Writer) !u8 {
    const toolchain = try std.fs.path.join(arena, &.{ project.directory, toolchain_file });
    Io.Dir.cwd().access(io, toolchain, .{}) catch {
        try report_line.write(errors, .{ .source = toolchain }, .@"error", rule, "missing: a Lean project pins its release there", .{});
        return exit_unusable;
    };
    for (try lake_candidates(arena, environ)) |lake| {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, lake);
        try argv.appendSlice(arena, project.lake_arguments);
        var child = std.process.spawn(io, .{ .argv = argv.items, .cwd = .{ .path = project.directory } }) catch |failure| switch (failure) {
            error.FileNotFound => continue,
            else => return failure,
        };
        const term = try child.wait(io);
        return status_of(term);
    }
    try report_line.write(errors, .{ .source = project.directory }, .@"error", rule, "no lake on PATH or at $HOME/{s}; install elan", .{elan_lake});
    return exit_unusable;
}

/// Where lake may be, in the order tried: on PATH, then where elan installs it.
pub fn lake_candidates(arena: Allocator, environ: *const std.process.Environ.Map) ![]const []const u8 {
    var candidates: std.ArrayList([]const u8) = .empty;
    try candidates.append(arena, lake_program);
    if (environ.get(home_variable)) |home| try candidates.append(arena, try std.fs.path.join(arena, &.{ home, elan_lake }));
    return candidates.items;
}

/// The exit status a lake run maps to: success, or a failed build.
pub fn status_of(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| if (code == 0) exit_success else exit_failed,
        else => exit_failed,
    };
}

// Tests.

const testing = std.testing;

test "lake_candidates tries PATH first, then elan's directory under $HOME" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var environ: std.process.Environ.Map = .init(arena);
    const bare = try lake_candidates(arena, &environ);
    try testing.expectEqual(1, bare.len);
    try testing.expectEqualStrings("lake", bare[0]);
    try environ.put("HOME", "/home/person");
    const both = try lake_candidates(arena, &environ);
    try testing.expectEqual(2, both.len);
    try testing.expectEqualStrings("/home/person/.elan/bin/lake", both[1]);
}

test "status_of passes lake's success and fails everything else" {
    try testing.expectEqual(0, status_of(.{ .exited = 0 }));
    try testing.expectEqual(1, status_of(.{ .exited = 1 }));
    try testing.expectEqual(1, status_of(.{ .exited = 3 }));
    try testing.expectEqual(1, status_of(.{ .unknown = 9 }));
}

test "run refuses a directory that pins no Lean release" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var environ: std.process.Environ.Map = .init(arena_state.allocator());
    var buffer: [512]u8 = undefined;
    var errors: Io.Writer = .fixed(&buffer);
    const status = try run(arena_state.allocator(), testing.io, &environ, .{ .directory = ".zig-cache/tmp/no-lean-here" }, &errors);
    try testing.expectEqual(2, status);
    try testing.expect(std.mem.indexOf(u8, errors.buffered(), "lean-toolchain: error: [lean] missing") != null);
}
