//! The lint driver: the walk, the arguments, the per-file dispatch, the `parse` pseudo-rule and
//! the exit status, generic over the rules a project hands it.
//!
//! A project's lint entry point names its rules and forwards `main`:
//!
//! ```zig
//! const Linter = pepegrillo.lint.Linter(.{ heap, file_length, markdown });
//! pub fn main(init: std.process.Init) !void {
//!     return Linter.main(init);
//! }
//! ```
//!
//! Each rule is a type that exports a `name` and a `check(context, file)`. The rule reads the path
//! and decides whether the file is its concern.
//!
//! Run:  lint [--rule NAME]... PATH...
//!
//! Every PATH is a file, or a directory walked recursively with the `skipped_directories` left
//! out. A PATH under the working directory is read relative to it, so `zig build`'s absolute and
//! `./` paths reach the rules as `src/...` (`paths.resolve_argument`). Every regular file found is
//! handed to every enabled rule. A `.zig` file is parsed once, and a file that does not parse is
//! reported as a finding of the `parse` pseudo-rule. With no `--rule`, every rule runs; with one
//! or more, only those.
//!
//! One line per finding on standard output, sorted by path, line, column and rule, in the shape
//! `report_line.zig` defines:
//!
//!     path:line:column: error: [rule-name] message
//!
//! A file the walk cannot read is reported on standard error as `path: error: [unreadable] reason`.
//!
//! Exit status: 0 when nothing was found, 1 when any finding was reported or a file failed to
//! read, 2 on a usage error.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Io = std.Io;
const paths = @import("paths.zig");
const report = @import("report.zig");
const report_line = @import("../report_line.zig");

/// The rule name a file that fails to parse is reported under.
pub const parse_rule_name = "parse";

/// The rule name a file the walk cannot read is reported under.
pub const unreadable_rule_name = "unreadable";

/// Longest path the walk builds.
pub const max_path_bytes: usize = 4096;

/// Files visited per run across every PATH. More is reported as an error.
const max_files_per_run: usize = 65536;

/// Command-line arguments the tool reads before giving up.
const max_arguments: usize = 1024;

/// Bytes buffered for standard output before a flush.
const output_buffer_bytes: usize = 16 * 1024;

/// Longest parse error message the tool renders.
const max_parse_error_bytes: usize = 512;

/// Longest line the tool prints about a file it cannot read: the path, and room for the rule name
/// and the reason. A longer line is cut, never an error.
const max_file_error_line_bytes: usize = max_path_bytes + 128;

/// Directories the walk does not enter: build output and version control, never hand-written.
const skipped_directories = [_][]const u8{ ".zig-cache", "zig-out", ".git" };

pub const exit_clean: u8 = 0;
pub const exit_findings: u8 = 1;
pub const exit_usage: u8 = 2;

const rule_flag = "--rule";

pub const ArgumentError = error{
    MissingValue,
    UnknownRule,
    UnknownFlag,
    NoPaths,
} || Allocator.Error;

/// The most rules one driver dispatches to, which sizes the enabled-rule table.
pub const max_rules: usize = 32;

/// Which rules run and which paths are walked, as read from the command line.
pub const Options = struct {
    enabled: [max_rules]bool = @splat(true),
    paths: []const []const u8 = &.{},
};

/// The driver for one set of rules. `rules` is a tuple of rule types, in the order `--rule` names
/// are looked up and the usage line lists them. Every function here forwards to a top-level one
/// that takes `rules` as a comptime parameter, so each is scored on its own.
pub fn Linter(comptime rules: anytype) type {
    comptime assert_rule_set(rules);

    return struct {
        pub const count = rules.len;

        pub fn main(init: std.process.Init) !void {
            return run_main(rules, init);
        }

        pub fn parse_arguments(
            arena: Allocator,
            arguments: []const []const u8,
        ) ArgumentError!Options {
            return parse_arguments_for(rules, arena, arguments);
        }

        pub fn rule_index_of(rule_name: []const u8) ?usize {
            return rule_index_in(rules, rule_name);
        }

        pub fn lint_path(run: *Run, path: []const u8) !void {
            return run.lint_path(rules, path);
        }

        pub fn walk_directory(run: *Run, dir: Io.Dir, root: []const u8) !void {
            return run.walk_directory(rules, dir, root);
        }

        pub fn dispatch(run: *Run, file: report.File) !void {
            return run.dispatch(rules, file);
        }
    };
}

