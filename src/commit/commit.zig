//! The commit-message linter: Conventional Commit rules a project configures, run over the commits
//! git lists for a revision range or over one message file.
//!
//! A project's entry point states its configuration and forwards `main`:
//!
//! ```zig
//! const config: pepegrillo.commit.Config = .{
//!     .scope_admits_digits = false,
//!     .third_person_forms = &.{ "adds", "fixes" },
//!     .imperative_exceptions = &.{ "embed", "bring" },
//! };
//! pub fn main(init: std.process.Init) !void {
//!     return pepegrillo.commit.main(init, config);
//! }
//! ```
//!
//! Run:  commit_lint --range REV [REV...]
//!       commit_lint --message PATH
//!
//! `--range` lints every non-merge commit `git log` lists for the revision arguments
//! (`git_log.zig`). `--message PATH` lints the one message in that file, the file a git hook is
//! handed, with the `#` lines git's editor template writes dropped first.
//!
//! One line per finding, in the order the rules of `rules.zig` ran, in the shape `report_line.zig`
//! defines, with `error` for a violation and `warning` for a warning:
//!
//!     source: error: [rule-name] message
//!
//! Exit status: 0 when no rule was violated, warnings included; 1 when any rule was violated; 2 on
//! a usage error, a message file that cannot be read, or a git log that failed. A pre-push hook
//! reads the difference: it refuses a push on 1 and reports a broken linter on 2.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Context = @import("../context.zig").Context;

const arguments = @import("arguments.zig");
const config = @import("config.zig");
const findings = @import("findings.zig");
const git_log = @import("git_log.zig");
const message = @import("message.zig");
const rules = @import("rules.zig");
const subject = @import("subject.zig");

pub const Config = config.Config;
pub const Finding = findings.Finding;
pub const Findings = findings.Findings;
pub const check_config = config.check_config;
pub const commit_types_default = config.commit_types_default;
pub const trailer_keys_default = config.trailer_keys_default;

/// Command-line arguments the linter reads before giving up.
const arguments_max: usize = 1024;

/// Bytes buffered for standard output before a flush.
const output_buffer_len: usize = 16 * 1024;

/// Bytes buffered for standard error before a flush.
const error_buffer_len: usize = 4 * 1024;

pub const exit_clean: u8 = 0;
pub const exit_violations: u8 = 1;
pub const exit_usage: u8 = 2;

/// Runs every rule over every non-merge commit of `git log` output.
pub fn lint_commits(
    arena: Allocator,
    comptime project: Config,
    results: *Findings,
    output: []const u8,
) !void {
    for (try git_log.split_commits(arena, output, project.commits_per_run_max)) |commit| {
        if (git_log.is_merge(commit.parents)) continue;
        const parsed = try parse(arena, project, commit.body);
        try rules.check_all(project, results, commit.sha, &parsed);
    }
}

/// Runs every rule over the text of one message file, with the `#` lines dropped first.
pub fn lint_message_text(
    arena: Allocator,
    comptime project: Config,
    results: *Findings,
    path: []const u8,
    text: []const u8,
) !void {
    const stripped = try message.strip_comments(arena, text);
    const parsed = try parse(arena, project, stripped);
    try rules.check_all(project, results, path, &parsed);
}

fn parse(arena: Allocator, comptime project: Config, text: []const u8) !message.Message {
    return message.parse(arena, text, project.trailer_keys, project.message_lines_max);
}

/// The exit status a run with these findings ends with.
fn exit_status(results: *const Findings) u8 {
    return if (results.count_errors() == 0) exit_clean else exit_violations;
}

fn lint_message_file(
    arena: Allocator,
    io: Io,
    comptime project: Config,
    results: *Findings,
    path: []const u8,
) !void {
    const limit: Io.Limit = .limited(project.message_len_max);
    const text = try Io.Dir.cwd().readFileAllocOptions(io, path, arena, limit, .of(u8), null);
    try lint_message_text(arena, project, results, path, text);
}

