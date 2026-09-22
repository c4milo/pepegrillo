//! The two reads the defer-order check makes over one block's statements:
//!
//! - `can_fail`: whether a statement can leave the block before the statements under it run.
//! - `compare_identifiers`: whether two subtrees name one identifier in common.
//!
//! Split off `defer_order.zig` so that file holds the configuration and the check, and this one
//! holds the reads. Neither read allocates. `compare_identifiers` collects the names of the
//! deferred expression into a fixed buffer and reads the other subtree against it.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const ast = @import("../ast.zig");

/// The most identifiers `compare_identifiers` collects from one deferred expression. An
/// expression that names more reads as `.shared`, so the limit costs a finding and never invents
/// one.
pub const max_deferred_identifiers: usize = 32;

/// True when the subtree at `node` holds a `try`, or a `catch` whose right-hand side holds a
/// `return`, a `break` or a `continue`. Those are the statements whose failure skips every
/// statement under them in the block.
pub fn can_fail(tree: *const Ast, node: Node.Index, parameter_types: ast.ParameterTypes) bool {
    var state: Fails = .{ .parameter_types = parameter_types };
    walk(tree, node, parameter_types, &state);
    return state.found;
}

/// What the identifiers of a deferred expression say about the statement above it.
pub const Comparison = enum {
    /// The two subtrees name an identifier in common.
    shared,
    /// They name none.
    none_shared,
    /// The deferred expression names no identifier, so there is nothing to compare. An expression
    /// that names nothing releases nothing, `errdefer comptime unreachable` being the one that
    /// appears in practice, so no ordering of it leaks anything.
    nothing_to_compare,
};

/// Whether the subtree at `deferred` and the subtree at `statement` name one identifier in
/// common. An identifier is the name an `identifier` node carries, each segment name of a
/// field-access chain, so `loop` and `loop.deinit()` share `loop`, and the name a variable
/// declaration binds, so `const file = try open(path);` shares `file` with `defer file.close();`.
pub fn compare_identifiers(
    tree: *const Ast,
    deferred: Node.Index,
    statement: Node.Index,
    parameter_types: ast.ParameterTypes,
) Comparison {
    var names: NameSet = .{};
    var collect: Collect = .{ .set = &names };
    walk(tree, deferred, parameter_types, &collect);
    if (names.overflowed) return .shared;
    if (names.count == 0) return .nothing_to_compare;
    var match: Match = .{ .set = &names };
    walk(tree, statement, parameter_types, &match);
    return if (match.found) .shared else .none_shared;
}

/// True when the subtree at `node` holds a `return`, a `break` or a `continue`.
fn holds_exit(tree: *const Ast, node: Node.Index, parameter_types: ast.ParameterTypes) bool {
    var state: Exits = .{};
    walk(tree, node, parameter_types, &state);
    return state.found;
}

/// Hands every node of the subtree at `node`, that node included, to `state.note`.
fn walk(
    tree: *const Ast,
    node: Node.Index,
    parameter_types: ast.ParameterTypes,
    state: anytype,
) void {
    var walker: Walk(@TypeOf(state.*)) = .{
        .tree = tree,
        .parameter_types = parameter_types,
        .state = state,
    };
    walker.child(node);
}

/// The walk every read above makes. `child` is what `ast.for_each_child_reading` calls, and the
/// state decides what one node means.
fn Walk(comptime State: type) type {
    return struct {
        tree: *const Ast,
        parameter_types: ast.ParameterTypes,
        state: *State,
        depth: u32 = 0,

        pub fn child(self: *@This(), node: Node.Index) void {
            self.depth += 1;
            defer self.depth -= 1;
            std.debug.assert(self.depth <= ast.max_tree_depth);
            self.state.note(self.tree, node);
            ast.for_each_child_reading(self.tree, node, self.parameter_types, self);
        }
    };
}

/// Whether a statement can leave the block.
const Fails = struct {
    parameter_types: ast.ParameterTypes,
    found: bool = false,

    fn note(self: *Fails, tree: *const Ast, node: Node.Index) void {
        switch (tree.nodeTag(node)) {
            .@"try" => self.found = true,
            .@"catch" => self.note_catch(tree, node),
            else => {},
        }
    }

    /// A `catch` that supplies a value, `f() catch 0`, runs the statements under it, so only one
    /// whose right-hand side leaves the block counts.
    fn note_catch(self: *Fails, tree: *const Ast, node: Node.Index) void {
        const right = tree.nodeData(node).node_and_node[1];
        if (holds_exit(tree, right, self.parameter_types)) self.found = true;
    }
};

