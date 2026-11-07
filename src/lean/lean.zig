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
//! The tool reads no argument.
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
const Context = @import("../context.zig").Context;

pub const Config = struct {
    /// The Lean project, from the working directory.
    directory: []const u8 = "spec/lean",
    /// What lake is asked to do.
    lake_arguments: []const []const u8 = &.{"build"},
};

/// The rule name every line carries.
const rule = "lean";
/// The file elan reads for the Lean release a project pins.
const toolchain_file = "lean-toolchain";
const lake_program = "lake";
/// Where elan installs lake, under `$HOME`.
const elan_lake = ".elan/bin/lake";
const home_variable = "HOME";
const exit_success: u8 = 0;
const exit_failed: u8 = 1;
const exit_unusable: u8 = 2;
const output_buffer_len: usize = 4096;

/// Why a configuration cannot run, which the compile error names.
pub fn check_config(comptime project: Config) ?[]const u8 {
    if (project.directory.len == 0) return "directory names no Lean project";
    if (project.lake_arguments.len == 0) return "lake_arguments asks lake to do nothing";
    return null;
}

pub fn main(init: std.process.Init, comptime project: Config) !void {
    comptime if (check_config(project)) |reason| @compileError(reason);
    const arena = init.arena.allocator();
    const all_arguments = try init.minimal.args.toSlice(arena);
    const given = if (all_arguments.len == 0) all_arguments else all_arguments[1..];
    var output_buffer: [output_buffer_len]u8 = undefined;
    var error_buffer: [output_buffer_len]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(init.io, &output_buffer);
    var errors = Io.File.stderr().writerStreaming(init.io, &error_buffer);
    const context: Context = .{ .arena = arena, .io = init.io, .environ = init.environ_map, .out = &out.interface, .errors = &errors.interface };
    const status = try run(&context, project, given);
    try errors.interface.flush();
    try out.interface.flush();
    std.process.exit(status);
}

/// Builds the Lean project, and returns the exit status. The tool reads no argument, so `given`
/// is left unread; lake's own output goes to the terminal.
pub fn run(context: *const Context, comptime project: Config, given: []const []const u8) !u8 {
    _ = given;
    const arena = context.arena;
    const io = context.io;
    const errors = context.errors;
    const toolchain = try std.fs.path.join(arena, &.{ project.directory, toolchain_file });
    Io.Dir.cwd().access(io, toolchain, .{}) catch {
        try report_line.write(errors, &.{ .source = toolchain }, .@"error", rule, "missing: a Lean project pins its release there", .{});
        return exit_unusable;
    };
    for (try lake_candidates(arena, context.environ)) |lake| {
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
    try report_line.write(errors, &.{ .source = project.directory }, .@"error", rule, "no lake on PATH or at $HOME/{s}; install elan", .{elan_lake});
    return exit_unusable;
}

/// Where lake may be, in the order tried: on PATH, then where elan installs it.
fn lake_candidates(arena: Allocator, environ: *const std.process.Environ.Map) ![]const []const u8 {
    var candidates: std.ArrayList([]const u8) = .empty;
    try candidates.append(arena, lake_program);
    if (environ.get(home_variable)) |home| try candidates.append(arena, try std.fs.path.join(arena, &.{ home, elan_lake }));
    return candidates.items;
}

/// The exit status a lake run maps to: success, or a failed build.
fn status_of(term: std.process.Child.Term) u8 {
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
    const arena = arena_state.allocator();
    var environ: std.process.Environ.Map = .init(arena);
    var buffer: [512]u8 = undefined;
    var errors: Io.Writer = .fixed(&buffer);
    var out: Io.Writer = .fixed(&.{});
    const context: Context = .{ .arena = arena, .io = testing.io, .environ = &environ, .out = &out, .errors = &errors };
    const status = try run(&context, .{ .directory = ".zig-cache/tmp/no-lean-here" }, &.{});
    try testing.expectEqual(2, status);
    try testing.expect(std.mem.indexOf(u8, errors.buffered(), "lean-toolchain: error: [lean] missing") != null);
}

test "check_config refuses an empty directory and an empty lake command" {
    try testing.expectEqual(null, check_config(.{}));
    try testing.expect(check_config(.{ .directory = "" }) != null);
    try testing.expect(check_config(.{ .lake_arguments = &.{} }) != null);
}

test "the root exports these names alone" {
    try @import("../public_names.zig").expect(@This(), &.{ "Config", "check_config", "main", "run" });
}
