//! TLC itself: where its jar is, whether it is the one the project pinned, the command that runs
//! it, and what a run concluded.
//!
//! The jar is `tla2tools.jar` from a tlaplus release. `$TLA2TOOLS_JAR` names one the caller
//! already has. Without it the jar is cached at `$XDG_CACHE_HOME/pepegrillo`, or
//! `$HOME/.cache/pepegrillo`, and fetched there with curl the first time. Either way its SHA-256
//! must equal the project's pin before any model runs, because a release asset can be replaced in
//! place.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;

/// The variable that names a jar the caller already has.
pub const jar_variable = "TLA2TOOLS_JAR";
const cache_variable = "XDG_CACHE_HOME";
const home_variable = "HOME";
/// The cache directory under `$HOME` when `$XDG_CACHE_HOME` is not set.
const home_cache_directory = ".cache";
/// pepegrillo's own directory inside the cache.
const cache_directory = "pepegrillo";
/// Where TLC keeps a run's states, inside pepegrillo's cache directory.
const states_directory = "tlc-states";
/// The release asset TLC ships as, by release tag.
const release_url_format = "https://github.com/tlaplus/tlaplus/releases/download/{s}/tla2tools.jar";
/// The program that fetches the jar, and its options: fail on an HTTP error, stay quiet, follow
/// GitHub's redirect to the asset.
const fetch_program = "curl";
const fetch_options = [_][]const u8{ "-fsSL", "-o" };
const fetch_success: u8 = 0;
/// The suffix a fetch writes to before it renames the file into place, so a jar cut short by a
/// failed fetch is never read as a whole one.
const partial_suffix = ".part";
/// Bytes of the jar read to hash it. A tla2tools.jar is a few megabytes.
const jar_len_max: usize = 256 * 1024 * 1024;

/// Hex digits of a SHA-256.
pub const sha256_hex_len: usize = std.crypto.hash.sha2.Sha256.digest_length * 2;

/// The path of the jar to run: `$TLA2TOOLS_JAR`, or the cached one for `release`.
pub fn jar_path(arena: Allocator, environ: *const Environ.Map, release: []const u8) ![]const u8 {
    if (environ.get(jar_variable)) |path| return path;
    const name = try std.fmt.allocPrint(arena, "tla2tools-{s}.jar", .{release});
    return std.fs.path.join(arena, &.{ try cache_root(arena, environ), name });
}

/// Where TLC's states for `label` go: a directory of their own in the cache, which the caller
/// empties before each run.
pub fn states_path(arena: Allocator, environ: *const Environ.Map, label: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ try cache_root(arena, environ), states_directory, label });
}

fn cache_root(arena: Allocator, environ: *const Environ.Map) ![]const u8 {
    if (environ.get(cache_variable)) |base| return std.fs.path.join(arena, &.{ base, cache_directory });
    const home = environ.get(home_variable) orelse return error.NoCacheDirectory;
    return std.fs.path.join(arena, &.{ home, home_cache_directory, cache_directory });
}

/// Fetches `release`'s jar to `path`, through a partial file renamed into place.
pub fn fetch(arena: Allocator, io: Io, release: []const u8, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    const partial = try std.mem.concat(arena, u8, &.{ path, partial_suffix });
    const url = try std.fmt.allocPrint(arena, release_url_format, .{release});
    const command = [_][]const u8{ fetch_program, fetch_options[0], fetch_options[1], partial, url };
    const result = try std.process.run(arena, io, .{ .argv = &command });
    const status = switch (result.term) {
        .exited => |code| code,
        else => return error.FetchFailed,
    };
    if (status != fetch_success) return error.FetchFailed;
    try Io.Dir.cwd().rename(partial, Io.Dir.cwd(), path, io);
}

/// The SHA-256 of the file at `path`, in lowercase hex.
pub fn file_sha256(arena: Allocator, io: Io, path: []const u8) ![sha256_hex_len]u8 {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(jar_len_max));
    return sha256_hex(bytes);
}

pub fn sha256_hex(bytes: []const u8) [sha256_hex_len]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// What a TLC run concluded.
pub const Verdict = union(enum) {
    /// Every invariant and property held.
    holds,
    /// TLC found a behavior that breaks one: a deadlock, an invariant, a temporal property or an
    /// assertion.
    violated,
    /// TLC could not check the model, with this exit status: a parse error, a bad configuration,
    /// an assumption that fails, or no Java at all.
    failed: u8,
};

/// TLC's exit statuses (`tlc2.output.EC.ExitStatus`): success, and the four ways a model it could
/// check is violated. An assumption that fails (10) is a configuration TLC cannot check, so it is
/// a failure, not a violation.
const exit_success: u8 = 0;
const exit_deadlock: u8 = 11;
const exit_safety: u8 = 12;
const exit_liveness: u8 = 13;
const exit_assert: u8 = 14;
/// The status a run that did not exit on its own is reported with.
const exit_not_exited: u8 = 255;

pub fn verdict_of(term: std.process.Child.Term) Verdict {
    const status = switch (term) {
        .exited => |code| code,
        else => return .{ .failed = exit_not_exited },
    };
    return switch (status) {
        exit_success => .holds,
        exit_deadlock, exit_safety, exit_liveness, exit_assert => .violated,
        else => .{ .failed = status },
    };
}

/// What TLC prints after a count of the states it found.
const states_marker = " distinct states found";

