//! Tests of the command line, the walk and the report of `complexity_report.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;
const report = @import("complexity_report.zig");
const Report = report.Report;
const Options = report.Options;
const parse_arguments = report.parse_arguments;
const print_report = report.print_report;
const scorer = @import("complexity_scorer.zig");
const FunctionScore = scorer.FunctionScore;
const boundary_source = @import("complexity_fixture.zig").boundary_source;

test "parse_arguments reads --max, --list and the paths, and defaults to 15 without a list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const options = try parse_arguments(arena, &.{ "--max", "20", "--list", "src", "tools" });
    try testing.expectEqual(20, options.max_score);
    try testing.expect(options.list);
    try testing.expectEqual(2, options.paths.len);
    try testing.expectEqualStrings("src", options.paths[0]);
    try testing.expectEqualStrings("tools", options.paths[1]);

    const defaults = try parse_arguments(arena, &.{"src"});
    try testing.expectEqual(report.default_max_score, defaults.max_score);
    try testing.expectEqual(15, defaults.max_score);
    try testing.expect(!defaults.list);
}

test "parse_arguments rejects a missing or bad value, an unknown flag, and no paths" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.MissingValue, parse_arguments(arena, &.{ "src", "--max" }));
    try testing.expectError(error.BadValue, parse_arguments(arena, &.{ "--max", "many", "src" }));
    try testing.expectError(error.UnknownFlag, parse_arguments(arena, &.{ "--limit", "3", "src" }));
    // A single dash is a flag too, so a mistyped flag never becomes a path.
    try testing.expectError(error.UnknownFlag, parse_arguments(arena, &.{ "-x", "src" }));
    try testing.expectError(error.NoPaths, parse_arguments(arena, &.{}));
    try testing.expectError(error.NoPaths, parse_arguments(arena, &.{"--list"}));
}

/// Runs `print_report` over the given scores and returns the text and the status.
fn run_report(
    arena: Allocator,
    scores: []const FunctionScore,
    options: Options,
) !struct { []const u8, u8 } {
    var run: Report = .{ .arena = arena, .io = testing.io };
    try run.scores.appendSlice(arena, scores);
    var writer: Io.Writer.Allocating = .init(arena);
    const status = try print_report(&writer.writer, &run, options);
    return .{ writer.written(), status };
}

test "a declaration over the threshold is named and the status is 1" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text, const status = try run_report(arena_state.allocator(), &.{
        .{ .path = "src/store/page.zig", .line = 12, .column = 4, .name = "parse", .score = 9 },
        .{ .path = "src/store/page.zig", .line = 40, .column = 4, .name = "write", .score = 2 },
    }, .{ .max_score = 3 });
    try testing.expectEqual(report.exit_findings, status);
    try testing.expectEqualStrings(
        \\src/store/page.zig:12: parse scored 9 (max 3)
        \\cognitive-complexity: 1 of 2 functions over the limit, 0 files not scored
        \\
    , text);
}

test "every violation is reported, sorted by path and then line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text, const status = try run_report(arena_state.allocator(), &.{
        .{ .path = "src/store/b.zig", .line = 3, .column = 1, .name = "third", .score = 20 },
        .{ .path = "src/store/a.zig", .line = 9, .column = 1, .name = "second", .score = 16 },
        .{ .path = "src/store/a.zig", .line = 7, .column = 1, .name = "first", .score = 17 },
    }, .{});
    try testing.expectEqual(report.exit_findings, status);
    try testing.expectEqualStrings(
        \\src/store/a.zig:7: first scored 17 (max 15)
        \\src/store/a.zig:9: second scored 16 (max 15)
        \\src/store/b.zig:3: third scored 20 (max 15)
        \\cognitive-complexity: 3 of 3 functions over the limit, 0 files not scored
        \\
    , text);
}

test "a clean run prints one summary line, and a score equal to the threshold passes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text, const status = try run_report(arena_state.allocator(), &.{
        .{ .path = "src/store/a.zig", .line = 1, .column = 1, .name = "small", .score = 4 },
        .{ .path = "src/store/a.zig", .line = 9, .column = 1, .name = "at_limit", .score = 15 },
    }, .{});
    try testing.expectEqual(report.exit_clean, status);
    try testing.expectEqualStrings(
        "cognitive-complexity: 2 functions scored, highest 15 (max 15)\n",
        text,
    );
}

test "over the boundary fixture 16 fails at the default threshold and passes at 16" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const scores = try scorer.score_source(arena, "src/store/page.zig", boundary_source);
    const text, const failing = try run_report(arena, scores, .{});
    try testing.expectEqual(report.exit_findings, failing);
    try testing.expect(std.mem.startsWith(u8, text, "src/store/page.zig:17: sixteen scored 16"));
    _, const passing = try run_report(arena, scores, .{ .max_score = 16 });
    try testing.expectEqual(report.exit_clean, passing);
}

test "--list prints every declaration highest first, then by path and line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text, const status = try run_report(arena_state.allocator(), &.{
        .{ .path = "src/store/b.zig", .line = 2, .column = 1, .name = "tied_later", .score = 3 },
        .{ .path = "src/store/a.zig", .line = 5, .column = 1, .name = "low", .score = 0 },
        .{ .path = "src/store/a.zig", .line = 8, .column = 1, .name = "tied_first", .score = 3 },
        .{ .path = "src/store/b.zig", .line = 1, .column = 1, .name = "high", .score = 7 },
    }, .{ .max_score = 15, .list = true });
    // Nothing is over the threshold, so listing changes the lines printed and not the status.
    try testing.expectEqual(report.exit_clean, status);
    try testing.expectEqualStrings(
        \\src/store/b.zig:1: high scored 7 (max 15)
        \\src/store/a.zig:8: tied_first scored 3 (max 15)
        \\src/store/b.zig:2: tied_later scored 3 (max 15)
        \\src/store/a.zig:5: low scored 0 (max 15)
        \\cognitive-complexity: 4 functions scored, highest 7 (max 15)
        \\
    , text);
}

