//! The command line, the directory walk, and the report of one cognitive-complexity run.
//! `complexity.zig` calls these from `main`; the tests are `complexity_report_test.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const paths = @import("../lint/paths.zig");
const report_line = @import("../report_line.zig");
const scorer = @import("complexity_scorer.zig");
const FunctionScore = scorer.FunctionScore;

/// The rule name a score is reported under.
pub const score_rule_name = "cognitive-complexity";

/// The rule name a file that could not be scored is reported under.
pub const unscored_rule_name = "not-scored";

/// Threshold applied when `--max` is absent: a score of 15 passes and 16 fails.
pub const default_max_score: u32 = 15;

/// Largest source file the tool reads. A larger one is reported as not scored.
pub const max_source_bytes: usize = 4 * 1024 * 1024;

/// Longest path the walk builds. A longer one is reported as not scored.
pub const max_path_bytes: usize = 4096;

/// Files read per run across every PATH. One more ends the run with `error.TooManyFiles`.
pub const max_files_per_run: usize = 65536;

/// Directories the walk does not enter: build output and version control, never hand-written.
pub const skipped_directories = [_][]const u8{ ".zig-cache", "zig-out", ".git" };

/// Exit status when every declaration is at or under the threshold and every file was scored.
pub const exit_clean: u8 = 0;
/// Exit status when a declaration is over the threshold or a file was not scored.
pub const exit_findings: u8 = 1;
/// Exit status for a malformed command line or a PATH the tool cannot read.
pub const exit_usage: u8 = 2;

const max_flag = "--max";
const list_flag = "--list";

pub const Options = struct {
    max_score: u32 = default_max_score,
    /// Print every declaration, highest score first, instead of only those over the threshold.
    list: bool = false,
    paths: []const []const u8 = &.{},
};

pub const ArgumentError = error{ MissingValue, BadValue, UnknownFlag, NoPaths } || Allocator.Error;

/// Reads `arguments`, without the program name, into `Options`. Every argument that starts with
/// `-` and is not a known flag is an error, so a mistyped flag never becomes a path.
pub fn parse_arguments(arena: Allocator, arguments: []const []const u8) ArgumentError!Options {
    var options: Options = .{};
    var path_list: std.ArrayList([]const u8) = .empty;
    try path_list.ensureTotalCapacity(arena, arguments.len);
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, max_flag)) {
            index += 1;
            if (index >= arguments.len) return error.MissingValue;
            options.max_score = std.fmt.parseInt(u32, arguments[index], 10) catch {
                return error.BadValue;
            };
        } else if (std.mem.eql(u8, argument, list_flag)) {
            options.list = true;
        } else if (std.mem.startsWith(u8, argument, "-")) {
            return error.UnknownFlag;
        } else {
            path_list.appendAssumeCapacity(argument);
        }
    }
    if (path_list.items.len == 0) return error.NoPaths;
    options.paths = path_list.items;
    return options;
}

pub fn print_usage() void {
    std.debug.print("usage: cognitive_complexity [--max N] [--list] PATH...\n", .{});
}

/// One file the tool could not score, kept so the run reports it instead of passing silently
/// over source it never read.
pub const Unscored = struct {
    path: []const u8,
    reason: []const u8,
};

/// Everything one run accumulates: the scores of every file under every PATH, the files that
/// could not be scored, and the count of files read.
pub const Report = struct {
    arena: Allocator,
    io: Io,
    scores: std.ArrayList(FunctionScore) = .empty,
    unscored: std.ArrayList(Unscored) = .empty,
    files_seen: usize = 0,
    /// The canonical working directory every PATH is made relative to, so a score reads
    /// `src/...` whether `zig build` passed an absolute or a `./` path. Empty leaves an absolute
    /// PATH absolute.
    working_directory: []const u8 = "",

    /// Scores one PATH: a file, or a directory walked recursively. A PATH that cannot be opened
    /// returns its error, which `main` reports as a usage error.
    pub fn lint_path(self: *Report, argument: []const u8) !void {
        const path = paths.resolve_argument(self.arena, self.io, self.working_directory, argument);
        const stat = try Io.Dir.cwd().statFile(self.io, path, .{});
        if (stat.kind != .directory) return self.lint_file(path);
        var dir = try Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });
        defer dir.close(self.io);
        try self.walk_directory(dir, path);
    }

    /// Scores every `.zig` file under `dir`, reported and read as `root/...`, entering every
    /// directory but the skipped ones.
    pub fn walk_directory(self: *Report, dir: Io.Dir, root: []const u8) !void {
        var walker = try dir.walkSelectively(self.arena);
        defer walker.deinit();
        var path_buffer: [max_path_bytes]u8 = undefined;
        while (try walker.next(self.io)) |entry| {
            switch (entry.kind) {
                .directory => if (!is_skipped_directory(entry.basename)) {
                    try walker.enter(self.io, entry);
                },
                .file => if (paths.has_extension(entry.basename, paths.zig_extension)) {
                    const joined = paths.join(&path_buffer, root, entry.path) catch {
                        try self.record_unscored(entry.path, "PathTooLong");
                        continue;
                    };
                    try self.lint_file(joined);
                },
                else => {},
            }
        }
    }

    fn lint_file(self: *Report, path: []const u8) !void {
        self.files_seen += 1;
        if (self.files_seen > max_files_per_run) return error.TooManyFiles;
        const source = Io.Dir.cwd().readFileAllocOptions(
            self.io,
            path,
            self.arena,
            .limited(max_source_bytes),
            .of(u8),
            0,
        ) catch |failure| return self.record_unscored(path, @errorName(failure));
        const scores = scorer.score_source(self.arena, path, source) catch |failure| {
            switch (failure) {
                error.OutOfMemory => return failure,
                else => return self.record_unscored(path, @errorName(failure)),
            }
        };
        try self.scores.appendSlice(self.arena, scores);
    }

    fn record_unscored(self: *Report, path: []const u8, reason: []const u8) !void {
        try self.unscored.append(self.arena, .{
            .path = try self.arena.dupe(u8, path),
            .reason = reason,
        });
    }
};