/// The last count of distinct states TLC printed, or null when it printed none. Progress lines
/// group the digits with commas; the final line does not.
pub fn states_found(output: []const u8) ?u64 {
    const end = std.mem.lastIndexOf(u8, output, states_marker) orelse return null;
    var start = end;
    while (start > 0 and (std.ascii.isDigit(output[start - 1]) or output[start - 1] == ',')) start -= 1;
    var count: u64 = 0;
    for (output[start..end]) |character| {
        if (character == ',') continue;
        count = std.math.mul(u64, count, 10) catch return null;
        count = std.math.add(u64, count, character - '0') catch return null;
    }
    return if (start == end) null else count;
}

/// How one configuration is run.
pub const Invocation = struct {
    java_program: []const u8,
    java_options: []const []const u8,
    workers: []const u8,
    jar: []const u8,
    states: []const u8,
    /// Relative to the model directory, which TLC runs in.
    configuration: []const u8,
    module: []const u8,
    /// TLC's own options beyond these, such as `-simulate num=10 -depth 41 -seed 1` for a run of
    /// random walks in place of a check.
    tlc_options: []const []const u8 = &.{},
};

/// The command line: `java <options> -cp <jar> tlc2.TLC <TLC options> -workers <n> -metadir
/// <states> -config <configuration> <module>`.
pub fn argv(arena: Allocator, invocation: Invocation) ![]const []const u8 {
    var arguments: std.ArrayList([]const u8) = .empty;
    try arguments.append(arena, invocation.java_program);
    try arguments.appendSlice(arena, invocation.java_options);
    try arguments.appendSlice(arena, &.{ "-cp", invocation.jar, "tlc2.TLC" });
    try arguments.appendSlice(arena, invocation.tlc_options);
    try arguments.appendSlice(arena, &.{ "-workers", invocation.workers, "-metadir", invocation.states });
    try arguments.appendSlice(arena, &.{ "-config", invocation.configuration, invocation.module });
    return arguments.items;
}

// Tests.

const testing = std.testing;

test "verdict_of reads TLC's exit status" {
    try testing.expectEqual(Verdict.holds, verdict_of(.{ .exited = 0 }));
    for ([_]u8{ 11, 12, 13, 14 }) |status| try testing.expectEqual(Verdict.violated, verdict_of(.{ .exited = status }));
    // A failed assumption, a parse error and a missing class are failures, not verdicts.
    for ([_]u8{ 10, 75, 150, 1 }) |status| try testing.expectEqual(Verdict{ .failed = status }, verdict_of(.{ .exited = status }));
    try testing.expectEqual(Verdict{ .failed = 255 }, verdict_of(.{ .unknown = 3 }));
}

test "states_found reads the last count, with or without commas" {
    const output =
        \\Progress(17): 884,918 states generated, 133,687 distinct states found, 15 states left on queue.
        \\1193851 states generated, 153909 distinct states found, 0 states left on queue.
        \\
    ;
    try testing.expectEqual(153909, states_found(output).?);
    try testing.expectEqual(133687, states_found("x: 884,918 states generated, 133,687 distinct states found").?);
    try testing.expectEqual(null, states_found("Error: TLC threw an unexpected exception."));
    try testing.expectEqual(null, states_found("no distinct states found"));
}

test "sha256_hex is the lowercase hex of the digest" {
    // FIPS 180-2's example: SHA-256("abc").
    try testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &sha256_hex("abc"),
    );
}

test "jar_path takes $TLA2TOOLS_JAR first, then the cache" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var environ: Environ.Map = .init(arena);
    try environ.put("HOME", "/home/person");
    try testing.expectEqualStrings("/home/person/.cache/pepegrillo/tla2tools-v1.8.0.jar", try jar_path(arena, &environ, "v1.8.0"));
    try environ.put("XDG_CACHE_HOME", "/var/cache");
    try testing.expectEqualStrings("/var/cache/pepegrillo/tla2tools-v1.8.0.jar", try jar_path(arena, &environ, "v1.8.0"));
    try environ.put("TLA2TOOLS_JAR", "/opt/tla2tools.jar");
    try testing.expectEqualStrings("/opt/tla2tools.jar", try jar_path(arena, &environ, "v1.8.0"));
    try testing.expectEqualStrings("/var/cache/pepegrillo/tlc-states/store", try states_path(arena, &environ, "store"));
}

test "argv runs TLC from the jar on one configuration and its module" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const got = try argv(arena_state.allocator(), .{
        .java_program = "java",
        .java_options = &.{"-XX:+UseParallelGC"},
        .workers = "auto",
        .jar = "/j.jar",
        .states = "/s",
        .configuration = "mutants/skip_fsync.cfg",
        .module = "MCStore",
    });
    const expected = [_][]const u8{
        "java", "-XX:+UseParallelGC", "-cp", "/j.jar",  "tlc2.TLC",               "-workers",
        "auto", "-metadir",           "/s",  "-config", "mutants/skip_fsync.cfg", "MCStore",
    };
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |want, have| try testing.expectEqualStrings(want, have);
}

test "argv puts TLC's own options after its class and before the configuration" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const got = try argv(arena_state.allocator(), .{
        .java_program = "java",
        .java_options = &.{},
        .workers = "1",
        .jar = "/j.jar",
        .states = "/s",
        .configuration = "trace/Walk.cfg",
        .module = "MCStoreWalk",
        .tlc_options = &.{ "-simulate", "num=10", "-depth", "41" },
    });
    const expected = [_][]const u8{
        "java",     "-cp", "/j.jar",   "tlc2.TLC", "-simulate", "num=10",         "-depth",      "41",
        "-workers", "1",   "-metadir", "/s",       "-config",   "trace/Walk.cfg", "MCStoreWalk",
    };
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |want, have| try testing.expectEqualStrings(want, have);
}
