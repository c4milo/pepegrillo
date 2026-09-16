//! unbounded-loop: a `while` loop whose shape shows that nothing bounds how many times it runs.
//!
//! Over every Zig file `scope` selects, the rule reads every `while` loop and makes up to three
//! checks. The configuration switches each one on.
//!
//! 1. `forever`: a `while (true)`.
//!    - `.always` reports every one, with or without a `break`: a `break` ends the loop on some
//!      condition, but nothing bounds how many iterations run before it.
//!    - `.unless_bounded_break` reports one whose body holds no `break`, and one whose body holds
//!      a `break` while the loop names no bound.
//! 2. `unchanged_condition`: a `while (condition)` whose condition is a bare identifier or a
//!    field-access chain, such as `running` or `self.state.running`, when the AST alone shows the
//!    body cannot end the loop. The body and the continue expression hold no `break`, no
//!    assignment whose target is the condition or a prefix or extension of it, no `&` taken of
//!    such a target, no destructuring assignment, and no call that names the condition's root or
//!    the loop's `|payload|` capture as its receiver or as an argument. Any of those may change
//!    the condition, and without types the AST cannot say that one does not, so such a loop is
//!    not reported. A `break` that belongs to a nested loop counts too: the check reports fewer
//!    loops rather than a false one.
//! 3. `length_read`: a condition that compares a length read against an integer literal, such as
//!    `while (reader.remaining() > 0)` or `while (chunk.len != 0)`, when the loop names no bound.
//!    A length read is a call or a field whose last name is one of `length_reader_names`.
//!
//! The loop names a bound when a chain that `bound` accepts appears anywhere in its condition,
//! continue expression or body.
//!
//! `while (false)` is never reported. A condition of any other shape, such as `index < count`,
//! `!done` or `iterator.next()`, is outside checks 1 and 2, and outside check 3 unless it compares
//! a length read against a literal. `for` loops are not read.
//!
//! What the rule cannot do. It reads the shape of the source and not its arithmetic, so it cannot
//! prove that a bound it found is what limits the loop, and it does not follow a bound through a
//! local constant. A loop it passes is not proved bounded.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const ast = @import("../ast.zig");
const report = @import("../report.zig");
const Scope = @import("../scope.zig").Scope;
const scan = @import("unbounded_loop_scan.zig");

pub const Bound = scan.Bound;

/// The condition text of check 1.
const forever_condition = "true";

/// The condition of a loop that never runs. It is a literal and not a value the body could change,
/// so check 2 skips it.
const never_condition = "false";

/// Which `while (true)` loops check 1 reports.
pub const ForeverPolicy = enum {
    /// Check 1 is off.
    off,
    /// Every `while (true)`, with `messages.forever`.
    always,
    /// A `while (true)` with no `break`, with `messages.forever_without_break`, and one with a
    /// `break` whose loop names no bound, with `messages.forever_without_bound`.
    unless_bounded_break,
};

/// The finding texts. Each is a `std.fmt` format string, so a literal brace is written `{{` or
/// `}}`, and each must use every argument its comment names.
pub const Messages = struct {
    /// Check 1 under `.always`. No arguments.
    forever: []const u8 = "while (true) has no bound",
    /// Check 1 under `.unless_bounded_break`, a loop with no `break`. No arguments.
    forever_without_break: []const u8 = "while (true) has no break; nothing ends the loop",
    /// Check 1 under `.unless_bounded_break`, a loop with a `break` and no bound. No arguments.
    forever_without_bound: []const u8 = "while (true) breaks on no named bound",
    /// Check 2. `condition`: the condition chain.
    unchanged_condition: []const u8 = "while ({[condition]s}) has no break and the body never" ++
        " assigns {[condition]s}",
    /// Check 3. `read`: the chain of the length read, without the call parentheses.
    length_read: []const u8 = "the condition reads {[read]s} against a literal and the loop" ++
        " names no bound",
};

/// The last names check 3 reads as a length read unless the configuration names others.
pub const default_length_reader_names = [_][]const u8{
    "remaining",
    "len",
    "size",
    "count",
    "bytes_remaining",
    "bytes_left",
};

