//! The configuration a project hands the commit-message linter: the subject grammar it accepts,
//! the first words it refuses as not imperative, the trailer keys, the limits on the subject and
//! the body, and the capacity caps of one run.
//!
//! A field with a default holds a value the linter's first projects shared. A field with no
//! default is one on which they differed, so every project states it.
//!
//! `invalid_reason` names a configuration no message could be judged under. `commit.main` checks
//! it at compile time, so such a configuration does not build.

const std = @import("std");
const Severity = @import("findings.zig").Severity;

/// The Conventional Commit types a subject may name when a project states none.
pub const default_commit_types = [_][]const u8{
    "feat", "fix", "docs", "test", "refactor", "perf", "build", "ci", "chore",
};

/// The trailer keys a final `Key: value` paragraph may name when a project states none.
pub const default_trailer_keys = [_][]const u8{
    "Co-Authored-By", "Signed-off-by", "Reviewed-by", "Refs", "Closes",
};

/// The words the `scope-known` finding prints after an unknown scope when a project states none.
pub const default_unknown_scope_reason = "is not one of the known scopes";

/// The most columns a subject line may occupy.
pub const default_max_subject_columns: usize = 72;

/// The most columns a body line may occupy.
pub const default_max_body_columns: usize = 100;

/// The most paragraphs a body may hold.
pub const default_max_body_paragraphs: usize = 3;

/// The most words a body may hold.
pub const default_max_body_words: usize = 100;

/// The most blank lines a message may end with.
pub const default_max_trailing_blank_lines: usize = 1;

/// Findings one run may record. One more is an error, never a dropped finding.
pub const default_max_findings: usize = 65536;

/// Lines one message may hold. A longer message is an error, never a truncated read.
pub const default_max_message_lines: usize = 4096;

/// Commits one `--range` run may hold. More is an error, never a truncated run.
pub const default_max_commits_per_run: usize = 65536;

/// Bytes of one `--message` file the linter reads.
pub const default_max_message_bytes: usize = 1024 * 1024;

/// Bytes of `git log` output the linter reads.
pub const default_max_git_output_bytes: usize = 64 * 1024 * 1024;

pub const Config = struct {
    /// The closed set of types a subject may name.
    commit_types: []const []const u8 = &default_commit_types,
    /// Whether a scope may hold ASCII digits beside lowercase letters and hyphens, so that `h2` is
    /// a well-formed scope. Uppercase and every other byte is refused either way.
    scope_admits_digits: bool,
    /// The scopes the project names. A well-formed scope outside this set draws a `scope-known`
    /// finding of `unknown_scope_severity`. Null turns the rule off: every well-formed scope
    /// passes.
    known_scopes: ?[]const []const u8 = null,
    /// The words the `scope-known` finding prints, as
    /// `the scope "NAME" <unknown_scope_reason> (KNOWN, SCOPES)`.
    unknown_scope_reason: []const u8 = default_unknown_scope_reason,
    /// Whether an unknown scope refuses the commit or is only reported.
    unknown_scope_severity: Severity = .warning,
    /// First words that describe the commit instead of commanding it: `adds`, `fixes`.
    third_person_forms: []const []const u8,
    /// Commands whose spelling ends in `ed` or `ing` all the same: `embed`, `bring`. The suffix
    /// test reads the end of a word and not its grammar, so without this list it refuses them.
    imperative_exceptions: []const []const u8,
    /// The closed set of keys a trailer line may name, matched without regard to case. A final
    /// paragraph of `Key: value` lines naming anything else is body, counted by the body rules.
    trailer_keys: []const []const u8 = &default_trailer_keys,
    max_subject_columns: usize = default_max_subject_columns,
    max_body_columns: usize = default_max_body_columns,
    max_body_paragraphs: usize = default_max_body_paragraphs,
    max_body_words: usize = default_max_body_words,
    max_trailing_blank_lines: usize = default_max_trailing_blank_lines,
    max_findings: usize = default_max_findings,
    max_message_lines: usize = default_max_message_lines,
    max_commits_per_run: usize = default_max_commits_per_run,
    max_message_bytes: usize = default_max_message_bytes,
    max_git_output_bytes: usize = default_max_git_output_bytes,
};

/// Why no message could be judged under `config`, or null when it is usable.
pub fn invalid_reason(config: *const Config) ?[]const u8 {
    if (config.commit_types.len == 0) return "commit_types is empty, so every subject is refused";
    if (config.max_findings == 0) return "max_findings is 0, so the first finding is an error";
    if (config.max_message_lines == 0) return "max_message_lines is 0, so no message is read";
    if (config.max_commits_per_run == 0) return "max_commits_per_run is 0, so no range is read";
    const known = config.known_scopes orelse return null;
    if (known.len == 0) return "known_scopes is empty; use null to accept every well-formed scope";
    return null;
}

// Tests.

const testing = std.testing;

/// A configuration with every required field stated and every default kept.
const usable: Config = .{
    .scope_admits_digits = false,
    .third_person_forms = &.{"adds"},
    .imperative_exceptions = &.{"embed"},
};

test "a configuration with the defaults is usable" {
    try testing.expectEqual(null, invalid_reason(&usable));
    var with_scopes = usable;
    with_scopes.known_scopes = &.{"store"};
    try testing.expectEqual(null, invalid_reason(&with_scopes));
}

test "invalid_reason names each configuration no message could be judged under" {
    var no_types = usable;
    no_types.commit_types = &.{};
    try testing.expect(invalid_reason(&no_types) != null);
    var no_findings = usable;
    no_findings.max_findings = 0;
    try testing.expect(invalid_reason(&no_findings) != null);
    var no_lines = usable;
    no_lines.max_message_lines = 0;
    try testing.expect(invalid_reason(&no_lines) != null);
    var no_commits = usable;
    no_commits.max_commits_per_run = 0;
    try testing.expect(invalid_reason(&no_commits) != null);
    var no_scopes = usable;
    no_scopes.known_scopes = &.{};
    try testing.expect(invalid_reason(&no_scopes) != null);
}
