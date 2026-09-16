//! The two tests relative-import applies to the path an `@import` names:
//!
//! - `holds_parent_or_absolute`: the path holds `../` anywhere, or starts with `/`.
//! - `leaves_subsystem`: the path, resolved against the directory of the importing file, names a
//!   file outside that file's subsystem.
//!
//! A subsystem is the directory an importing file belongs to. Under `source_root` it is the child
//! directory the file sits in, such as `src/store/` for `src/store/journal/slots.zig`. Anywhere
//! else it is the first path component, such as `tools/` for `tools/lint/main.zig`. A file directly
//! inside `source_root`, or a bare file name with no directory, has no subsystem, so every path it
//! imports leaves it. The resolution reads only the text of the path the walk built. The driver
//! makes every PATH under the working directory relative to it, so `zig build`'s absolute paths
//! reach this file as `src/...`. A PATH outside the working directory stays absolute and makes `/`
//! the subsystem of every file under it.

const std = @import("std");
const paths = @import("../paths.zig");

/// Path segments one resolution holds: the importing file's directory and the import path
/// together. A path that needs more is reported as leaving its subsystem.
pub const max_resolved_segments: usize = 32;

/// The segment that climbs out of the importing file's directory.
const parent_segment = "../";

/// The first byte of an absolute path.
const absolute_root: u8 = '/';

/// The extension that marks an import path as a file rather than a module name.
const zig_file_marker = ".zig";

/// True when `imported` climbs above the importing file's directory or names an absolute path.
pub fn holds_parent_or_absolute(imported: []const u8) bool {
    if (imported.len == 0) return false;
    if (imported[0] == absolute_root) return true;
    return std.mem.indexOf(u8, imported, parent_segment) != null;
}

/// True when `imported`, resolved against the directory holding `path`, names a file outside that
/// file's subsystem. An absolute path always does. A module name, which holds no `/` and no
/// `.zig`, never does: the build decides what it names.
pub fn leaves_subsystem(source_root: []const u8, path: []const u8, imported: []const u8) bool {
    if (imported.len == 0) return false;
    if (imported[0] == absolute_root) return true;
    const names_file = std.mem.indexOfScalar(u8, imported, paths.separator) != null or
        std.mem.indexOf(u8, imported, zig_file_marker) != null;
    if (!names_file) return false;
    var buffer: [max_resolved_segments][]const u8 = undefined;
    const resolved = resolve(paths.dirname(path), imported, &buffer) orelse return true;
    const root = subsystem_root(source_root, path);
    if (root.len == 0) return true;
    return !starts_with_segments(resolved, root);
}

/// The directory the importing file's subsystem owns, with its trailing separator:
/// `src/<name>/` under `source_root`, or the first component anywhere else. Empty when the file
/// has no subsystem.
pub fn subsystem_root(source_root: []const u8, path: []const u8) []const u8 {
    const first = std.mem.indexOfScalar(u8, path, paths.separator) orelse return "";
    if (!std.mem.eql(u8, path[0..first], source_root)) return path[0 .. first + 1];
    const rest = path[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, paths.separator) orelse return "";
    return path[0 .. first + 1 + second + 1];
}

/// Resolves `relative` against `directory`, collapsing `.` and `..`. Null when it climbs above
/// the first segment of `directory` or needs more than `buffer` holds.
fn resolve(directory: []const u8, relative: []const u8, buffer: [][]const u8) ?[]const []const u8 {
    const start = push(directory, buffer, 0) orelse return null;
    const count = climb(relative, buffer, start) orelse return null;
    return buffer[0..count];
}

/// Appends the non-empty segments of `path` to `buffer` from `count`. Null when they do not fit.
fn push(path: []const u8, buffer: [][]const u8, count: usize) ?usize {
    var total = count;
    var parts = std.mem.splitScalar(u8, path, paths.separator);
    while (parts.next()) |segment| {
        if (segment.len == 0) continue;
        if (total == buffer.len) return null;
        buffer[total] = segment;
        total += 1;
    }
    return total;
}

