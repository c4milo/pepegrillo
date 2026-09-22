//! unreleased-acquire: a value acquired with `try` that nothing in its block is shown to release,
//! where a statement under it can still fail. When that statement returns, the value is lost. This
//! is the leak inside a function, where defer-order reads the caller of one.
//!
//! Over every Zig file `scope` selects, the rule reads the statements of every block in order. A
//! statement of the shape `const name = try <call>(...)` is an acquire when the last segment of
//! the called function starts with one of `acquire_prefixes` or ends with one of
//! `acquire_suffixes`. Both lists are empty by default, so the rule reports nothing until a
//! project names the functions its own tree acquires with. Under `read_assignments`, which is
//! off, `<target> = try <call>(...)` is an acquire too, of the root of its target: `slot` for
//! `slot.* = try open_socket()`, `client` for `client.socket = try open_socket()`.
//!
//! An acquire is reported when all three hold:
//!
//! 1. A statement between the acquire and its release can fail: its subtree holds a `try`, or a
//!    `catch` whose right-hand side holds a `return`, a `break` or a `continue`. The release is
//!    the first statement under the acquire that calls a function named by `release_prefixes` or
//!    `release_suffixes` and names the acquired value, `close_now(socket)` for `socket`. Without
//!    one, every statement under the acquire is read.
//! 2. No `defer` and no `errdefer` in effect where the acquire stands names the value. Those are
//!    the defers of its own block, above it and below it, and the defers of every block above
//!    that one written before the statement the acquire sits inside. Each runs when its own block
//!    ends, however it ends, which is the whole point of writing one, so each releases what it
//!    names. A defer of a block the walk has left, or of one beside the acquire's, is not in
//!    effect and does not count. A defer above an acquire matters only for an assignment: the
//!    name a declaration binds does not exist yet where such a defer is written.
//! 3. No `return` under it names the value, when `pass_returned` is set. A value the block returns
//!    belongs to its caller from there.
//!
//! The finding sits at the declaration.
//!
//! What the rule cannot do:
//!
//! - It reads names and not types. A function the project's list names that hands back something
//!   owning nothing, a flag word or a count, is reported like a descriptor.
//! - It reads one ownership transfer, the direct `return`. A value written into a structure,
//!   appended to a list, or handed to a function that takes it, is reported.
//! - An arena, a pool or a fixed buffer releases everything it handed out at once. A value taken
//!   from one is reported unless the project leaves those functions out of its list. This is why
//!   the lists start empty: a guessed list reports allocations that need no release.
//! - It reads an acquire into a variable that already exists only under `read_assignments`, and
//!   an acquire into a subscript, `slots[index] = try open(path)`, not at all: it has no root
//!   identifier to follow.
//! - It reads a block's statements in the order they are written and does not know that a loop
//!   runs its body again. An acquire that is the last statement of a loop body has nothing under
//!   it, so nothing in its own block can fail, and the rule passes it — even though the next
//!   iteration of that same acquire is what loses the value the last one took.
//! - A release it finds is a call with a matching name, not a proof. It cannot tell that the call
//!   releases the value, and it cannot see a release a called function makes.
//! - The release ends the window wherever it stands inside a statement, so one only some paths
//!   reach, `if (refused) close_now(socket);`, ends it for every path. The window is read short
//!   rather than long, which reports fewer acquires rather than false ones.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const ast = @import("../ast.zig");
const report = @import("../report.zig");
const Scope = @import("../scope.zig").Scope;

/// The last names a call releases something by, unless the configuration names others.
pub const default_release_prefixes = [_][]const u8{
    "close",
    "free",
    "destroy",
    "release",
    "unmap",
};

/// The last-name endings a call releases something by, unless the configuration names others.
pub const default_release_suffixes = [_][]const u8{
    "deinit",
    "_close",
    "_free",
};