fn lint(
    arena: Allocator,
    io: Io,
    comptime project: Config,
    results: *Findings,
    options: arguments.Options,
    errors: *Io.Writer,
) !void {
    switch (options.input) {
        .message => |path| try lint_message_file(arena, io, project, results, path),
        .range => |revisions| {
            const command = try range_command(arena, project, revisions);
            const output = try git_log.run_git_log(arena, io, command, revisions, errors);
            try lint_commits(arena, project, results, output);
        },
    }
}

/// The command `--range` runs: `git log` over the revisions, its output capped at the project's
/// `git_output_len_max`.
fn range_command(
    arena: Allocator,
    comptime project: Config,
    revisions: []const []const u8,
) !std.process.RunOptions {
    return git_log.git_log_options(arena, revisions, project.git_output_len_max);
}

/// One run over the command-line arguments, without the program name: every finding written to
/// `context.out`, and the exit status returned. A usage error or a failed lint writes no finding,
/// and writes what went wrong to `context.errors`.
pub fn run(context: *const Context, comptime project: Config, given: []const []const u8) !u8 {
    const errors = context.errors;
    const options = arguments.parse_arguments(given) catch |err| {
        try errors.print("error: {s}\n{s}", .{ @errorName(err), arguments.usage });
        return exit_usage;
    };
    var results: Findings = .{ .arena = context.arena, .findings_max = project.findings_max };
    lint(context.arena, context.io, project, &results, options, errors) catch |err| {
        try errors.print("error: {s}\n", .{@errorName(err)});
        return exit_usage;
    };
    try results.write(context.out);
    return exit_status(&results);
}

pub fn main(init: std.process.Init, comptime project: Config) !void {
    comptime if (check_config(project)) |reason| @compileError(reason);
    const arena = init.arena.allocator();
    const all_arguments = try init.minimal.args.toSlice(arena);
    if (all_arguments.len > arguments_max) return error.TooManyArguments;
    const given = if (all_arguments.len == 0) all_arguments else all_arguments[1..];
    var output_buffer: [output_buffer_len]u8 = undefined;
    var error_buffer: [error_buffer_len]u8 = undefined;
    // Streaming, not positional: a positional writer starts at offset 0 and overwrites earlier
    // output when standard output is redirected to a file.
    var out = Io.File.stdout().writerStreaming(init.io, &output_buffer);
    var errors = Io.File.stderr().writerStreaming(init.io, &error_buffer);
    const context: Context = .{ .arena = arena, .io = init.io, .environ = init.environ_map, .out = &out.interface, .errors = &errors.interface };
    const status = try run(&context, project, given);
    try errors.interface.flush();
    try out.interface.flush();
    std.process.exit(status);
}

// Tests. The rules have their own files; these pin the merge skip, the `--message` path, and the
// exit status.

const testing = std.testing;

test "the root exports these names alone" {
    try @import("../public_names.zig").expect(@This(), &.{
        "Config",               "Finding",              "Findings",
        "commit_types_default", "trailer_keys_default", "lint_commits",
        "lint_message_text",    "run",                  "main",
        "exit_clean",           "exit_violations",      "exit_usage",
        "check_config",
    });
}

test {
    _ = arguments;
    _ = config;
    _ = findings;
    _ = git_log;
    _ = message;
    _ = rules;
    _ = subject;
    _ = @import("rules_test.zig");
    _ = @import("rules_config_test.zig");
}

/// The configuration the tests below lint with: scopes admit digits, and no scope list.
const test_config: Config = .{
    .scope_admits_digits = true,
    .third_person_forms = &.{ "adds", "fixes" },
    .imperative_exceptions = &.{"embed"},
};

/// The configuration with a scope list, so a new scope draws a warning.
const scoped_config: Config = .{
    .scope_admits_digits = true,
    .known_scopes = &.{ "store", "net", "h2" },
    .third_person_forms = &.{ "adds", "fixes" },
    .imperative_exceptions = &.{"embed"},
};

