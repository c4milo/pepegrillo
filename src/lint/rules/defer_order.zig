//! defer-order: a `defer` or an `errdefer` registered under a statement that can fail. When that
//! statement fails, it returns before the `defer` is registered, so whatever the block acquired
//! above it leaks. The fix is one line of ordering: the `defer` moves above the statement that can
//! fail.
//!
//! Over every Zig file `scope` selects, the rule reads the statements of every block in order. For
//! each statement that is a `defer` or an `errdefer`, it reads the statement immediately above it
//! and reports the `defer` when all three hold:
//!
//! 1. A statement stands above it in the same block. A `defer` that opens a block is passed.
//! 2. That statement can fail: its subtree holds a `try`, or a `catch` whose right-hand side holds
//!    a `return`, a `break` or a `continue`. A `catch` that supplies a value, `f() catch 0`, runs
//!    the statements under it, so it does not count.
//! 3. The statement and the deferred expression name no identifier in common. Sharing a name is
//!    what separates the two orders: `const file = try open(path); defer file.close();` names
//!    `file` on both sides, because what is released is what the statement produced, while
//!    `try connect_all(&client); defer close_all();` names nothing on both sides, because what is
//!    released was acquired further above. An identifier is the name an `identifier` carries, each
//!    segment of a field-access chain, so `loop` and `loop.deinit()` share `loop`, and the name a
//!    variable declaration binds. A deferred expression that names no identifier at all leaves
//!    nothing to compare and is passed: it releases nothing, so no ordering of it leaks anything.
//!    `errdefer comptime unreachable`, which asserts that nothing below it can fail, is the
//!    expression of this shape that appears in practice.
//!
//! The finding sits at the `defer` keyword. `defer_order_scan.zig` holds the two reads.
//!
//! What the rule cannot do:
//!
//! - It reads the statement order of one block and not the dataflow. It cannot tell whether the
//!   deferred expression releases anything, so a `defer` that writes a log line reads the same as
//!   one that closes a socket.
//! - It cannot see inside the statement it reads. A function that opens one socket per iteration
//!   and returns on the first failure leaks every socket it already opened, and the rule reads its
//!   caller alone.
//! - A shared name is a guess that two statements are about the same thing. Code that shares a
//!   name by coincidence is passed, and correct code that shares none is reported.
//! - A resource released through any path but a `defer` is invisible to it.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const ast = @import("../ast.zig");
const report = @import("../report.zig");
const Scope = @import("../scope.zig").Scope;
const scan = @import("defer_order_scan.zig");

pub const max_deferred_identifiers = scan.max_deferred_identifiers;

pub const Config = struct {
    /// The name `--rule` selects and the report prints.
    name: []const u8 = "defer-order",
    /// The files the rule reads. A file that does not parse is skipped.
    scope: Scope,
    /// The finding text. No arguments.
    message: []const u8 = "a defer after a statement that can fail; anything acquired above it" ++
        " leaks when that statement returns",
    /// Which function parameter types the walk reads. `.simple_prototypes_only` reproduces a
    /// walker that read the parameter types of one-parameter prototypes alone.
    parameter_types: ast.ParameterTypes = .every_prototype,
};

pub fn Rule(comptime config: Config) type {
    return struct {
        pub const name = config.name;

        pub fn check(context: *report.Context, file: report.File) !void {
            return check_file(config, context, file);
        }
    };
}

fn check_file(comptime config: Config, context: *report.Context, file: report.File) !void {
    if (!config.scope.applies(file.path)) return;
    const tree = file.tree orelse return;
    var walker: Walker(config) = .{
        .tree = tree,
        .findings = &context.findings,
        .path = file.path,
    };
    for (tree.rootDecls()) |declaration| walker.child(declaration);
    if (walker.failure) |failure| return failure;
}

/// The walk over every node of one file. `child` is what `ast.for_each_child_reading` calls, and
/// every block it reaches is read as a statement list by `check_block`.
fn Walker(comptime config: Config) type {
    return struct {
        tree: *const Ast,
        findings: *report.Findings,
        path: []const u8,
        depth: u32 = 0,
        /// The first error `visit` returned. `child` returns nothing, so the walk keeps it here
        /// and `check_file` returns it.
        failure: ?anyerror = null,

        pub fn child(self: *@This(), node: Node.Index) void {
            self.depth += 1;
            defer self.depth -= 1;
            std.debug.assert(self.depth <= ast.max_tree_depth);
            visit(config, self, node) catch |failure| {
                self.failure = failure;
            };
        }
    };
}

fn visit(comptime config: Config, walker: *Walker(config), node: Node.Index) !void {
    try check_block(config, walker, node);
    ast.for_each_child_reading(walker.tree, node, config.parameter_types, walker);
}

/// Reads one block's statements in order. A node that is not a block has none, and a nested block
/// is read on its own, so every `defer` is judged by the statement above it in its own block.
fn check_block(comptime config: Config, walker: *Walker(config), node: Node.Index) !void {
    var buffer: [2]Node.Index = undefined;
    const statements = walker.tree.blockStatements(&buffer, node) orelse return;
    for (statements, 0..) |statement, index| {
        if (index == 0) continue;
        if (!is_defer(walker.tree.nodeTag(statement))) continue;
        try check_defer(config, walker, statement, statements[index - 1]);
    }
}

/// Reports `statement`, a `defer` or an `errdefer`, when `previous` can fail and the two name no
/// identifier in common.
fn check_defer(
    comptime config: Config,
    walker: *Walker(config),
    statement: Node.Index,
    previous: Node.Index,
) !void {
    const tree = walker.tree;
    if (!scan.can_fail(tree, previous, config.parameter_types)) return;
    const deferred = deferred_expression(tree, statement);
    const names = scan.compare_identifiers(tree, deferred, previous, config.parameter_types);
    if (names != .none_shared) return;
    const location = ast.node_location(tree, statement);
    const findings = walker.findings;
    const message = config.message;
    try findings.add(config.name, walker.path, location.line, location.column, message, .{});
}

fn is_defer(tag: Node.Tag) bool {
    return switch (tag) {
        .@"defer", .@"errdefer" => true,
        else => false,
    };
}

/// The expression a `defer` or an `errdefer` runs later. An `errdefer` carries an optional
/// `|payload|` token before it, so the two shapes read their expression from different fields.
fn deferred_expression(tree: *const Ast, statement: Node.Index) Node.Index {
    return switch (tree.nodeTag(statement)) {
        .@"defer" => tree.nodeData(statement).node,
        .@"errdefer" => tree.nodeData(statement).opt_token_and_node[1],
        else => unreachable,
    };
}

test {
    _ = scan;
    _ = @import("defer_order_test.zig");
}
