//! Tests of `coverage.zig`. A shell script stands in for kcov, so the tests run where kcov does
//! not: it prints a release, runs the program, and on a merge copies a report the test wrote.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Context = @import("../context.zig").Context;
const coverage = @import("coverage.zig");

const testing = std.testing;

/// Where each test keeps its files, from the working directory. A configuration is comptime, so
/// its paths are fixed and not those of `testing.tmpDir`.
const test_root = ".zig-cache/tmp/coverage-test";

/// The report that the stand-in's merge writes.
const Report = enum { counted, no_lines, malformed };

/// What the stand-in for kcov does.
const StandIn = struct {
    version: []const u8 = "kcov 43+dfsg-2",
    version_status: u8 = 0,
    merge_status: u8 = 0,
    report: Report = .counted,
};

/// A configuration whose paths are all under `base`.
fn config_at(comptime base: []const u8) coverage.Config {
    return .{
        .directories = &.{ base ++ "/src/store", base ++ "/src/wire" },
        .output = base ++ "/out",
        .kcov_program = base ++ "/kcov",
    };
}

fn with_kcov(comptime project: coverage.Config, comptime kcov_program: []const u8) coverage.Config {
    var changed = project;
    changed.kcov_program = kcov_program;
    return changed;
}

fn with_directories(comptime project: coverage.Config, comptime directories: []const []const u8) coverage.Config {
    var changed = project;
    changed.directories = directories;
    return changed;
}

/// Writes the directories, the stand-in for kcov, the report and two programs under `base`:
/// `pass` exits with status 0, and `fail` prints to standard error and exits with status 1.
fn prepare(arena: Allocator, comptime base: []const u8, stand_in: StandIn) !void {
    const io = testing.io;
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, base) catch {};
    try cwd.createDirPath(io, base ++ "/src/store");
    try cwd.createDirPath(io, base ++ "/src/wire");
    const script = try std.fmt.allocPrint(arena,
        \\#!/bin/sh
        \\here=$(dirname "$0")
        \\if [ "$1" = "--version" ]; then echo '{s}'; exit {d}; fi
        \\if [ "$1" = "--merge" ]; then
        \\  if [ {d} -ne 0 ]; then echo 'kcov: cannot merge' >&2; exit {d}; fi
        \\  mkdir -p "$2/kcov-merged" && cp "$here/report.json" "$2/kcov-merged/coverage.json"
        \\  exit 0
        \\fi
        \\mkdir -p "$2" && printf '%s' "$1" > "$2/include" && "$3"
        \\
    , .{ stand_in.version, stand_in.version_status, stand_in.merge_status, stand_in.merge_status });
    try write_program(base ++ "/kcov", script);
    try write_program(base ++ "/pass", "#!/bin/sh\nexit 0\n");
    try write_program(base ++ "/fail", "#!/bin/sh\necho 'expected 1, found 2' >&2\nexit 1\n");
    try cwd.writeFile(io, .{ .sub_path = base ++ "/report.json", .data = try report_text(arena, base, stand_in.report) });
}

fn write_program(path: []const u8, text: []const u8) !void {
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = text, .flags = .{ .permissions = .executable_file } });
}

/// kcov's report over the absolute paths of the directories under `base`.
fn report_text(arena: Allocator, comptime base: []const u8, kind: Report) ![]const u8 {
    const store = try Io.Dir.cwd().realPathFileAlloc(testing.io, base ++ "/src/store", arena);
    const wire = try Io.Dir.cwd().realPathFileAlloc(testing.io, base ++ "/src/wire", arena);
    return switch (kind) {
        .counted => std.fmt.allocPrint(arena,
            \\{{"files": [
            \\  {{"file": "{s}/page.zig", "covered_lines": "6", "total_lines": "9"}},
            \\  {{"file": "{s}/index.zig", "covered_lines": "1", "total_lines": "2"}},
            \\  {{"file": "{s}/frame.zig", "covered_lines": "3", "total_lines": "4"}},
            \\  {{"file": "/elsewhere/std/mem.zig", "covered_lines": "50", "total_lines": "90"}}
            \\], "covered_lines": 60, "total_lines": 105}}
        , .{ store, store, wire }),
        .no_lines => "{\"files\": [], \"covered_lines\": 0, \"total_lines\": 0}",
        .malformed => "<html>",
    };
}

