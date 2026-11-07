//! The test each root runs on the names it exports. A root is the file a project reaches through
//! `@import("pepegrillo")`, and each `pub` declaration in it is a name a project can call. The test
//! lists those names, so a name added or removed by accident fails it (docs/api.md, section 1).
//! Only tests reference this file, and the root does not export it.

const std = @import("std");

/// The most names one root exports.
const names_max = 64;

/// Fails when the `pub` declarations of `namespace` differ from `expected`, in any order, and
/// prints the first name that differs.
pub fn expect(comptime namespace: type, comptime expected: []const []const u8) !void {
    const difference = comptime first_difference(namespace, expected);
    if (difference) |name| {
        std.debug.print("{s}\n", .{name});
        return error.PublicNamesDiffer;
    }
}

/// The first name exported and not listed, or listed and not exported, or null.
fn first_difference(comptime namespace: type, comptime expected: []const []const u8) ?[]const u8 {
    const declarations = std.meta.declarations(namespace);
    std.debug.assert(declarations.len <= names_max);
    for (declarations) |declaration| {
        if (!contains(expected, declaration.name)) return "exported and not listed: " ++ declaration.name;
    }
    for (expected) |name| {
        if (!declared(declarations, name)) return "listed and not exported: " ++ name;
    }
    return null;
}

fn contains(names: []const []const u8, wanted: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, wanted)) return true;
    }
    return false;
}

fn declared(declarations: []const std.builtin.Type.Declaration, wanted: []const u8) bool {
    for (declarations) |declaration| {
        if (std.mem.eql(u8, declaration.name, wanted)) return true;
    }
    return false;
}

test "first_difference accepts the names in any order and names a missing or an extra one" {
    const Namespace = struct {
        pub const one = 1;
        pub fn two() void {}
        const hidden = 3;
    };
    try expect(Namespace, &.{ "two", "one" });
    const extra = comptime first_difference(Namespace, &.{"one"}).?;
    try std.testing.expectEqualStrings("exported and not listed: two", extra);
    const missing = comptime first_difference(Namespace, &.{ "one", "two", "three" }).?;
    try std.testing.expectEqualStrings("listed and not exported: three", missing);
}