pub const Config = struct {
    /// The name `--rule` selects and the report prints.
    name: []const u8 = "unreleased-acquire",
    /// The files the rule reads. A file that does not parse is skipped.
    scope: Scope,
    /// A call whose last segment starts with one of these acquires something: `open_`, `create`.
    /// Empty, with `acquire_suffixes`, reports nothing.
    acquire_prefixes: []const []const u8 = &.{},
    /// A call whose last segment ends with one of these acquires something: `_init`.
    acquire_suffixes: []const []const u8 = &.{},
    /// A call whose last segment starts with one of these releases what it names. Empty, with
    /// `release_suffixes`, reads every statement under the acquire.
    release_prefixes: []const []const u8 = &default_release_prefixes,
    /// A call whose last segment ends with one of these releases what it names.
    release_suffixes: []const []const u8 = &default_release_suffixes,
    /// When set, a value a `return` under the acquire names is passed: the caller owns it.
    pass_returned: bool = true,
    /// When set, `slot.* = try open_socket()` is read as an acquire of `slot`, beside
    /// `const slot = try open_socket()`. Off, so adopting it is the project's commit: a tree that
    /// already runs this rule gains findings the day it is set.
    read_assignments: bool = false,
    /// The finding text, a `std.fmt` format string. `acquired`: the name the declaration binds.
    message: []const u8 = "{[acquired]s} is acquired here and a statement under it can fail," ++
        " and no defer releases {[acquired]s}",
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
/// The deferred expressions already registered where a statement runs: those above it in its own
/// block, and those above the statement it sits inside in every block above that. Each releases
/// whatever it names however its own block ends, so each protects an acquire under it.
const Registered = struct {
    expressions: [max_registered_defers]Node.Index = undefined,
    count: usize = 0,
    /// Set when a block registers more defers than `expressions` holds. Every acquire under it
    /// then reads as released, which is the safe direction.
    overflowed: bool = false,

    fn push(self: *Registered, expression: Node.Index) void {
        if (self.count == self.expressions.len) {
            self.overflowed = true;
            return;
        }
        self.expressions[self.count] = expression;
        self.count += 1;
    }

    /// True when one registered expression names `acquired`.
    fn releases(
        self: *const Registered,
        tree: *const Ast,
        acquired: []const u8,
        parameter_types: ast.ParameterTypes,
    ) bool {
        if (self.overflowed) return true;
        for (self.expressions[0..self.count]) |expression| {
            if (ast.mentions(tree, expression, acquired, parameter_types)) return true;
        }
        return false;
    }
};

fn Walker(comptime config: Config) type {
    return struct {
        tree: *const Ast,
        findings: *report.Findings,
        path: []const u8,
        depth: u32 = 0,
        /// The defers in effect where the walk stands.
        registered: Registered = .{},
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
    var buffer: [2]Node.Index = undefined;
    if (walker.tree.blockStatements(&buffer, node)) |statements| {
        return check_block(config, walker, statements);
    }
    ast.for_each_child_reading(walker.tree, node, config.parameter_types, walker);
}

/// Reads one block's statements in order, and descends into each before the defer it may be takes
/// effect, so every acquire is read with the defers that stand above it and no others. The defers
/// this block registered go out of effect with the block, as they do when it ends.
fn check_block(
    comptime config: Config,
    walker: *Walker(config),
    statements: []const Node.Index,
) !void {
    const outer = walker.registered;
    defer walker.registered = outer;
    for (statements, 0..) |statement, index| {
        if (acquired_name(config, walker.tree, statement)) |acquired| {
            try check_acquire(config, walker, statement, acquired, statements[index + 1 ..]);
        }
        walker.child(statement);
        if (deferred_expression(walker.tree, statement)) |expression| {
            walker.registered.push(expression);
        }
    }
}

/// Reports the acquire at `statement` when the statements in `below` neither release it nor pass
/// it on, and one of those that stand before its release can fail.
fn check_acquire(
    comptime config: Config,
    walker: *Walker(config),
    statement: Node.Index,
    acquired: []const u8,
    below: []const Node.Index,
) !void {
    const tree = walker.tree;
    const reach = below[0..release_index(config, tree, acquired, below)];
    if (!any_can_fail(config, tree, reach)) return;
    if (deferred_release(config, tree, acquired, below)) return;
    if (walker.registered.releases(tree, acquired, config.parameter_types)) return;
    if (config.pass_returned and returned(config, tree, acquired, below)) return;
    const location = ast.node_location(tree, statement);
    const findings = walker.findings;
    const message = config.message;
    const arguments = .{ .acquired = acquired };
    try findings.add(config.name, walker.path, location.line, location.column, message, arguments);
}

/// The most defers `Registered` holds at once: the defers of one block and of every block above
/// it. A block that registers more makes the stack read as releasing everything, so the limit
/// costs findings and never invents one.
pub const max_registered_defers: usize = 64;

/// The target that binds nothing. `_ = try open_socket()` acquires and discards in one statement,
/// and no defer can release what has no name, so it is no acquire.
const discard_target = "_";

/// How far `assigned_root` walks down an assignment's target before it gives up: `a.b.c.*` is
/// four. A target nested deeper is read as no acquire at all.
const max_target_depth: usize = 16;

/// The name a statement acquires: the name `const name = try <acquire>(...)` binds, or, when the
/// configuration reads assignments, the root of the target of `<target> = try <acquire>(...)`.
/// Null for every other statement.
fn acquired_name(comptime config: Config, tree: *const Ast, statement: Node.Index) ?[]const u8 {
    if (declared_name(config, tree, statement)) |name| return name;
    if (!config.read_assignments) return null;
    return assigned_name(config, tree, statement);
}

/// The name `const name = try <acquire>(...)` binds.
fn declared_name(comptime config: Config, tree: *const Ast, statement: Node.Index) ?[]const u8 {
    const declaration = tree.fullVarDecl(statement) orelse return null;
    const initializer = declaration.ast.init_node.unwrap() orelse return null;
    if (!is_acquire(config, tree, initializer)) return null;
    return tree.tokenSlice(declaration.ast.mut_token + 1);
}

/// The root of the target of `<target> = try <acquire>(...)`: `slot` for `slot.* = ...` and for
/// `slot.handle = ...`. The root, and not the whole target, because a `defer` releases what it
/// names through the same root, and a root reads fewer acquires rather than false ones.
fn assigned_name(comptime config: Config, tree: *const Ast, statement: Node.Index) ?[]const u8 {
    if (tree.nodeTag(statement) != .assign) return null;
    const target, const value = tree.nodeData(statement).node_and_node;
    if (!is_acquire(config, tree, value)) return null;
    return assigned_root(tree, target);
}

/// The identifier an assignment's target is rooted at, past its `.*` and its field accesses, or
/// null when the target is the discard or any other expression, such as `slots[index]`.
fn assigned_root(tree: *const Ast, target: Node.Index) ?[]const u8 {
    var node = target;
    for (0..max_target_depth) |_| {
        switch (tree.nodeTag(node)) {
            .identifier => return named_root(tree.tokenSlice(tree.nodeMainToken(node))),
            .deref => node = tree.nodeData(node).node,
            .field_access => node = tree.nodeData(node).node_and_token[0],
            else => return null,
        }
    }
    return null;
}

fn named_root(root: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, root, discard_target)) return null;
    return root;
}