test "lint_commits reports one line per finding, named by sha" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var results: Findings = .{ .arena = arena, .findings_max = test_config.findings_max };
    try lint_commits(arena, test_config, &results, "aaa\x00ppp\x00Adds the page cache.\n\x00\n");
    try testing.expectEqual(1, results.count());
    try testing.expectEqualStrings("aaa", results.items.items[0].source);
    try testing.expectEqualStrings(rules.subject_format_rule, results.items.items[0].rule);
    try testing.expectEqual(exit_violations, exit_status(&results));
}

test "lint_commits reports nothing for a conforming range" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var results: Findings = .{ .arena = arena, .findings_max = scoped_config.findings_max };
    try lint_commits(arena, scoped_config, &results, git_log.two_commit_log);
    try testing.expectEqual(0, results.count());
    try testing.expectEqual(exit_clean, exit_status(&results));
}

test "lint_commits skips a merge commit, whose message git wrote" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var results: Findings = .{ .arena = arena, .findings_max = test_config.findings_max };
    const log = "aaa\x00bbb ccc\x00Merge branch 'topic' into main\n\x00\n";
    try lint_commits(arena, test_config, &results, log);
    try testing.expectEqual(0, results.count());
}

test "the same merge message on one parent is not skipped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var results: Findings = .{ .arena = arena, .findings_max = test_config.findings_max };
    const log = "aaa\x00bbb\x00Merge branch 'topic' into main\n\x00\n";
    try lint_commits(arena, test_config, &results, log);
    try testing.expectEqual(1, results.count());
    try testing.expectEqualStrings(rules.subject_format_rule, results.items.items[0].rule);
}

test "a warning alone leaves the exit status clean" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var results: Findings = .{ .arena = arena, .findings_max = scoped_config.findings_max };
    const log = "aaa\x00ppp\x00feat(frobnicator): add the page cache\n\x00\n";
    try lint_commits(arena, scoped_config, &results, log);
    try testing.expectEqual(1, results.count());
    try testing.expectEqual(0, results.count_errors());
    try testing.expectEqualStrings(rules.scope_known_rule, results.items.items[0].rule);
    try testing.expectEqual(exit_clean, exit_status(&results));
}

test "lint_message_text drops the # lines git's editor template writes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var results: Findings = .{ .arena = arena, .findings_max = test_config.findings_max };
    const text = "feat(store): add the page cache\n# Please enter the commit message.\n";
    try lint_message_text(arena, test_config, &results, "COMMIT_EDITMSG", text);
    try testing.expectEqual(0, results.count());
}

test "lint_message_text names the path and keeps a # that does not open a line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var results: Findings = .{ .arena = arena, .findings_max = test_config.findings_max };
    const text = "feat(store): add the page cache\n #1 is the reason\n";
    try lint_message_text(arena, test_config, &results, "COMMIT_EDITMSG", text);
    try testing.expectEqual(1, results.count());
    try testing.expectEqualStrings("COMMIT_EDITMSG", results.items.items[0].source);
    try testing.expectEqualStrings(rules.body_separation_rule, results.items.items[0].rule);
}

test "lint_commits and lint_message_text parse with the configured trailer keys" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const change_ids = comptime blk: {
        var project = test_config;
        project.trailer_keys = &.{"Change-Id"};
        break :blk project;
    };
    const text = "feat: add x\n\none\n\ntwo\n\nthree\n\nChange-Id: I0123\n";
    var results: Findings = .{ .arena = arena, .findings_max = test_config.findings_max };
    try lint_message_text(arena, change_ids, &results, "COMMIT_EDITMSG", text);
    const log = try std.fmt.allocPrint(arena, "aaa\x00ppp\x00{s}\x00\n", .{text});
    try lint_commits(arena, change_ids, &results, log);
    try testing.expectEqual(0, results.count());
    try lint_message_text(arena, test_config, &results, "COMMIT_EDITMSG", text);
    try testing.expectEqual(1, results.count());
    try testing.expectEqualStrings(rules.body_size_rule, results.items.items[0].rule);
}

