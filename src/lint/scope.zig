//! Which files a rule reads. Every generic rule takes a `Scope` in its configuration and asks
//! `applies` before it reads a file, so a project states its directories, exemptions and file
//! kinds as data and never as code.
//!
//! A path is read when all three hold:
//!
//! 1. It is a file kind the rule reads: its path ends with one of `extensions`, or its basename is
//!    one of `basenames`.
//! 2. It is where the rule reads: under one of `include_directories` when that list is not empty,
//!    and directly inside a directory named in `parent_directory_names` when that list is not
//!    empty.
//! 3. No exclusion names it: `exclude_directories`, `exclude_paths`, `exclude_basenames`,
//!    `exclude_basename_suffixes`, and `exclude_stem_segment`.
//!
//! Directory and path matching goes through `paths.zig`, so it compares whole components.

const std = @import("std");
const paths = @import("paths.zig");

pub const Scope = struct {
    /// A file whose path ends with one of these is a file kind the rule reads.
    extensions: []const []const u8 = &.{},
    /// A file whose basename is one of these is read whatever its extension.
    basenames: []const []const u8 = &.{},
    /// When not empty, only a file under one of these directories is read.
    include_directories: []const []const u8 = &.{},
    /// When not empty, only a file whose parent directory has one of these names is read, so
    /// `docs` reads `docs/design.md` and `./docs/design.md` and not `docs/notes/meeting.md`.
    parent_directory_names: []const []const u8 = &.{},
    /// A file under one of these directories is not read.
    exclude_directories: []const []const u8 = &.{},
    /// A file whose path ends with one of these, at a component boundary, is not read.
    exclude_paths: []const []const u8 = &.{},
    /// A file whose basename is one of these is not read.
    exclude_basenames: []const []const u8 = &.{},
    /// A file whose basename ends with one of these is not read: `_test.zig`.
    exclude_basename_suffixes: []const []const u8 = &.{},
    /// When set, a file whose stem ends with this segment, or holds it followed by `_`, is not
    /// read. The stem is the basename without its last extension, so `_test` excludes
    /// `journal_test.zig` and the pieces split from it, such as `journal_test_torn.zig`.
    exclude_stem_segment: ?[]const u8 = null,

    pub fn applies(self: *const Scope, path: []const u8) bool {
        if (!self.is_file_kind(path)) return false;
        if (!self.is_included(path)) return false;
        return !self.is_excluded(path);
    }

    fn is_file_kind(self: *const Scope, path: []const u8) bool {
        if (has_any_extension(path, self.extensions)) return true;
        return is_any_of(paths.basename(path), self.basenames);
    }

    fn is_included(self: *const Scope, path: []const u8) bool {
        const directories = self.include_directories;
        if (directories.len != 0 and !paths.is_under_any(path, directories)) return false;
        if (self.parent_directory_names.len == 0) return true;
        return is_any_of(paths.parent_basename(path), self.parent_directory_names);
    }

    fn is_excluded(self: *const Scope, path: []const u8) bool {
        const basename = paths.basename(path);
        if (paths.is_under_any(path, self.exclude_directories)) return true;
        if (paths.ends_with_any_path(path, self.exclude_paths)) return true;
        if (is_any_of(basename, self.exclude_basenames)) return true;
        if (has_any_extension(basename, self.exclude_basename_suffixes)) return true;
        const segment = self.exclude_stem_segment orelse return false;
        return stem_holds_segment(basename, segment);
    }
};

fn has_any_extension(path: []const u8, suffixes: []const []const u8) bool {
    for (suffixes) |suffix| {
        if (paths.has_extension(path, suffix)) return true;
    }
    return false;
}

fn is_any_of(name: []const u8, names: []const []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

/// True when the basename's stem is `<name><segment>` or `<name><segment>_<part>`.
fn stem_holds_segment(basename: []const u8, segment: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse basename.len;
    const stem = basename[0..dot];
    if (std.mem.endsWith(u8, stem, segment)) return true;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, stem, search_from, segment)) |index| {
        const after = index + segment.len;
        if (after < stem.len and stem[after] == '_') return true;
        search_from = index + 1;
    }
    return false;
}

// Tests.

const testing = std.testing;

test "a scope with extensions alone reads every file of that kind" {
    const scope: Scope = .{ .extensions = &.{ ".zig", ".sh" } };
    try testing.expect(scope.applies("src/store/page.zig"));
    try testing.expect(scope.applies("tools/run.sh"));
    try testing.expect(!scope.applies("docs/design.md"));
}

test "basenames read a file whatever its extension" {
    const scope: Scope = .{ .extensions = &.{".zig"}, .basenames = &.{"Makefile"} };
    try testing.expect(scope.applies("./Makefile"));
    try testing.expect(!scope.applies("./Makefile.old"));
}

test "include_directories and parent_directory_names narrow where the rule reads" {
    const included: Scope = .{
        .extensions = &.{".zig"},
        .include_directories = &.{ "src", "build" },
    };
    try testing.expect(included.applies("./src/store/page.zig"));
    try testing.expect(included.applies("build/modules.zig"));
    try testing.expect(!included.applies("tools/lint.zig"));
    try testing.expect(!included.applies("build.zig"));

    const documents: Scope = .{ .extensions = &.{".md"}, .parent_directory_names = &.{"docs"} };
    try testing.expect(documents.applies("./docs/design.md"));
    try testing.expect(!documents.applies("docs/notes/meeting.md"));
    try testing.expect(!documents.applies("README.md"));
}

test "each exclusion removes the files it names" {
    const scope: Scope = .{
        .extensions = &.{".zig"},
        .exclude_directories = &.{"tools"},
        .exclude_paths = &.{"src/golden/golden.zig"},
        .exclude_basenames = &.{"constants.zig"},
        .exclude_basename_suffixes = &.{"_fuzz.zig"},
    };
    try testing.expect(scope.applies("src/store/page.zig"));
    try testing.expect(!scope.applies("tools/lint.zig"));
    try testing.expect(!scope.applies("./src/golden/golden.zig"));
    try testing.expect(scope.applies("src/notgolden/golden.zig"));
    try testing.expect(!scope.applies("src/store/constants.zig"));
    try testing.expect(!scope.applies("src/store/page_fuzz.zig"));
}

test "exclude_stem_segment removes a test file and the pieces split from it" {
    const scope: Scope = .{ .extensions = &.{".zig"}, .exclude_stem_segment = "_test" };
    try testing.expect(!scope.applies("src/store/journal_test.zig"));
    try testing.expect(!scope.applies("src/store/journal_test_torn.zig"));
    try testing.expect(scope.applies("src/store/journal_testing.zig"));
    try testing.expect(scope.applies("src/store/journal.zig"));
}