/// True when an expression is `try <call>(...)` over a function the acquire lists name.
fn is_acquire(comptime config: Config, tree: *const Ast, expression: Node.Index) bool {
    if (tree.nodeTag(expression) != .@"try") return false;
    const call = tree.nodeData(expression).node;
    if (!ast.is_call(tree.nodeTag(call))) return false;
    var buffer: [ast.max_chain_bytes]u8 = undefined;
    const chain = ast.chain_text(tree, ast.callee(tree, call), &buffer) orelse return false;
    return named_by(ast.last_segment(chain), config.acquire_prefixes, config.acquire_suffixes);
}

/// True when `last` starts with one of `prefixes` or ends with one of `suffixes`.
fn named_by(last: []const u8, prefixes: []const []const u8, suffixes: []const []const u8) bool {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, last, prefix)) return true;
    }
    for (suffixes) |suffix| {
        if (std.mem.endsWith(u8, last, suffix)) return true;
    }
    return false;
}

fn any_can_fail(comptime config: Config, tree: *const Ast, statements: []const Node.Index) bool {
    for (statements) |statement| {
        if (ast.can_fail(tree, statement, config.parameter_types)) return true;
    }
    return false;
}

/// How many statements stand between the acquire and the call that releases it, or every
/// statement under it when no such call appears: nothing bounds the window then.
fn release_index(
    comptime config: Config,
    tree: *const Ast,
    acquired: []const u8,
    below: []const Node.Index,
) usize {
    for (below, 0..) |statement, index| {
        var state: Releases(config) = .{ .acquired = acquired };
        search(config, tree, statement, &state);
        if (state.found) return index;
    }
    return below.len;
}

