//! TLA+ models, checked by the TLC model checker. A project states where its models are and which
//! TLC release it pins; the engine finds every configuration, runs TLC on each, and checks the
//! verdict against the one the configuration expects.
//!
//! ```zig
//! // tools/tla.zig
//! const pepegrillo = @import("pepegrillo");
//! pub fn main(init: std.process.Init) !void {
//!     return pepegrillo.tla.main(init, .{ .tlc_release = "v1.8.0", .tlc_sha256 = "..." });
//! }
//! ```
//!
//! Run:  tla [configuration...]
//!
//! With no argument every configuration under the models directory runs (`tla_models.zig`). An
//! argument names one configuration by its path from the working directory. Each configuration's
//! header says what TLC must conclude (`tla_header.zig`), and `tla_tlc.zig` finds the jar and
//! checks it against the pin.
//!
//! One line per configuration, in the shape `report_line.zig` defines: `note` when TLC concluded
//! what the configuration expects, with the count of distinct states, and `error` when it did not,
//! followed by the end of TLC's output on standard error.
//!
//! Exit status: 0 when every configuration concluded what it expects; 1 when any did not; 2 when
//! TLC could not run at all: a jar that fails its pin or cannot be fetched, or no configuration.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const report_line = @import("../report_line.zig");

pub const header = @import("tla_header.zig");
pub const models = @import("tla_models.zig");
pub const tlc = @import("tla_tlc.zig");

pub const Config = struct {
    /// Where the models live, from the working directory.
    models_directory: []const u8 = "spec/tla",
    /// The tlaplus release tag the project pins, such as `v1.8.0`.
    tlc_release: []const u8,
    /// The SHA-256 of that release's tla2tools.jar, in lowercase hex.
    tlc_sha256: []const u8,
    java_program: []const u8 = "java",
    java_options: []const []const u8 = &.{"-XX:+UseParallelGC"},
    /// TLC's `-workers`: a count, or `auto` for one per core.
    workers: []const u8 = "auto",
};

/// The rule name every line carries.
const rule = "tla";
/// Bytes of a configuration file read for its header.
const configuration_len_max: usize = 1024 * 1024;
/// Bytes of TLC's output kept per run. A model that prints more is cut short in the report only.
const output_len_max: usize = 64 * 1024 * 1024;
/// Lines of TLC's output printed after a configuration that did not conclude what it expects.
const failure_tail_lines: usize = 40;
const exit_success: u8 = 0;
const exit_mismatch: u8 = 1;
const exit_unusable: u8 = 2;
const output_buffer_bytes: usize = 4096;

/// Why a configuration cannot be run, which the report names.
fn check_config(comptime project: Config) ?[]const u8 {
    if (project.tlc_release.len == 0) return "tlc_release names no release";
    if (project.tlc_sha256.len != tlc.sha256_hex_len) return "tlc_sha256 is not 64 hex digits";
    for (project.tlc_sha256) |digit| {
        if (!std.ascii.isDigit(digit) and (digit < 'a' or digit > 'f')) return "tlc_sha256 is not lowercase hex";
    }
    return null;
}

pub fn main(init: std.process.Init, comptime project: Config) !void {
    comptime if (check_config(project)) |reason| @compileError(reason);
    const arena = init.arena.allocator();
    const all_arguments = try init.minimal.args.toSlice(arena);
    const given = if (all_arguments.len == 0) all_arguments else all_arguments[1..];
    var output_buffer: [output_buffer_bytes]u8 = undefined;
    var error_buffer: [output_buffer_bytes]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(init.io, &output_buffer);
    var errors = Io.File.stderr().writerStreaming(init.io, &error_buffer);
    const context: Context = .{ .arena = arena, .io = init.io, .environ = init.environ_map, .out = &out.interface, .errors = &errors.interface };
    const status = try run(context, project, given);
    try errors.interface.flush();
    try out.interface.flush();
    std.process.exit(status);
}

pub const Context = struct {
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    out: *Io.Writer,
    errors: *Io.Writer,
};

/// Checks the jar, then every configuration `given` names, or every one under the models
/// directory when it names none. Returns the exit status.
pub fn run(context: Context, comptime project: Config, given: []const []const u8) !u8 {
    const jar = verified_jar(context, project) catch |failure| {
        try report_line.write(context.errors, .{ .source = project.models_directory }, .@"error", rule, "TLC cannot run: {t}", .{failure});
        return exit_unusable;
    };
    const configurations = if (given.len == 0)
        try models.discover(context.arena, context.io, project.models_directory)
    else
        try named(context.arena, given);
    if (configurations.len == 0) {
        try report_line.write(context.errors, .{ .source = project.models_directory }, .@"error", rule, "no TLC configuration found", .{});
        return exit_unusable;
    }
    var status = exit_success;
    for (configurations) |configuration| {
        if (!try check(context, project, jar, configuration)) status = exit_mismatch;
    }
    return status;
}

/// The jar, fetched into the cache when neither the variable nor the cache has it, and refused
/// unless its SHA-256 is the pinned one. Public for a project's tool that runs TLC some other way,
/// such as for random walks, and holds TLC to the same pin.
pub fn verified_jar(context: Context, comptime project: Config) ![]const u8 {
    const path = try tlc.jar_path(context.arena, context.environ, project.tlc_release);
    const named_by_variable = context.environ.get(tlc.jar_variable) != null;
    Io.Dir.cwd().access(context.io, path, .{}) catch |failure| switch (failure) {
        error.FileNotFound => if (named_by_variable) return failure else try tlc.fetch(context.arena, context.io, project.tlc_release, path),
        else => return failure,
    };
    const digest = try tlc.file_sha256(context.arena, context.io, path);
    if (!std.mem.eql(u8, &digest, project.tlc_sha256)) return error.JarDoesNotMatchPin;
    return path;
}

