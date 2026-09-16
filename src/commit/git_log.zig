//! The commits of a `--range` run, read out of `git log`.
//!
//! `run_git_log` runs `git log --format=%H%x00%P%x00%B%x00 REV... --` and returns its standard
//! output. `split_commits` splits that output on NUL: three fields per commit, the sha, the
//! parents, and the raw message, with a newline between one commit's last field and the next
//! commit's sha. `%B` is the message the rules read; `%H` names the commit a finding came from;
//! `%P` makes a merge commit visible, and `is_merge` is how the linter skips one, because its
//! message is git's and not the author's.
//!
//! Any revision arguments git accepts work: `origin/main..HEAD`, or `SHA --not --remotes` for a
//! branch the remote has never seen.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The git command the linter runs, one argument per constant.
const git_program = "git";
const git_log_command = "log";
const git_log_format = "--format=%H%x00%P%x00%B%x00";

/// Ends the revision arguments, so a range is never read as a path.
const git_revision_terminator = "--";

/// The exit status git reports when the log succeeded.
const git_success: u8 = 0;

/// Bytes of git's error output the linter prints back.
const max_git_stderr_bytes: usize = 64 * 1024;

/// The byte git writes between the fields of one commit.
const field_separator: u8 = 0;

/// The bytes git writes between one commit's last field and the next commit's sha, trimmed off
/// the sha before it is read.
const record_separators = "\n\r";

/// Fields git writes per commit: the sha, the parents, and the message.
const fields_per_commit: usize = 3;

/// Parents that make a commit a merge.
const merge_parent_count: usize = 2;

/// One commit as `git log` wrote it.
pub const Commit = struct {
    sha: []const u8,
    /// The parent shas, separated by spaces; empty for the root commit.
    parents: []const u8,
    /// The raw message: subject, body and trailers.
    body: []const u8,
};

/// True when the commit has two or more parents.
pub fn is_merge(parents: []const u8) bool {
    var iterator = std.mem.tokenizeScalar(u8, parents, ' ');
    var count: usize = 0;
    while (iterator.next()) |_| {
        count += 1;
        if (count >= merge_parent_count) return true;
    }
    return false;
}

/// Splits `git log` output into commits. Reading stops at the first field group whose sha is
/// empty, which is the newline git writes after the last commit. More than `max_commits` commits
/// is an error, never a truncated run.
pub fn split_commits(arena: Allocator, output: []const u8, max_commits: usize) ![]const Commit {
    var fields: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, output, field_separator);
    while (iterator.next()) |field| {
        if (fields.items.len >= max_commits * fields_per_commit) return error.TooManyCommits;
        try fields.append(arena, field);
    }
    var commits: std.ArrayList(Commit) = .empty;
    var index: usize = 0;
    while (index + fields_per_commit <= fields.items.len) : (index += fields_per_commit) {
        const sha = std.mem.trim(u8, fields.items[index], record_separators);
        if (sha.len == 0) break;
        try commits.append(arena, .{
            .sha = sha,
            .parents = fields.items[index + 1],
            .body = fields.items[index + 2],
        });
    }
    return commits.items;
}

/// The standard output of the `git log` command `git_log_options` built for `revisions`, or an
/// error with git's own error output written to `errors`.
pub fn run_git_log(
    arena: Allocator,
    io: Io,
    options: std.process.RunOptions,
    revisions: []const []const u8,
    errors: *Io.Writer,
) ![]u8 {
    const result = try std.process.run(arena, io, options);
    const status = switch (result.term) {
        .exited => |code| code,
        else => return error.GitDidNotExit,
    };
    if (status != git_success) {
        const written = try std.mem.join(arena, " ", revisions);
        try errors.print("git log {s}: {s}", .{ written, result.stderr });
        return error.GitFailed;
    }
    return result.stdout;
}

/// The command `run_git_log` runs: `git log` over `revisions`, with its output capped.
pub fn git_log_options(
    arena: Allocator,
    revisions: []const []const u8,
    max_output_bytes: usize,
) !std.process.RunOptions {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ git_program, git_log_command, git_log_format });
    try argv.appendSlice(arena, revisions);
    try argv.append(arena, git_revision_terminator);
    return .{
        .argv = argv.items,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_git_stderr_bytes),
    };
}

// Tests.

const testing = std.testing;

/// The commit cap the tests below split with.
const test_max_commits: usize = 16;

test "is_merge counts the parents git wrote" {
    try testing.expect(!is_merge(""));
    try testing.expect(!is_merge("aaa"));
    try testing.expect(is_merge("aaa bbb"));
    try testing.expect(is_merge("aaa bbb ccc"));
}

/// The output git writes for two commits: fields separated by NUL, and a newline between one
/// commit's last field and the next commit's sha.
pub const two_commit_log =
    "aaa\x00" ++ "ppp\x00" ++ "feat(store): add the page cache\n\x00" ++
    "\nbbb\x00" ++ "\x00" ++ "fix(net): reject an empty frame\n\x00" ++ "\n";

test "split_commits reads three fields per commit and stops at the trailing newline" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const commits = try split_commits(arena_state.allocator(), two_commit_log, test_max_commits);
    try testing.expectEqual(2, commits.len);
    try testing.expectEqualStrings("aaa", commits[0].sha);
    try testing.expectEqualStrings("ppp", commits[0].parents);
    try testing.expectEqualStrings("feat(store): add the page cache\n", commits[0].body);
    try testing.expectEqualStrings("bbb", commits[1].sha);
    try testing.expectEqualStrings("", commits[1].parents);
    try testing.expectEqualStrings("fix(net): reject an empty frame\n", commits[1].body);
}

test "split_commits reads empty output as no commit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const commits = try split_commits(arena_state.allocator(), "", test_max_commits);
    try testing.expectEqual(0, commits.len);
}

test "split_commits refuses output over max_commits, never truncating the run" {
    // The cap counts fields, and the newline git writes after the last commit is a seventh field
    // here. So two commits need a cap of three: the cap errs early by that one field.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(2, (try split_commits(arena, two_commit_log, 3)).len);
    try testing.expectError(error.TooManyCommits, split_commits(arena, two_commit_log, 2));
}

test "git_log_options runs git log over the revisions, ended by --, with the output capped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const revisions = [_][]const u8{ "abc123", "--not", "--remotes" };
    const options = try git_log_options(arena_state.allocator(), &revisions, 512);
    const want = [_][]const u8{
        "git", "log", "--format=%H%x00%P%x00%B%x00", "abc123", "--not", "--remotes", "--",
    };
    try testing.expectEqual(want.len, options.argv.len);
    for (want, options.argv) |expected, actual| try testing.expectEqualStrings(expected, actual);
    try testing.expectEqual(std.Io.Limit.limited(512), options.stdout_limit);
}

test "run_git_log reports a git log that exited non-zero as an error, not as output" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // git refuses an option it does not know, in a repository or outside one.
    const revisions = [_][]const u8{"--no-such-option-of-git-log"};
    const options = try git_log_options(arena, &revisions, 4096);
    var buffer: [4096]u8 = undefined;
    var errors: Io.Writer = .fixed(&buffer);
    const result = run_git_log(arena, testing.io, options, &revisions, &errors);
    if (result) |_| {
        return error.TestExpectedError;
    } else |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => try testing.expectEqual(error.GitFailed, err),
    }
    const written = errors.buffered();
    try testing.expect(std.mem.startsWith(u8, written, "git log --no-such-option-of-git-log: "));
}