/// Reads `arguments` (without the program name) into `Options`.
fn parse_arguments_for(
    comptime rules: anytype,
    arena: Allocator,
    arguments: []const []const u8,
) ArgumentError!Options {
    var options: Options = .{};
    var selected: [max_rules]bool = @splat(false);
    var any_selected = false;
    var path_list: std.ArrayList([]const u8) = .empty;
    try path_list.ensureTotalCapacity(arena, arguments.len);
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, rule_flag)) {
            index += 1;
            if (index >= arguments.len) return error.MissingValue;
            const rule_name = arguments[index];
            selected[rule_index_in(rules, rule_name) orelse return error.UnknownRule] = true;
            any_selected = true;
        } else if (std.mem.startsWith(u8, argument, "--")) {
            return error.UnknownFlag;
        } else {
            path_list.appendAssumeCapacity(argument);
        }
    }
    if (path_list.items.len == 0) return error.NoPaths;
    if (any_selected) options.enabled = selected;
    options.paths = path_list.items;
    return options;
}

fn rule_index_in(comptime rules: anytype, rule_name: []const u8) ?usize {
    inline for (rules, 0..) |rule, index| {
        if (std.mem.eql(u8, rule.name, rule_name)) return index;
    }
    return null;
}

/// One run: the walk, the per-file dispatch, and the counts the exit status is computed from.
pub const Run = struct {
    context: report.Context,
    enabled: [max_rules]bool = @splat(true),
    files_seen: usize = 0,
    file_errors: usize = 0,
    /// Set by the tests so a passing run writes nothing. `main` leaves it false.
    quiet: bool = false,
    /// The canonical working directory every PATH is made relative to. Empty leaves an absolute
    /// PATH absolute.
    working_directory: []const u8 = "",

    pub fn lint_path(self: *Run, comptime rules: anytype, argument: []const u8) !void {
        const io = self.context.io;
        const arena = self.context.arena;
        const path = paths.resolve_argument(arena, io, self.working_directory, argument);
        const stat = Io.Dir.cwd().statFile(io, path, .{}) catch |failure| {
            return self.file_error(path, @errorName(failure));
        };
        if (stat.kind != .directory) return self.lint_file(rules, path);
        var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |failure| {
            return self.file_error(path, @errorName(failure));
        };
        defer dir.close(io);
        try self.walk_directory(rules, dir, path);
    }

    /// Visits every regular file under `dir`, reported under `root/...`, entering every directory
    /// but the skipped ones.
    pub fn walk_directory(
        self: *Run,
        comptime rules: anytype,
        dir: Io.Dir,
        root: []const u8,
    ) !void {
        var walker = try dir.walkSelectively(self.context.arena);
        defer walker.deinit();
        var path_buffer: [max_path_bytes]u8 = undefined;
        while (try walker.next(self.context.io)) |entry| {
            switch (entry.kind) {
                .directory => if (!is_skipped_directory(entry.basename)) {
                    try walker.enter(self.context.io, entry);
                },
                .file => {
                    const joined = paths.join(&path_buffer, root, entry.path) catch {
                        return self.file_error(entry.path, "PathTooLong");
                    };
                    try self.lint_file(rules, joined);
                },
                else => {},
            }
        }
    }

    fn lint_file(self: *Run, comptime rules: anytype, path: []const u8) !void {
        self.files_seen += 1;
        if (self.files_seen > max_files_per_run) return error.TooManyFiles;
        const arena = self.context.arena;
        const source = self.context.read_file(path) orelse {
            return self.file_error(path, "Unreadable");
        };
        defer arena.free(source);
        var tree: Ast = undefined;
        var tree_pointer: ?*const Ast = null;
        if (paths.has_extension(path, paths.zig_extension)) {
            tree = try Ast.parse(arena, source, .zig);
            if (tree.errors.len == 0) {
                tree_pointer = &tree;
            } else {
                try self.report_parse_error(path, &tree);
            }
        }
        defer if (tree_pointer != null) tree.deinit(arena);
        try self.dispatch(rules, .{ .path = path, .source = source, .tree = tree_pointer });
    }

    pub fn dispatch(self: *Run, comptime rules: anytype, file: report.File) !void {
        inline for (rules, 0..) |rule, index| {
            if (self.enabled[index]) try rule.check(&self.context, file);
        }
    }

    /// The first parse error, at its token, as the `parse` pseudo-rule.
    fn report_parse_error(self: *Run, path: []const u8, tree: *const Ast) !void {
        const first = tree.errors[0];
        var message_buffer: [max_parse_error_bytes]u8 = undefined;
        var writer: Io.Writer = .fixed(&message_buffer);
        tree.renderError(first, &writer) catch {};
        const location = tree.tokenLocation(0, first.token);
        try self.context.findings.add(
            parse_rule_name,
            path,
            location.line + 1,
            location.column + 1,
            "{s}",
            .{writer.buffered()},
        );
    }

    /// Counts a file the rules could not read, and prints it unless the caller asked for silence.
    /// A test drives `lint_path` over a deliberately missing path and passes; printing there would
    /// put the run under `zig build`'s "failed command" heading on a green run, which is how a
    /// real failure gets lost in the noise.
    fn file_error(self: *Run, path: []const u8, reason: []const u8) void {
        self.file_errors += 1;
        if (self.quiet) return;
        var line_buffer: [max_file_error_line_bytes]u8 = undefined;
        var line: Io.Writer = .fixed(&line_buffer);
        write_file_error(&line, path, reason) catch {};
        std.debug.print("{s}", .{line.buffered()});
    }
};