/// Whether a subtree leaves the block it sits in.
const Exits = struct {
    found: bool = false,

    fn note(self: *Exits, tree: *const Ast, node: Node.Index) void {
        switch (tree.nodeTag(node)) {
            .@"return", .@"break", .@"continue" => self.found = true,
            else => {},
        }
    }
};

/// The identifiers one subtree names, held by value so no read allocates.
const NameSet = struct {
    names: [max_deferred_identifiers][]const u8 = undefined,
    count: usize = 0,
    /// Set when the subtree names more identifiers than `names` holds.
    overflowed: bool = false,

    fn add(self: *NameSet, name: []const u8) void {
        if (self.count == self.names.len) {
            self.overflowed = true;
            return;
        }
        self.names[self.count] = name;
        self.count += 1;
    }

    fn holds(self: *const NameSet, name: []const u8) bool {
        for (self.names[0..self.count]) |held| {
            if (std.mem.eql(u8, held, name)) return true;
        }
        return false;
    }
};

/// Writes the identifiers of one subtree into `set`.
const Collect = struct {
    set: *NameSet,

    fn note(self: *Collect, tree: *const Ast, node: Node.Index) void {
        const name = name_of(tree, node) orelse return;
        self.set.add(name);
    }
};

/// Whether one subtree names an identifier `set` holds.
const Match = struct {
    set: *const NameSet,
    found: bool = false,

    fn note(self: *Match, tree: *const Ast, node: Node.Index) void {
        const name = name_of(tree, node) orelse return;
        if (self.set.holds(name)) self.found = true;
    }
};

/// The identifier one node names: the name an `identifier` carries, the segment name a field
/// access carries, or the name a variable declaration binds. Null for every other node. The root
/// of a field-access chain is an `identifier` the walk reaches on its own.
fn name_of(tree: *const Ast, node: Node.Index) ?[]const u8 {
    return switch (tree.nodeTag(node)) {
        .identifier => tree.tokenSlice(tree.nodeMainToken(node)),
        .field_access => tree.tokenSlice(tree.nodeData(node).node_and_token[1]),
        .simple_var_decl,
        .local_var_decl,
        .aligned_var_decl,
        .global_var_decl,
        => tree.tokenSlice(tree.nodeMainToken(node) + 1),
        else => null,
    };
}

// Tests. The rule's tests, which drive these reads through whole files, are in
// `defer_order_test.zig`.

const testing = std.testing;

/// Parses `source` and hands the first statement of the first function's body to `read`.
fn first_statement(source: [:0]const u8, read: fn (*const Ast, Node.Index) bool) !bool {
    var tree = try Ast.parse(testing.allocator, source, .zig);
    defer tree.deinit(testing.allocator);
    try testing.expectEqual(0, tree.errors.len);
    const body = tree.nodeData(tree.rootDecls()[0]).node_and_node[1];
    var buffer: [2]Node.Index = undefined;
    return read(&tree, tree.blockStatements(&buffer, body).?[0]);
}

fn fails(tree: *const Ast, node: Node.Index) bool {
    return can_fail(tree, node, .every_prototype);
}

test "can_fail reads a try anywhere in the statement" {
    try testing.expect(try first_statement("fn f() !void {\n    try open();\n}", fails));
    try testing.expect(try first_statement("fn f() !void {\n    const a = try b(c);\n}", fails));
    try testing.expect(try first_statement("fn f() !void {\n    a(try b());\n}", fails));
    try testing.expect(!try first_statement("fn f() void {\n    const a = b(c);\n}", fails));
}

test "can_fail reads a catch that leaves the block and passes one that supplies a value" {
    const returns = "fn f() !void {\n    const a = b() catch return error.X;\n}";
    const breaks = "fn f() void {\n    const a = b() catch break;\n}";
    const continues = "fn f() void {\n    const a = b() catch continue;\n}";
    const value = "fn f() void {\n    const a = b() catch 0;\n}";
    const block = "fn f() void {\n    const a = b() catch |e| handle(e);\n}";
    try testing.expect(try first_statement(returns, fails));
    try testing.expect(try first_statement(breaks, fails));
    try testing.expect(try first_statement(continues, fails));
    try testing.expect(!try first_statement(value, fails));
    try testing.expect(!try first_statement(block, fails));
}

test "a name set holds what it is given and reports an overflow" {
    var set: NameSet = .{};
    set.add("loop");
    try testing.expect(set.holds("loop"));
    try testing.expect(!set.holds("loopx"));
    try testing.expect(!set.overflowed);
    for (0..max_deferred_identifiers) |_| set.add("filler");
    try testing.expect(set.overflowed);
    try testing.expectEqual(max_deferred_identifiers, set.count);
}
