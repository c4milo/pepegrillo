//! Whether a name a configuration holds still names something.
//!
//! A rule is told what to look for by a list of names its project writes down. A name that no
//! longer exists does not fail the rule. The rule reports nothing, and nothing separates that
//! from a clean tree: `std.crypto.random` left the standard library and every rule that forbade
//! it went on passing. These checks read the names at compile time, so a name that has gone
//! fails the build instead of going quiet.
//!
//! A project calls them from its own tool, which imports the namespace its names are rooted at:
//!
//!     comptime names.assert_all_resolve(std, "std", &forbidden_prefixes);
//!     comptime names.assert_all_match(std, "std", &forbidden_raw_prefixes);
//!
//! `assert_all_resolve` reads a whole name, `std.testing.allocator`. `assert_all_match` reads a
//! partial one, `std.posix.clock_`, and asks that some declaration begin with it. A name rooted
//! anywhere but `root` is left alone: the namespace to read it under is not in hand.
//!
//! What these cannot do. They read the declarations a namespace exports, so a name that still
//! exists but has changed meaning reads as present. Only the name of the last segment is read,
//! never its value: reading the value would run the declaration, and `std.testing.allocator`
//! refuses to be read outside a test. So a name under a declaration that is not a namespace,
//! `std.testing.allocator.something`, reads as naming nothing.

const std = @import("std");

/// The separator between the segments of a name.
const segment_separator = '.';

/// True when a type holds declarations to read.
fn is_namespace(comptime candidate: type) bool {
    return switch (@typeInfo(candidate)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => true,
        else => false,
    };
}

/// True when `chain`, read segment by segment under `namespace`, names a declaration that
/// exists. An empty chain is the namespace itself and resolves.
pub fn resolves(comptime namespace: type, comptime chain: []const u8) bool {
    if (chain.len == 0) return true;
    comptime var current = namespace;
    comptime var parts = std.mem.splitScalar(u8, chain, segment_separator);
    inline while (comptime parts.next()) |segment| {
        if (comptime !is_namespace(current)) return false;
        if (comptime !@hasDecl(current, segment)) return false;
        // The last segment is answered by its declaration existing. Reading its value would run
        // whatever the declaration is, and `std.testing.allocator` refuses to be read outside a
        // test, so the walk stops at the name.
        if (comptime parts.rest().len == 0) return true;
        const next = @field(current, segment);
        // A declaration that is not a namespace has nothing under it to reach.
        if (comptime @TypeOf(next) != type) return false;
        current = next;
    }
    return true;
}

/// True when some declaration of the namespace `chain` ends in begins with the partial segment
/// `chain` ends with, so `posix.clock_` matches while `posix.no_such_` does not.
pub fn matches(comptime namespace: type, comptime chain: []const u8) bool {
    const cut = comptime std.mem.lastIndexOfScalar(u8, chain, segment_separator);
    const holder = comptime if (cut) |index| chain[0..index] else "";
    const partial = comptime if (cut) |index| chain[index + 1 ..] else chain;
    if (partial.len == 0) return false;
    if (comptime !resolves(namespace, holder)) return false;
    const reached = comptime reach(namespace, holder);
    if (comptime !is_namespace(reached)) return false;
    inline for (comptime std.meta.declarations(reached)) |declaration| {
        if (comptime std.mem.startsWith(u8, declaration.name, partial)) return true;
    }
    return false;
}

/// The namespace `chain` names under `namespace`. Only called for a chain `resolves` accepted.
fn reach(comptime namespace: type, comptime chain: []const u8) type {
    if (chain.len == 0) return namespace;
    comptime var current = namespace;
    comptime var parts = std.mem.splitScalar(u8, chain, segment_separator);
    inline while (comptime parts.next()) |segment| {
        const next = @field(current, segment);
        if (comptime @TypeOf(next) != type) return current;
        current = next;
    }
    return current;
}

/// Fails the build when a whole name rooted at `root` names nothing under `namespace`.
pub fn assert_all_resolve(
    comptime namespace: type,
    comptime root: []const u8,
    comptime chains: []const []const u8,
) void {
    inline for (chains) |chain| {
        const rest = comptime rooted(chain, root) orelse continue;
        if (comptime !resolves(namespace, rest)) {
            @compileError("the configured name `" ++ chain ++ "` names nothing under `" ++
                root ++ "`; it has moved or gone, and the rule holding it checks nothing");
        }
    }
}

/// Fails the build when a partial name rooted at `root` begins no declaration under `namespace`.
pub fn assert_all_match(
    comptime namespace: type,
    comptime root: []const u8,
    comptime chains: []const []const u8,
) void {
    inline for (chains) |chain| {
        const rest = comptime rooted(chain, root) orelse continue;
        if (comptime !matches(namespace, rest)) {
            @compileError("the configured prefix `" ++ chain ++ "` begins no name under `" ++
                root ++ "`; it has moved or gone, and the rule holding it checks nothing");
        }
    }
}