/// True when a `defer` or an `errdefer` under the acquire, in the same block, names it.
fn deferred_release(
    comptime config: Config,
    tree: *const Ast,
    acquired: []const u8,
    below: []const Node.Index,
) bool {
    for (below) |statement| {
        const deferred = deferred_expression(tree, statement) orelse continue;
        if (ast.mentions(tree, deferred, acquired, config.parameter_types)) return true;
    }
    return false;
}

/// The expression a `defer` or an `errdefer` runs later, or null for every other statement.
fn deferred_expression(tree: *const Ast, statement: Node.Index) ?Node.Index {
    return switch (tree.nodeTag(statement)) {
        .@"defer" => tree.nodeData(statement).node,
        .@"errdefer" => tree.nodeData(statement).opt_token_and_node[1],
        else => null,
    };
}

/// True when a `return` under the acquire names it: the caller owns it from there.
fn returned(
    comptime config: Config,
    tree: *const Ast,
    acquired: []const u8,
    below: []const Node.Index,
) bool {
    var state: Returns(config) = .{ .acquired = acquired };
    for (below) |statement| search(config, tree, statement, &state);
    return state.found;
}

/// Hands every node of the subtree at `node` to `state.note`.
fn search(
    comptime config: Config,
    tree: *const Ast,
    node: Node.Index,
    state: anytype,
) void {
    var walker: Search(config, @TypeOf(state.*)) = .{ .tree = tree, .state = state };
    walker.child(node);
}

fn Search(comptime config: Config, comptime State: type) type {
    return struct {
        tree: *const Ast,
        state: *State,
        depth: u32 = 0,

        pub fn child(self: *@This(), node: Node.Index) void {
            self.depth += 1;
            defer self.depth -= 1;
            std.debug.assert(self.depth <= ast.max_tree_depth);
            self.state.note(self.tree, node);
            ast.for_each_child_reading(self.tree, node, config.parameter_types, self);
        }
    };
}

/// Whether one statement calls a release named by the configuration over the acquired value.
fn Releases(comptime config: Config) type {
    return struct {
        acquired: []const u8,
        found: bool = false,

        fn note(self: *@This(), tree: *const Ast, node: Node.Index) void {
            if (!ast.is_call(tree.nodeTag(node))) return;
            var buffer: [ast.max_chain_bytes]u8 = undefined;
            const callee = ast.callee(tree, node);
            const chain = ast.chain_text(tree, callee, &buffer) orelse return;
            const last = ast.last_segment(chain);
            if (!named_by(last, config.release_prefixes, config.release_suffixes)) return;
            if (ast.mentions(tree, node, self.acquired, config.parameter_types)) self.found = true;
        }
    };
}

/// Whether one statement returns the acquired value.
fn Returns(comptime config: Config) type {
    return struct {
        acquired: []const u8,
        found: bool = false,

        fn note(self: *@This(), tree: *const Ast, node: Node.Index) void {
            if (tree.nodeTag(node) != .@"return") return;
            const value = tree.nodeData(node).opt_node.unwrap() orelse return;
            if (ast.mentions(tree, value, self.acquired, config.parameter_types)) self.found = true;
        }
    };
}

test {
    _ = @import("unreleased_acquire_test.zig");
}