test "message_lines_max and commits_per_run_max are the caps lint_commits reads" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var results: Findings = .{ .arena = arena, .findings_max = test_config.findings_max };
    const few_lines = comptime blk: {
        var project = test_config;
        project.message_lines_max = 1;
        break :blk project;
    };
    const two_lines = "aaa\x00ppp\x00feat: add x\n\nwhy\n\x00\n";
    const too_long = lint_commits(arena, few_lines, &results, two_lines);
    try testing.expectError(error.TooManyLines, too_long);
    const one_commit = comptime blk: {
        var project = test_config;
        project.commits_per_run_max = 1;
        break :blk project;
    };
    const log = git_log.two_commit_log;
    try testing.expectError(error.TooManyCommits, lint_commits(arena, one_commit, &results, log));
    try testing.expectEqual(0, results.count());
}

test "message_len_max is the size a message file must stay under" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    const text = "feat(store): add the page cache\n";
    try directory.dir.writeFile(testing.io, .{ .sub_path = "message", .data = text });
    const path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/message", .{directory.sub_path});
    var results: Findings = .{ .arena = arena, .findings_max = test_config.findings_max };
    const small = comptime blk: {
        var project = test_config;
        project.message_len_max = text.len;
        break :blk project;
    };
    const refused = lint_message_file(arena, testing.io, small, &results, path);
    try testing.expectError(error.StreamTooLong, refused);
    const large = comptime blk: {
        var project = test_config;
        project.message_len_max = text.len + 1;
        break :blk project;
    };
    try lint_message_file(arena, testing.io, large, &results, path);
    try testing.expectEqual(0, results.count());
}

test "range_command runs git log over the revisions with the project's output cap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const capped = comptime blk: {
        var project = test_config;
        project.git_output_len_max = 4096;
        break :blk project;
    };
    const revisions = [_][]const u8{"origin/main..HEAD"};
    const command = try range_command(arena_state.allocator(), capped, &revisions);
    try testing.expectEqual(Io.Limit.limited(4096), command.stdout_limit);
    try testing.expectEqualStrings("origin/main..HEAD", command.argv[command.argv.len - 2]);
}

test "run writes every finding and returns the exit status, and caps the findings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(testing.io, .{ .sub_path = "message", .data = "feat: Add x.\n" });
    const path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/message", .{directory.sub_path});
    const given = [_][]const u8{ "--message", path };
    var buffer: [512]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var error_buffer: [512]u8 = undefined;
    var errors: Io.Writer = .fixed(&error_buffer);
    var environ: std.process.Environ.Map = .init(arena);
    const context: Context = .{ .arena = arena, .io = testing.io, .environ = &environ, .out = &out, .errors = &errors };
    const status = try run(&context, test_config, &given);
    try testing.expectEqual(exit_violations, status);
    try testing.expectEqual(0, errors.buffered().len);
    const description_lines = ": error: [subject-description] ";
    try testing.expectEqual(2, std.mem.count(u8, out.buffered(), description_lines));
    const one_finding = comptime blk: {
        var project = test_config;
        project.findings_max = 1;
        break :blk project;
    };
    var capped_out: Io.Writer = .fixed(&buffer);
    var capped_errors: Io.Writer = .fixed(&error_buffer);
    var capped = context;
    capped.out = &capped_out;
    capped.errors = &capped_errors;
    const capped_status = try run(&capped, one_finding, &given);
    try testing.expectEqual(exit_usage, capped_status);
    try testing.expectEqual(0, capped_out.buffered().len);
    try testing.expectEqualStrings("error: TooManyFindings\n", capped_errors.buffered());
}

test "run returns the usage status for arguments it cannot read, and writes nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var buffer: [64]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var error_buffer: [256]u8 = undefined;
    var errors: Io.Writer = .fixed(&error_buffer);
    const given = [_][]const u8{"--rule"};
    const arena = arena_state.allocator();
    var environ: std.process.Environ.Map = .init(arena);
    const context: Context = .{ .arena = arena, .io = testing.io, .environ = &environ, .out = &out, .errors = &errors };
    const status = try run(&context, test_config, &given);
    try testing.expectEqual(exit_usage, status);
    try testing.expectEqual(0, out.buffered().len);
    const want = "error: UnknownArgument\n" ++ arguments.usage;
    try testing.expectEqualStrings(want, errors.buffered());
}