/// What is left of `chain` under `root`, or null when `chain` is rooted elsewhere.
fn rooted(comptime chain: []const u8, comptime root: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, chain, root)) return null;
    if (chain.len == root.len) return "";
    if (chain[root.len] != segment_separator) return null;
    return chain[root.len + 1 ..];
}

// Tests.

const testing = std.testing;

/// A namespace of a shape the checks must read: a nested namespace, a value, and a name whose
/// start another name shares.
const Fixture = struct {
    pub const inner = struct {
        pub const leaf: u32 = 1;
        pub const deeper = struct {
            pub const bottom: u32 = 2;
        };
    };
    pub const value: u32 = 3;
    pub const clock_kind: u32 = 4;
    /// A type that is not a namespace, so nothing is read under it.
    pub const Number = u32;
};

/// A namespace holding a declaration that refuses to be read, as `std.testing.allocator` does
/// outside a test. Resolving the name must not read the value, or this file would not compile.
const Guarded = struct {
    pub const refuses: u32 = @compileError("this declaration must never be read");
    pub const inner = struct {
        pub const refuses_too: u32 = @compileError("nor this one");
    };
};

test "resolving a name reads the name and never the declaration behind it" {
    try testing.expect(resolves(Guarded, "refuses"));
    try testing.expect(resolves(Guarded, "inner.refuses_too"));
    try testing.expect(!resolves(Guarded, "missing"));
}

test "a whole name resolves when every segment of it exists" {
    try testing.expect(resolves(Fixture, ""));
    try testing.expect(resolves(Fixture, "inner"));
    try testing.expect(resolves(Fixture, "inner.leaf"));
    try testing.expect(resolves(Fixture, "inner.deeper.bottom"));
    try testing.expect(resolves(Fixture, "value"));
}

test "a whole name that no segment of the namespace holds does not resolve" {
    try testing.expect(!resolves(Fixture, "outer"));
    try testing.expect(!resolves(Fixture, "inner.missing"));
    try testing.expect(!resolves(Fixture, "inner.deeper.missing"));
    try testing.expect(!resolves(Fixture, "missing.leaf"));
}

test "a name read through a value stops at the value" {
    // `value` is a number, so nothing under it is read and the chain is no longer than it.
    try testing.expect(!resolves(Fixture, "value.anything"));
}

test "a name read through a type that holds no declarations stops at it" {
    // `Number` is `u32`, a type with no declarations to read, so the walk ends rather than
    // asking a number what it declares.
    try testing.expect(resolves(Fixture, "Number"));
    try testing.expect(!resolves(Fixture, "Number.anything"));
}

test "a partial name matches when some declaration begins with it" {
    try testing.expect(matches(Fixture, "clock_"));
    try testing.expect(matches(Fixture, "inner.deep"));
    try testing.expect(!matches(Fixture, "clock_kinds"));
    try testing.expect(!matches(Fixture, "inner.no_such_"));
    try testing.expect(!matches(Fixture, "missing.clock_"));
    try testing.expect(!matches(Fixture, ""));
}

test "rooted keeps what stands under the root and leaves every other name alone" {
    try testing.expectEqualStrings("heap", rooted("std.heap", "std").?);
    try testing.expectEqualStrings("", rooted("std", "std").?);
    try testing.expectEqualStrings("a.b", rooted("std.a.b", "std").?);
    try testing.expect(rooted("other.heap", "std") == null);
    // Shares the root's first bytes and then does not end it: `stdlib` is not `std`.
    try testing.expect(rooted("stdlib.heap", "std") == null);
    // Ends at a separator where the root would, and is a different root.
    try testing.expect(rooted("abc.heap", "std") == null);
}

test "the standard library is read the same way a fixture is" {
    try testing.expect(resolves(std, "heap"));
    try testing.expect(resolves(std, "mem.eql"));
    try testing.expect(resolves(std, "testing.allocator"));
    try testing.expect(!resolves(std, "no_such_module"));
    try testing.expect(matches(std, "me"));
}

test "a list rooted elsewhere passes whatever it holds" {
    // Nothing here is rooted at `std`, so nothing is read and the build stands.
    comptime assert_all_resolve(std, "std", &.{ "core.thing", "project.other" });
    comptime assert_all_match(std, "std", &.{"core.thing_"});
}

test "a list of names that all resolve passes" {
    comptime assert_all_resolve(std, "std", &.{ "std.heap", "std.mem.eql", "std.testing" });
    comptime assert_all_match(std, "std", &.{"std.me"});
}
