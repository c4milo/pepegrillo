//! Path predicates the rules filter files by. Every rule states its own directories and exempt
//! paths as named constants and asks these functions whether a path falls under them.
//!
//! Paths arrive as the walk built them: the PATH argument, made relative to the working directory
//! by `resolve_argument`, joined with the entry's relative path by one `/`. `zig build` hands a
//! tool absolute paths, or `./`-prefixed ones when the step sets a working directory, and both
//! arrive as `src/...`. A PATH outside the working directory stays absolute. The predicates compare
//! whole path components, never raw prefixes, so `src/testing/endpoint.zig` is under
//! `src/testing/` and `mysrc/testing/endpoint.zig` is not.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const separator: u8 = '/';

/// The extension of a Zig source file, the files the AST rules read.
pub const zig_extension = ".zig";

pub fn has_extension(path: []const u8, extension: []const u8) bool {
    return std.mem.endsWith(u8, path, extension);
}

/// The last component of the path.
pub fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, separator) orelse return path;
    return path[slash + 1 ..];
}

/// The path without its last component and the separator before it, or empty when the path is a
/// bare name.
pub fn dirname(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, separator) orelse return "";
    return path[0..slash];
}

/// The basename of the directory holding the path, or empty for a bare name.
pub fn parent_basename(path: []const u8) []const u8 {
    return basename(dirname(path));
}

/// True when `directory`, given as components such as `src/testing`, occurs as consecutive whole
/// components of the path's directory part. A trailing separator on `directory` is ignored, so
/// `src/testing/` and `src/testing` agree.
pub fn is_under(path: []const u8, directory: []const u8) bool {
    const wanted = std.mem.trimEnd(u8, directory, "/");
    const directories = dirname(path);
    var start: usize = 0;
    while (start <= directories.len) {
        const remaining = directories[start..];
        if (std.mem.startsWith(u8, remaining, wanted) and
            (remaining.len == wanted.len or remaining[wanted.len] == separator))
        {
            return true;
        }
        const slash = std.mem.indexOfScalar(u8, remaining, separator) orelse return false;
        start += slash + 1;
    }
    return false;
}

/// True when the path is under any of the listed directories.
pub fn is_under_any(path: []const u8, directories: []const []const u8) bool {
    for (directories) |directory| {
        if (is_under(path, directory)) return true;
    }
    return false;
}

/// True when the path is exactly `suffix` or ends with a separator followed by `suffix`, so
/// `build/modules.zig` matches `./build/modules.zig` and not `notbuild/modules.zig`.
pub fn ends_with_path(path: []const u8, suffix: []const u8) bool {
    if (std.mem.eql(u8, path, suffix)) return true;
    if (path.len <= suffix.len) return false;
    return std.mem.endsWith(u8, path, suffix) and path[path.len - suffix.len - 1] == separator;
}

/// True when the path ends with any of the listed paths.
pub fn ends_with_any_path(path: []const u8, suffixes: []const []const u8) bool {
    for (suffixes) |suffix| {
        if (ends_with_path(path, suffix)) return true;
    }
    return false;
}

/// The path with `suffix` removed from its end, or the whole path when it does not end there.
/// `build/modules.zig` with `build/modules.zig` removed is the empty string, and
/// `/home/me/project/build/modules.zig` becomes `/home/me/project/`.
pub fn without_suffix(path: []const u8, suffix: []const u8) []const u8 {
    if (!std.mem.endsWith(u8, path, suffix)) return path;
    return path[0 .. path.len - suffix.len];
}

/// The directory a relative path is read from when it names no directory of its own.
pub const current_directory = ".";

/// The prefix that names the current directory in front of a path.
const current_directory_prefix = "./";

/// Writes `root/relative` into `buffer` with exactly one separator between them: trailing
/// separators on `root` are dropped first, so a directory argument given as `src/` reports
/// `src/core/core.zig` and not `src//core/core.zig`. A root of `.` adds nothing, so walking the
/// working directory reports `src/core/core.zig` and not `./src/core/core.zig`.
pub fn join(buffer: []u8, root: []const u8, relative: []const u8) ![]const u8 {
    const trimmed_root = std.mem.trimEnd(u8, root, "/");
    if (std.mem.eql(u8, trimmed_root, current_directory)) {
        return std.fmt.bufPrint(buffer, "{s}", .{relative});
    }
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ trimmed_root, relative });
}

/// `path` relative to `working_directory`, an absolute path, when it lies under it, and with every
/// leading `./` removed. A path that is the working directory, or `./` alone, is `.`. An absolute
/// path outside the working directory, and an empty `working_directory`, leave it absolute.
pub fn relative_to(working_directory: []const u8, path: []const u8) []const u8 {
    var relative = path;
    const directory = std.mem.trimEnd(u8, working_directory, "/");
    if (working_directory.len != 0 and relative.len != 0 and relative[0] == separator) {
        const trimmed = std.mem.trimEnd(u8, relative, "/");
        if (std.mem.eql(u8, trimmed, directory)) return current_directory;
        if (std.mem.startsWith(u8, relative, directory) and relative.len > directory.len and
            relative[directory.len] == separator)
        {
            relative = relative[directory.len + 1 ..];
        }
    }
    while (std.mem.startsWith(u8, relative, current_directory_prefix)) {
        relative = std.mem.trimStart(u8, relative[current_directory_prefix.len..], "/");
    }
    return if (relative.len == 0) current_directory else relative;
}

/// The canonical absolute path of the working directory, or empty when the platform cannot say.
/// An empty working directory leaves every absolute PATH absolute.
pub fn canonical_working_directory(arena: Allocator, io: Io) []const u8 {
    return Io.Dir.cwd().realPathFileAlloc(io, current_directory, arena) catch "";
}