test "files not scored follow the scores, sorted by path, and fail the run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var run: Report = .{ .arena = arena, .io = testing.io };
    try run.scores.append(arena, .{
        .path = "src/store/a.zig",
        .line = 1,
        .column = 1,
        .name = "small",
        .score = 1,
    });
    try run.unscored.append(arena, .{ .path = "src/store/z.zig", .reason = "ParseFailed" });
    try run.unscored.append(arena, .{ .path = "src/store/m.zig", .reason = "NestingTooDeep" });
    var writer: Io.Writer.Allocating = .init(arena);
    const status = try print_report(&writer.writer, &run, .{});
    try testing.expectEqual(report.exit_findings, status);
    try testing.expectEqualStrings(
        \\src/store/m.zig: not scored (NestingTooDeep)
        \\src/store/z.zig: not scored (ParseFailed)
        \\cognitive-complexity: 0 of 1 functions over the limit, 2 files not scored
        \\
    , writer.written());
}

test "the walk skips build output, version control and files that are not Zig" {
    try testing.expect(report.is_skipped_directory(".zig-cache"));
    try testing.expect(report.is_skipped_directory("zig-out"));
    try testing.expect(report.is_skipped_directory(".git"));
    try testing.expect(!report.is_skipped_directory("src"));
}

/// Writes the fixture tree the walk tests read: one scored file, one that does not parse, a
/// file that is not Zig, and one Zig file under each skipped directory.
fn write_walk_fixture(dir: Io.Dir) !void {
    const io = testing.io;
    const source = "pub fn branch(a: bool) void {\n    if (a) {}\n}\n";
    try dir.createDirPath(io, "src/store");
    try dir.writeFile(io, .{ .sub_path = "src/store/page.zig", .data = source });
    try dir.writeFile(io, .{ .sub_path = "src/store/broken.zig", .data = "fn broken( {\n" });
    try dir.writeFile(io, .{ .sub_path = "src/store/page.zig.orig", .data = "fn ( {\n" });
    for (report.skipped_directories) |skipped| {
        try dir.createDirPath(io, skipped);
        var path_buffer: [report.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/skipped.zig", .{skipped});
        try dir.writeFile(io, .{ .sub_path = path, .data = source });
    }
}

test "the walk scores Zig files under the root and reports a file that does not parse" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try write_walk_fixture(tmp.dir);

    var run: Report = .{ .arena = arena_state.allocator(), .io = testing.io };
    // Files are read through the joined path, relative to the working directory, where
    // `testing.tmpDir` creates the directory. The trailing separator is dropped by the join.
    var root_buffer: [report.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, ".zig-cache/tmp/{s}/", .{tmp.sub_path});
    try run.walk_directory(tmp.dir, root);

    try testing.expectEqual(2, run.files_seen);
    try testing.expectEqual(1, run.scores.items.len);
    try testing.expectEqualStrings("branch", run.scores.items[0].name);
    try testing.expect(std.mem.endsWith(u8, run.scores.items[0].path, "/src/store/page.zig"));
    try testing.expect(std.mem.indexOf(u8, run.scores.items[0].path, "//") == null);
    try testing.expectEqual(1, run.unscored.items.len);
    try testing.expect(std.mem.endsWith(u8, run.unscored.items[0].path, "/src/store/broken.zig"));
    try testing.expectEqualStrings("ParseFailed", run.unscored.items[0].reason);
}

test "lint_path scores a single file and returns the error of a missing path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "page.zig", .data = "fn f() void {}\n" });
    var path_buffer: [report.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/page.zig", .{tmp.sub_path});

    var run: Report = .{ .arena = arena_state.allocator(), .io = testing.io };
    try run.lint_path(path);
    try testing.expectEqual(1, run.scores.items.len);
    try testing.expectError(error.FileNotFound, run.lint_path(".zig-cache/tmp/no-such/page.zig"));
}

test "a path longer than max_path_bytes is reported as not scored" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "page.zig", .data = "fn f() void {}\n" });

    var run: Report = .{ .arena = arena_state.allocator(), .io = testing.io };
    const long_root = "r" ** report.max_path_bytes;
    try run.walk_directory(tmp.dir, long_root);
    try testing.expectEqual(0, run.files_seen);
    try testing.expectEqual(1, run.unscored.items.len);
    try testing.expectEqualStrings("page.zig", run.unscored.items[0].path);
    try testing.expectEqualStrings("PathTooLong", run.unscored.items[0].reason);
}

test "a file past max_files_per_run ends the run with an error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "page.zig", .data = "fn f() void {}\n" });
    var path_buffer: [report.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/page.zig", .{tmp.sub_path});

    var run: Report = .{ .arena = arena_state.allocator(), .io = testing.io };
    run.files_seen = report.max_files_per_run - 1;
    try run.lint_path(path);
    try testing.expectEqual(1, run.scores.items.len);
    try testing.expectError(error.TooManyFiles, run.lint_path(path));
}