pub const Config = struct {
    /// The name `--rule` selects and the report prints.
    name: []const u8 = "unbounded-loop",
    /// The files the rule reads. A file that does not parse is skipped.
    scope: Scope,
    /// Check 1.
    forever: ForeverPolicy = .off,
    /// Check 2.
    unchanged_condition: bool = false,
    /// Check 3.
    length_read: bool = false,
    /// What names a bound, for check 1 under `.unless_bounded_break` and for check 3.
    bound: Bound = .{},
    /// The last names of a length read, for check 3.
    length_reader_names: []const []const u8 = &default_length_reader_names,
    messages: Messages = .{},
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

/// The walk over every node of one file. `child` is what `ast.for_each_child_reading` calls; the checks
/// are the functions below it, which take the configuration as a parameter.
fn Walker(comptime config: Config) type {
    return struct {
        tree: *const Ast,
        findings: *report.Findings,
        path: []const u8,
        depth: u32 = 0,
        /// The first error a check returned. `child` returns nothing, so the walk keeps it here
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
    if (ast.is_while(walker.tree.nodeTag(node))) try visit_while(config, walker, node);
    ast.for_each_child_reading(walker.tree, node, config.parameter_types, walker);
}

fn visit_while(comptime config: Config, walker: *Walker(config), node: Node.Index) !void {
    const loop = walker.tree.fullWhile(node).?;
    var buffer: [ast.max_chain_bytes]u8 = undefined;
    if (ast.chain_text(walker.tree, loop.ast.cond_expr, &buffer)) |condition| {
        if (std.mem.eql(u8, condition, forever_condition)) {
            return check_forever(config, walker, node, loop);
        }
        if (std.mem.eql(u8, condition, never_condition)) return;
        if (!config.unchanged_condition) return;
        return check_unchanged_condition(config, walker, node, loop, condition);
    }
    if (config.length_read) try check_length_read(config, walker, node, loop);
}

/// Check 1.
fn check_forever(
    comptime config: Config,
    walker: *Walker(config),
    node: Node.Index,
    loop: Ast.full.While,
) !void {
    switch (config.forever) {
        .off => {},
        .always => try add(config, walker, node, config.messages.forever, .{}),
        .unless_bounded_break => {
            const found = scan.scan_loop(walker.tree, loop, config.bound, config.parameter_types);
            if (!found.has_break) {
                return add(config, walker, node, config.messages.forever_without_break, .{});
            }
            if (found.names_bound) return;
            try add(config, walker, node, config.messages.forever_without_bound, .{});
        },
    }
}

/// Check 2.
fn check_unchanged_condition(
    comptime config: Config,
    walker: *Walker(config),
    node: Node.Index,
    loop: Ast.full.While,
    condition: []const u8,
) !void {
    const found = scan.scan_body(walker.tree, loop, condition, config.parameter_types);
    if (found.has_break or found.may_change) return;
    const arguments = .{ .condition = condition };
    try add(config, walker, node, config.messages.unchanged_condition, arguments);
}

/// Check 3.
fn check_length_read(
    comptime config: Config,
    walker: *Walker(config),
    node: Node.Index,
    loop: Ast.full.While,
) !void {
    if (scan.scan_loop(walker.tree, loop, config.bound, config.parameter_types).names_bound) return;
    var buffer: [ast.max_chain_bytes]u8 = undefined;
    const read = scan.length_read_against_literal(
        walker.tree,
        loop.ast.cond_expr,
        config.length_reader_names,
        &buffer,
    ) orelse return;
    try add(config, walker, node, config.messages.length_read, .{ .read = read });
}

/// Reports one finding at the loop's `while` keyword.
fn add(
    comptime config: Config,
    walker: *Walker(config),
    node: Node.Index,
    comptime format: []const u8,
    arguments: anytype,
) !void {
    const location = ast.node_location(walker.tree, node);
    const findings = walker.findings;
    try findings.add(config.name, walker.path, location.line, location.column, format, arguments);
}

test {
    _ = scan;
    _ = @import("unbounded_loop_test.zig");
}