/// A PATH argument as the walk and the rules see it: `relative_to` the working directory. An
/// absolute PATH that names the working directory through a symbolic link, such as `/tmp` for
/// `/private/tmp`, is compared again by its canonical path.
pub fn resolve_argument(
    arena: Allocator,
    io: Io,
    directory: []const u8,
    argument: []const u8,
) []const u8 {
    const relative = relative_to(directory, argument);
    if (directory.len == 0 or relative.len == 0 or relative[0] != separator) return relative;
    const canonical = Io.Dir.cwd().realPathFileAlloc(io, argument, arena) catch return relative;
    const canonical_relative = relative_to(directory, canonical);
    return if (canonical_relative[0] == separator) relative else canonical_relative;
}

// Tests.

const testing = std.testing;

test "basename, dirname and parent_basename split at the last separator" {
    try testing.expectEqualStrings("core.zig", basename("src/core/core.zig"));
    try testing.expectEqualStrings("core.zig", basename("core.zig"));
    try testing.expectEqualStrings("src/core", dirname("src/core/core.zig"));
    try testing.expectEqualStrings("", dirname("core.zig"));
    try testing.expectEqualStrings("core", parent_basename("src/core/core.zig"));
    try testing.expectEqualStrings("docs", parent_basename("./docs/design.md"));
    try testing.expectEqualStrings("", parent_basename("README.md"));
}

test "is_under matches whole components anywhere in the directory part" {
    try testing.expect(is_under("src/testing/endpoint.zig", "src/testing/"));
    try testing.expect(is_under("./src/testing/endpoint.zig", "src/testing"));
    try testing.expect(is_under("/home/me/project/src/net/packet/header.zig", "src/net"));
    try testing.expect(is_under("tools/lint.zig", "tools"));
    try testing.expect(!is_under("mysrc/testing/endpoint.zig", "src/testing"));
    try testing.expect(!is_under("src/testingx/endpoint.zig", "src/testing"));
    try testing.expect(!is_under("src/testing", "src/testing"));
    try testing.expect(!is_under("core.zig", "tools"));
}

test "ends_with_path needs a separator before the suffix" {
    try testing.expect(ends_with_path("build/modules.zig", "build/modules.zig"));
    try testing.expect(ends_with_path("./build/modules.zig", "build/modules.zig"));
    try testing.expect(!ends_with_path("notbuild/modules.zig", "build/modules.zig"));
    try testing.expect(!ends_with_path("modules.zig", "build/modules.zig"));
    const suffixes = [_][]const u8{ "a.zig", "build/modules.zig" };
    try testing.expect(ends_with_any_path("./build/modules.zig", &suffixes));
    try testing.expect(!ends_with_any_path("./build/modules.zig", &.{"a.zig"}));
}

test "without_suffix removes the suffix it finds and nothing else" {
    try testing.expectEqualStrings("", without_suffix("build/modules.zig", "build/modules.zig"));
    const suffix = "build/modules.zig";
    try testing.expectEqualStrings("./", without_suffix("./build/modules.zig", suffix));
    try testing.expectEqualStrings("a/b.zig", without_suffix("a/b.zig", "c.zig"));
}

test "join drops trailing separators from the root" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("src/core.zig", try join(&buffer, "src", "core.zig"));
    try testing.expectEqualStrings("src/core.zig", try join(&buffer, "src//", "core.zig"));
    try testing.expectEqualStrings("/core.zig", try join(&buffer, "/", "core.zig"));
    try testing.expectEqualStrings("core.zig", try join(&buffer, ".", "core.zig"));
    try testing.expectEqualStrings("core.zig", try join(&buffer, "./", "core.zig"));
    var short: [4]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, join(&short, "src", "core.zig"));
}

/// Checks that `relative_to` makes `path` into `expected` against `directory`.
fn expect_relative(expected: []const u8, directory: []const u8, path: []const u8) !void {
    try testing.expectEqualStrings(expected, relative_to(directory, path));
}

/// The working directory the `relative_to` tests read against.
const home = "/home/me/project";

test "relative_to strips the working directory and every leading ./" {
    try expect_relative("src/store/page.zig", home, "/home/me/project/src/store/page.zig");
    try expect_relative("src", "/home/me/project/", "/home/me/project/src");
    try expect_relative("src/store", home, "./src/store");
    try expect_relative("src", home, "././/src");
    try expect_relative("src", "", "./src");
    try expect_relative(".", home, "/home/me/project/");
    try expect_relative(".", home, "./");
    try expect_relative("tools", home, "tools");
}

test "relative_to leaves a path outside the working directory absolute" {
    try expect_relative("/home/me/projects/src", home, "/home/me/projects/src");
    try expect_relative("/etc/hosts", home, "/etc/hosts");
    try expect_relative("/home/me/project/src", "", "/home/me/project/src");
    try expect_relative("../other/src", home, "../other/src");
}

test "resolve_argument reads a PATH through a symbolic link by its canonical path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project/src");
    try tmp.dir.symLink(io, "project", "link", .{ .is_directory = true });

    const working = canonical_working_directory(arena, io);
    const tmp_path = try std.fmt.allocPrint(arena, "{s}/.zig-cache/tmp/{s}", .{
        working, tmp.sub_path,
    });
    // The project directory stands in for the working directory, reached through `link`.
    const project = try std.fmt.allocPrint(arena, "{s}/project", .{tmp_path});
    const through_link = try std.fmt.allocPrint(arena, "{s}/link/src", .{tmp_path});
    try testing.expectEqualStrings("src", resolve_argument(arena, io, project, through_link));
    const outside = try std.fmt.allocPrint(arena, "{s}/elsewhere", .{tmp_path});
    try testing.expectEqualStrings(outside, resolve_argument(arena, io, project, outside));
}