pub fn is_skipped_directory(basename: []const u8) bool {
    for (skipped_directories) |skipped| {
        if (std.mem.eql(u8, basename, skipped)) return true;
    }
    return false;
}

/// Orders scores by path, then line, then column, so the report reads top to bottom through each
/// file whatever order the walk visited the files in.
fn path_before(_: void, left: FunctionScore, right: FunctionScore) bool {
    switch (std.mem.order(u8, left.path, right.path)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (left.line != right.line) return left.line < right.line;
    return left.column < right.column;
}

/// Orders scores highest first, and equal scores by `path_before`.
fn score_before(_: void, left: FunctionScore, right: FunctionScore) bool {
    if (left.score != right.score) return left.score > right.score;
    return path_before({}, left, right);
}

fn unscored_before(_: void, left: Unscored, right: Unscored) bool {
    return std.mem.order(u8, left.path, right.path) == .lt;
}

/// Prints one line per declaration over the threshold, or per declaration with `list`, then one
/// line per file not scored, then the summary line. A declaration over the threshold is an
/// `error`, and one at or under it, printed only with `list`, is a `note`. Returns the exit status.
pub fn print_report(out: *Io.Writer, report: *Report, options: Options) !u8 {
    const scores = report.scores.items;
    if (options.list) {
        std.mem.sort(FunctionScore, scores, {}, score_before);
    } else {
        std.mem.sort(FunctionScore, scores, {}, path_before);
    }
    var violations: usize = 0;
    var highest: u32 = 0;
    for (scores) |scored| {
        highest = @max(highest, scored.score);
        const over = scored.score > options.max_score;
        if (over) violations += 1;
        if (!over and !options.list) continue;
        const location: report_line.Location = .{
            .source = scored.path,
            .position = .{ .line = scored.line, .column = scored.column },
        };
        const severity: report_line.Severity = if (over) .@"error" else .note;
        const message = "{s} scored {d} (max {d})";
        try report_line.write(out, location, severity, score_rule_name, message, .{
            scored.name, scored.score, options.max_score,
        });
    }
    const unscored = report.unscored.items;
    std.mem.sort(Unscored, unscored, {}, unscored_before);
    for (unscored) |file| {
        const location: report_line.Location = .{ .source = file.path };
        try report_line.write(out, location, .@"error", unscored_rule_name, "{s}", .{file.reason});
    }
    return print_summary(out, .{
        .scored = scores.len,
        .highest = highest,
        .violations = violations,
        .unscored = unscored.len,
        .max_score = options.max_score,
    });
}

const Totals = struct {
    scored: usize,
    highest: u32,
    violations: usize,
    unscored: usize,
    max_score: u32,
};

fn print_summary(out: *Io.Writer, totals: Totals) !u8 {
    if (totals.violations == 0 and totals.unscored == 0) {
        try out.print("cognitive-complexity: {d} functions scored, highest {d} (max {d})\n", .{
            totals.scored, totals.highest, totals.max_score,
        });
        try out.flush();
        return exit_clean;
    }
    try out.print(
        "cognitive-complexity: {d} of {d} functions over the limit, {d} files not scored\n",
        .{ totals.violations, totals.scored, totals.unscored },
    );
    try out.flush();
    return exit_findings;
}

test {
    _ = @import("complexity_report_test.zig");
}