/// What one run gave: its exit status, its report and its errors.
const Outcome = struct {
    status: u8,
    out: []const u8,
    errors: []const u8,
};

fn run_at(arena: Allocator, comptime project: coverage.Config, given: []const []const u8) !Outcome {
    var environ: std.process.Environ.Map = .init(arena);
    const out_buffer = try arena.alloc(u8, 4096);
    const error_buffer = try arena.alloc(u8, 4096);
    var out: Io.Writer = .fixed(out_buffer);
    var errors: Io.Writer = .fixed(error_buffer);
    const context: Context = .{ .arena = arena, .io = testing.io, .environ = &environ, .out = &out, .errors = &errors };
    const status = try coverage.run(&context, project, given);
    return .{ .status = status, .out = out.buffered(), .errors = errors.buffered() };
}

fn contains(text: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, text, part) != null;
}

test "run reports each directory and the total, and fails after the report when a program fails" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = test_root ++ "/counted";
    try prepare(arena, base, .{});
    // A file that an earlier run left in the output, which the engine deletes.
    try Io.Dir.cwd().createDirPath(testing.io, base ++ "/out/run-9");
    const outcome = try run_at(arena, comptime config_at(base), &.{ base ++ "/pass", base ++ "/fail" });
    try testing.expectEqual(1, outcome.status);
    try testing.expectEqualStrings(
        base ++ "/src/store: note: [coverage] 63.6% of 11 lines\n" ++
            base ++ "/src/wire: note: [coverage] 75.0% of 4 lines\n" ++
            base ++ "/out: note: [coverage] total 66.6% of 15 lines\n",
        outcome.out,
    );
    try testing.expect(contains(outcome.errors, base ++ "/fail: error: [coverage] the program exited with status 1 under kcov\n"));
    try testing.expect(contains(outcome.errors, "expected 1, found 2\n"));
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(testing.io, base ++ "/out/run-9", .{}));
}

test "run passes when every program passes, and gives kcov the absolute path of each directory" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = test_root ++ "/passed";
    try prepare(arena, base, .{});
    const outcome = try run_at(arena, comptime config_at(base), &.{base ++ "/pass"});
    try testing.expectEqual(0, outcome.status);
    try testing.expectEqualStrings("", outcome.errors);
    const include = try Io.Dir.cwd().readFileAlloc(testing.io, base ++ "/out/run-1/include", arena, .limited(4096));
    const store = try Io.Dir.cwd().realPathFileAlloc(testing.io, base ++ "/src/store", arena);
    const wire = try Io.Dir.cwd().realPathFileAlloc(testing.io, base ++ "/src/wire", arena);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "--include-path={s},{s}", .{ store, wire }), include);
}

test "run judges nothing without a program, without kcov, or with another kcov release" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = test_root ++ "/unusable";
    try prepare(arena, base, .{ .version = "kcov v42" });
    const project = comptime config_at(base);
    const usage = try run_at(arena, project, &.{});
    try testing.expectEqual(2, usage.status);
    try testing.expect(contains(usage.errors, "coverage: error: [coverage] usage: coverage <program>..."));
    const other = try run_at(arena, project, &.{base ++ "/pass"});
    try testing.expectEqual(2, other.status);
    try testing.expect(contains(other.errors, "error: [coverage] kcov 42 is installed, and the project pins kcov 43"));
    const missing = comptime with_kcov(project, base ++ "/no-kcov");
    const absent = try run_at(arena, missing, &.{base ++ "/pass"});
    try testing.expectEqual(2, absent.status);
    try testing.expect(contains(absent.errors, base ++ "/no-kcov: error: [coverage] no kcov there; install kcov 43"));
}