/// The configurations the command line named, each by its path from the working directory.
fn named(arena: Allocator, given: []const []const u8) ![]models.Configuration {
    var found: std.ArrayList(models.Configuration) = .empty;
    for (given) |path| try found.append(arena, try models.from_path(arena, path));
    return found.items;
}

/// Runs one configuration and reports it. True when TLC concluded what it expects.
fn check(context: Context, comptime project: Config, jar: []const u8, configuration: models.Configuration) !bool {
    const path = try std.fs.path.join(context.arena, &.{ configuration.model_directory, configuration.relative_path });
    const location: report_line.Location = .{ .source = path };
    const plan = planned(context, configuration, path) catch |failure| {
        try report_line.write(context.out, location, .@"error", rule, "{s}", .{plan_failure(failure)});
        return false;
    };
    const states = try tlc.states_path(context.arena, context.environ, try state_label(context.arena, path));
    Io.Dir.cwd().deleteTree(context.io, states) catch {};
    const result = try std.process.run(context.arena, context.io, .{
        .argv = try tlc.argv(context.arena, .{
            .java_program = project.java_program,
            .java_options = project.java_options,
            .workers = project.workers,
            .jar = jar,
            .states = states,
            .configuration = configuration.relative_path,
            .module = plan.module,
        }),
        .cwd = .{ .path = configuration.model_directory },
        .stdout_limit = .limited(output_len_max),
        .stderr_limit = .limited(output_len_max),
    });
    const verdict = tlc.verdict_of(result.term);
    const states_count = tlc.states_found(result.stdout);
    if (matches(verdict, plan.expect)) {
        try report_line.write(context.out, location, .note, rule, "{t}, as expected, {?d} distinct states", .{ plan.expect, states_count });
        return true;
    }
    try report_line.write(context.out, location, .@"error", rule, "expected {t}, found {s}", .{ plan.expect, describe(verdict) });
    try write_tail(context.errors, result.stdout);
    try write_tail(context.errors, result.stderr);
    return false;
}

/// What one configuration expects, and the module it checks.
const Plan = struct {
    expect: header.Expectation,
    module: []const u8,
};

fn planned(context: Context, configuration: models.Configuration, path: []const u8) !Plan {
    const text = try Io.Dir.cwd().readFileAlloc(context.io, path, context.arena, .limited(configuration_len_max));
    const read = try header.read(text);
    const expect = read.expect orelse if (configuration.is_mutant) header.Expectation.violated else return error.NoExpectation;
    const module = read.module orelse (try models.module_for(context.arena, context.io, configuration)) orelse return error.NoModule;
    return .{ .expect = expect, .module = module };
}

fn plan_failure(failure: anyerror) []const u8 {
    return switch (failure) {
        error.NoExpectation => "states no expectation: its first lines need \\* expect: holds, or \\* expect: violated",
        error.NoModule => "names no module: no .tla file prefixes its name, so it needs \\* module: <name>",
        error.UnknownExpectation => "expects neither holds nor violated",
        error.EmptyModule => "names an empty module",
        else => @errorName(failure),
    };
}

pub fn matches(verdict: tlc.Verdict, expect: header.Expectation) bool {
    return switch (verdict) {
        .holds => expect == .holds,
        .violated => expect == .violated,
        .failed => false,
    };
}

fn describe(verdict: tlc.Verdict) []const u8 {
    return switch (verdict) {
        .holds => "holds",
        .violated => "violated",
        .failed => "a TLC failure",
    };
}

/// A name for a configuration's states directory: its path, with separators made underscores.
fn state_label(arena: Allocator, path: []const u8) ![]const u8 {
    const label = try arena.dupe(u8, path);
    for (label) |*character| {
        if (character.* == '/' or character.* == '\\') character.* = '_';
    }
    return label;
}

/// The last `failure_tail_lines` lines of `output`.
fn write_tail(errors: *Io.Writer, output: []const u8) !void {
    var start = output.len;
    var lines: usize = 0;
    while (start > 0 and lines <= failure_tail_lines) : (start -= 1) {
        if (output[start - 1] == '\n') lines += 1;
    }
    try errors.writeAll(output[start..]);
}

// Tests.

const testing = std.testing;

test "matches holds a verdict to what the configuration expects" {
    try testing.expect(matches(.holds, .holds));
    try testing.expect(matches(.violated, .violated));
    try testing.expect(!matches(.holds, .violated));
    try testing.expect(!matches(.violated, .holds));
    // TLC failing to check a model is never what a configuration expects.
    try testing.expect(!matches(.{ .failed = 150 }, .holds));
    try testing.expect(!matches(.{ .failed = 150 }, .violated));
}

test "check_config refuses a pin that is not a lowercase SHA-256" {
    const good = "9d36716ffb5e49d1ba8fae4651eba59f3189887e12eb90e204a42d2e6e993fef";
    try testing.expectEqual(null, check_config(.{ .tlc_release = "v1.8.0", .tlc_sha256 = good }));
    try testing.expect(check_config(.{ .tlc_release = "", .tlc_sha256 = good }) != null);
    try testing.expect(check_config(.{ .tlc_release = "v1.8.0", .tlc_sha256 = good[1..] }) != null);
    try testing.expect(check_config(.{ .tlc_release = "v1.8.0", .tlc_sha256 = "9D" ++ good[2..] }) != null);
}

test "state_label keeps each configuration's states apart" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("spec_tla_store_mutants_skip.cfg", try state_label(arena_state.allocator(), "spec/tla/store/mutants/skip.cfg"));
}