/// Writes the line for a file the walk cannot read: `path: error: [unreadable] reason`.
pub fn write_file_error(out: *Io.Writer, path: []const u8, reason: []const u8) !void {
    const location: report_line.Location = .{ .source = path };
    try report_line.write(out, location, .@"error", unreadable_rule_name, "{s}", .{reason});
}

fn print_usage(comptime rules: anytype) void {
    std.debug.print("usage: lint [--rule NAME]... PATH...\nrules:", .{});
    inline for (rules) |rule| std.debug.print(" {s}", .{rule.name});
    std.debug.print("\n", .{});
}

fn run_main(comptime rules: anytype, init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const all_arguments = try init.minimal.args.toSlice(arena);
    if (all_arguments.len > max_arguments) return error.TooManyArguments;
    const arguments = if (all_arguments.len == 0) all_arguments else all_arguments[1..];
    const options = parse_arguments_for(rules, arena, arguments) catch |failure| {
        std.debug.print("error: {s}\n", .{@errorName(failure)});
        print_usage(rules);
        std.process.exit(exit_usage);
    };

    var run: Run = .{
        .context = .{ .arena = arena, .io = init.io, .findings = .{ .arena = arena } },
        .enabled = options.enabled,
        .working_directory = paths.canonical_working_directory(arena, init.io),
    };
    for (options.paths) |path| try run.lint_path(rules, path);
    run.context.findings.sort();

    var output_buffer: [output_buffer_bytes]u8 = undefined;
    // Streaming, not positional: a positional writer starts at offset 0 and overwrites earlier
    // output when standard output is redirected to a file.
    var writer = Io.File.stdout().writerStreaming(init.io, &output_buffer);
    try run.context.findings.write(&writer.interface);
    try writer.interface.flush();
    std.process.exit(exit_status(run.context.findings.count(), run.file_errors));
}

/// Refuses, at compile time, a rule set the driver cannot run: more rules than `max_rules`, a name
/// that is empty or not lowercase words joined by hyphens, or two rules sharing a name. `--rule`
/// looks rules up by name and the report prints it.
fn assert_rule_set(comptime rules: anytype) void {
    if (rules.len > max_rules) @compileError("more lint rules than max_rules");
    inline for (rules, 0..) |rule, index| {
        assert_rule_name_shape(rule.name);
        inline for (rules, 0..) |other, other_index| {
            if (other_index != index and std.mem.eql(u8, other.name, rule.name)) {
                @compileError("two lint rules share the name " ++ rule.name);
            }
        }
    }
}

fn assert_rule_name_shape(comptime rule_name: []const u8) void {
    if (rule_name.len == 0) @compileError("a lint rule has an empty name");
    for (rule_name) |byte| {
        if (!std.ascii.isLower(byte) and byte != '-') {
            @compileError("lint rule name is not lowercase words and hyphens: " ++ rule_name);
        }
    }
}

fn is_skipped_directory(basename: []const u8) bool {
    for (skipped_directories) |skipped| {
        if (std.mem.eql(u8, basename, skipped)) return true;
    }
    return false;
}

/// 0 when nothing was found and every file was read, else 1.
pub fn exit_status(finding_count: usize, file_errors: usize) u8 {
    return if (finding_count != 0 or file_errors != 0) exit_findings else exit_clean;
}

test {
    _ = @import("driver_test.zig");
}