test "run judges nothing when kcov names no release, or a directory does not exist" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = test_root ++ "/unnamed";
    try prepare(arena, base, .{ .version = "kcov", .version_status = 0 });
    const unnamed = try run_at(arena, comptime config_at(base), &.{base ++ "/pass"});
    try testing.expectEqual(2, unnamed.status);
    try testing.expect(contains(unnamed.errors, "error: [coverage] kcov --version names no release"));
    try prepare(arena, base, .{});
    const absent = comptime with_directories(config_at(base), &.{base ++ "/src/gone"});
    const gone = try run_at(arena, absent, &.{base ++ "/pass"});
    try testing.expectEqual(2, gone.status);
    try testing.expect(contains(gone.errors, base ++ "/src/gone: error: [coverage] cannot resolve: FileNotFound"));
}

test "run refuses a directory whose absolute path holds a comma, which kcov reads between paths" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = test_root ++ "/comma";
    try prepare(arena, base, .{});
    const cwd = Io.Dir.cwd();
    try cwd.deleteTree(testing.io, base ++ "/src/wire");
    try cwd.createDirPath(testing.io, base ++ "/a,b");
    try cwd.symLink(testing.io, "../a,b", base ++ "/src/wire", .{ .is_directory = true });
    const outcome = try run_at(arena, comptime config_at(base), &.{base ++ "/pass"});
    try testing.expectEqual(2, outcome.status);
    try testing.expect(contains(outcome.errors, base ++ "/src/wire: error: [coverage] its absolute path holds a comma"));
}

test "run judges nothing when the merge fails, or its report is not kcov's or counts no line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = test_root ++ "/merge";
    const project = comptime config_at(base);
    try prepare(arena, base, .{ .merge_status = 3 });
    const unmerged = try run_at(arena, project, &.{base ++ "/pass"});
    try testing.expectEqual(2, unmerged.status);
    try testing.expect(contains(unmerged.errors, base ++ "/kcov: error: [coverage] kcov --merge failed: the program exited with status 3\nkcov: cannot merge\n"));
    try prepare(arena, base, .{ .report = .malformed });
    const malformed = try run_at(arena, project, &.{base ++ "/pass"});
    try testing.expectEqual(2, malformed.status);
    try testing.expect(contains(malformed.errors, base ++ "/out/merged/kcov-merged/coverage.json: error: [coverage] is not a kcov report"));
    try prepare(arena, base, .{ .report = .no_lines });
    const empty = try run_at(arena, project, &.{base ++ "/pass"});
    try testing.expectEqual(2, empty.status);
    try testing.expect(contains(empty.out, base ++ "/src/store: warning: [coverage] counted no line"));
    try testing.expect(contains(empty.errors, base ++ "/out: error: [coverage] counted no line in any directory"));
}

test "check_config refuses directories that overlap, leave the working directory, or sit in output" {
    try testing.expectEqual(null, coverage.check_config(.{ .directories = &.{ "src/store", "src/storage" } }));
    try testing.expect(coverage.check_config(.{ .directories = &.{} }) != null);
    try testing.expect(coverage.check_config(.{ .directories = &.{""} }) != null);
    try testing.expect(coverage.check_config(.{ .directories = &.{"/src"} }) != null);
    try testing.expect(coverage.check_config(.{ .directories = &.{"../src"} }) != null);
    try testing.expect(coverage.check_config(.{ .directories = &.{"src/./store"} }) != null);
    try testing.expect(coverage.check_config(.{ .directories = &.{"src/"} }) != null);
    try testing.expect(coverage.check_config(.{ .directories = &.{"src,tools"} }) != null);
    try testing.expect(coverage.check_config(.{ .directories = &.{ "src", "src/store" } }) != null);
    try testing.expect(coverage.check_config(.{ .directories = &.{ "src/store", "src" } }) != null);
    try testing.expect(coverage.check_config(.{ .directories = &.{ "src", "src" } }) != null);
    try testing.expect(coverage.check_config(.{ .directories = &.{"zig-out/src"}, .output = "zig-out" }) != null);
    try testing.expect(coverage.check_config(.{ .directories = &.{"src"}, .output = "." }) != null);
    try testing.expect(coverage.check_config(.{ .directories = &.{"src"}, .kcov_program = "" }) != null);
    try testing.expect(coverage.check_config(.{ .directories = &.{"src"}, .kcov_release = 0 }) != null);
}