/// Applies `relative` to the segments already in `buffer`: `..` removes one and `.` is skipped.
/// Null when it climbs above the first segment or does not fit.
fn climb(relative: []const u8, buffer: [][]const u8, count: usize) ?usize {
    var total = count;
    var parts = std.mem.splitScalar(u8, relative, paths.separator);
    while (parts.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (total == 0) return null;
            total -= 1;
            continue;
        }
        if (total == buffer.len) return null;
        buffer[total] = segment;
        total += 1;
    }
    return total;
}

/// True when the segments of `resolved` begin with the non-empty segments of `root`.
fn starts_with_segments(resolved: []const []const u8, root: []const u8) bool {
    var wanted = std.mem.splitScalar(u8, root, paths.separator);
    var index: usize = 0;
    while (wanted.next()) |segment| {
        if (segment.len == 0) continue;
        if (index == resolved.len) return false;
        if (!std.mem.eql(u8, resolved[index], segment)) return false;
        index += 1;
    }
    return true;
}

// Tests.

const testing = std.testing;

test "holds_parent_or_absolute reads the text of the path alone" {
    try testing.expect(holds_parent_or_absolute("../core/core.zig"));
    try testing.expect(holds_parent_or_absolute("store/../../core.zig"));
    try testing.expect(holds_parent_or_absolute("/home/someone/project/src/core.zig"));
    try testing.expect(!holds_parent_or_absolute(""));
    try testing.expect(!holds_parent_or_absolute("core"));
    try testing.expect(!holds_parent_or_absolute("journal/slots.zig"));
    try testing.expect(!holds_parent_or_absolute("..core.zig"));
}

test "subsystem_root is a child of the source root, or the first component" {
    try testing.expectEqualStrings("src/store/", subsystem_root("src", "src/store/page.zig"));
    try testing.expectEqualStrings("src/store/", subsystem_root("src", "src/store/journal/a.zig"));
    try testing.expectEqualStrings("tools/", subsystem_root("src", "tools/lint/main.zig"));
    try testing.expectEqualStrings("lib/", subsystem_root("src", "lib/store/page.zig"));
    try testing.expectEqualStrings("src/", subsystem_root("lib", "src/store/page.zig"));
    try testing.expectEqualStrings("./", subsystem_root("src", "./src/store/page.zig"));
    try testing.expectEqualStrings("/", subsystem_root("src", "/home/src/store/page.zig"));
    try testing.expectEqualStrings("", subsystem_root("src", "src/main.zig"));
    try testing.expectEqualStrings("", subsystem_root("src", "build.zig"));
}

test "leaves_subsystem resolves the path before it compares" {
    try testing.expect(!leaves_subsystem("src", "src/store/journal/open.zig", "../constants.zig"));
    try testing.expect(leaves_subsystem("src", "src/store/journal/open.zig", "../../core/a.zig"));
    try testing.expect(!leaves_subsystem("src", "src/store/page.zig", "./journal/../slots.zig"));
    try testing.expect(leaves_subsystem("src", "src/store/page.zig", "/abs/page.zig"));
    try testing.expect(!leaves_subsystem("src", "src/store/page.zig", "core"));
    try testing.expect(leaves_subsystem("src", "src/store/page.zig", "../../other/module"));
    try testing.expect(leaves_subsystem("src", "src/store/page.zig", "./../page.zig"));
    try testing.expect(!leaves_subsystem("src", "src/store/page.zig", ""));
}

test "leaves_subsystem reports a file with no subsystem and a climb above the tree" {
    try testing.expect(leaves_subsystem("src", "src/main.zig", "store/page.zig"));
    try testing.expect(leaves_subsystem("src", "build.zig", "page.zig"));
    try testing.expect(!leaves_subsystem("src", "build.zig", "core"));
    try testing.expect(leaves_subsystem("src", "tools/lint.zig", "../../outside.zig"));
    try testing.expect(leaves_subsystem("src", "tools/lint.zig", "../../tools/lint.zig"));
}

test "leaves_subsystem reports a resolution longer than max_resolved_segments" {
    // The directory `src/store` is two segments and the file name one more.
    const deep = "a/" ** (max_resolved_segments - 3) ++ "page.zig";
    try testing.expect(!leaves_subsystem("src", "src/store/page.zig", deep));
    const deeper = "a/" ** (max_resolved_segments - 2) ++ "page.zig";
    try testing.expect(leaves_subsystem("src", "src/store/page.zig", deeper));
}
