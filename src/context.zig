//! What the `run` of each tool receives: `tla`, `lean`, `instructions`, `checkfree` and `commit`.
//! Each tool's `main` builds one from `std.process.Init`, and a project's own entry point can
//! build one to run a tool with other writers, as a test does.
//!
//! Each tool has one entry shape:
//!
//! ```zig
//! pub fn check_config(comptime project: Config) ?[]const u8
//! pub fn run(context: *const Context, comptime project: Config, given: []const []const u8) !u8
//! pub fn main(init: std.process.Init, comptime project: Config) !void
//! ```
//!
//! `check_config` names why a configuration cannot run, or returns null; `main` makes it a compile
//! error. `run` reads the arguments in `given`, without the program name, writes its report, and
//! returns the exit status.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Context = struct {
    /// Scratch memory that lives until the tool exits.
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    /// Where the report goes: standard output in `main`.
    out: *Io.Writer,
    /// Where a usage error and the end of a failed run go: standard error in `main`.
    errors: *Io.Writer,
};
