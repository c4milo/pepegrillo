//! The scans the unbounded-loop checks read one loop with:
//!
//! - `scan_loop`: whether a `break` appears in the loop, and whether a bound is named anywhere in
//!   its condition, continue expression or body.
//! - `scan_body`: whether the body or the continue expression can change a bare-chain condition.
//! - `length_read_against_literal`: whether a condition compares a length read against an integer
//!   literal.
//!
//! Split off `unbounded_loop.zig` so that file holds the configuration and the checks, and this
//! one holds the reads.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const ast = @import("../ast.zig");

/// What names a bound. A chain names a bound when it holds a segment equal to one of `segments`,
/// or when its last segment ends with one of `last_segment_suffixes`. Both lists empty means no
/// chain names a bound.
pub const Bound = struct {
    /// `constants` makes `constants.frame_count` a bound.
    segments: []const []const u8 = &.{},
    /// `_max` makes `limits.frame_count_max` and `frame_count_max` a bound.
    last_segment_suffixes: []const []const u8 = &.{},

    pub fn names(self: Bound, chain: []const u8) bool {
        for (self.segments) |segment| {
            if (ast.has_segment(chain, segment)) return true;
        }
        const last = ast.last_segment(chain);
        for (self.last_segment_suffixes) |suffix| {
            if (std.mem.endsWith(u8, last, suffix)) return true;
        }
        return false;
    }
};

/// What one loop's condition, continue expression and body hold: whether a `break` appears, and
/// whether a bound is named.
pub const LoopScan = struct {
    tree: *const Ast,
    bound: Bound,
    parameter_types: ast.ParameterTypes,
    has_break: bool = false,
    names_bound: bool = false,
    depth: u32 = 0,

    pub fn child(self: *LoopScan, node: Node.Index) void {
        self.depth += 1;
        defer self.depth -= 1;
        std.debug.assert(self.depth <= ast.max_tree_depth);
        if (self.tree.nodeTag(node) == .@"break") self.has_break = true;
        var buffer: [ast.max_chain_bytes]u8 = undefined;
        if (ast.chain_text(self.tree, node, &buffer)) |chain| {
            // A chain holds no break and no further chain, so it is read whole and not descended
            // into.
            if (self.bound.names(chain)) self.names_bound = true;
            return;
        }
        ast.for_each_child_reading(self.tree, node, self.parameter_types, self);
    }
};

pub fn scan_loop(
    tree: *const Ast,
    loop: Ast.full.While,
    bound: Bound,
    parameter_types: ast.ParameterTypes,
) LoopScan {
    var scan: LoopScan = .{ .tree = tree, .bound = bound, .parameter_types = parameter_types };
    scan.child(loop.ast.cond_expr);
    scan.child(loop.ast.then_expr);
    if (loop.ast.cont_expr.unwrap()) |continue_expression| scan.child(continue_expression);
    return scan;
}

/// What one loop's body and continue expression hold that may end a loop whose condition is the
/// chain `condition`: a `break`, or a change the AST cannot rule out.
pub const BodyScan = struct {
    tree: *const Ast,
    condition: []const u8,
    /// The name the loop's `|payload|` capture binds, when it has one.
    payload: ?[]const u8,
    parameter_types: ast.ParameterTypes,
    has_break: bool = false,
    may_change: bool = false,
    depth: u32 = 0,

    pub fn child(self: *BodyScan, node: Node.Index) void {
        self.depth += 1;
        defer self.depth -= 1;
        std.debug.assert(self.depth <= ast.max_tree_depth);
        const tag = self.tree.nodeTag(node);
        if (tag == .@"break") self.has_break = true;
        if (tag == .assign_destructure) self.may_change = true;
        if (is_assignment(tag)) self.note_target(self.tree.nodeData(node).node_and_node[0]);
        if (tag == .address_of) self.note_target(self.tree.nodeData(node).node);
        if (ast.is_call(tag)) self.note_call(node);
        ast.for_each_child_reading(self.tree, node, self.parameter_types, self);
    }

    /// An assignment to, or the address of, a chain related to the condition.
    fn note_target(self: *BodyScan, target: Node.Index) void {
        var buffer: [ast.max_chain_bytes]u8 = undefined;
        const chain = ast.chain_text(self.tree, target, &buffer) orelse return;
        if (is_related(chain, self.condition)) self.may_change = true;
    }

    /// A call through the condition's root or the payload capture, or a call passing either, may
    /// change the condition.
    fn note_call(self: *BodyScan, node: Node.Index) void {
        var call_buffer: [1]Node.Index = undefined;
        const call = self.tree.fullCall(&call_buffer, node).?;
        var buffer: [ast.max_chain_bytes]u8 = undefined;
        if (ast.chain_text(self.tree, call.ast.fn_expr, &buffer)) |callee| {
            const through_field = self.tree.nodeTag(call.ast.fn_expr) == .field_access;
            if (through_field and self.is_condition_root(ast.first_segment(callee))) {
                self.may_change = true;
            }
        }
        for (call.ast.params) |parameter| {
            const argument = ast.chain_text(self.tree, parameter, &buffer) orelse continue;
            if (self.is_condition_root(ast.first_segment(argument))) self.may_change = true;
        }
    }

    /// True when `segment` names the condition's root or the payload capture.
    fn is_condition_root(self: *const BodyScan, segment: []const u8) bool {
        if (std.mem.eql(u8, segment, ast.first_segment(self.condition))) return true;
        const payload = self.payload orelse return false;
        return std.mem.eql(u8, segment, payload);
    }
};

pub fn scan_body(
    tree: *const Ast,
    loop: Ast.full.While,
    condition: []const u8,
    parameter_types: ast.ParameterTypes,
) BodyScan {
    var scan: BodyScan = .{
        .tree = tree,
        .condition = condition,
        .payload = payload_name(tree, loop),
        .parameter_types = parameter_types,
    };
    scan.child(loop.ast.then_expr);
    if (loop.ast.cont_expr.unwrap()) |continue_expression| scan.child(continue_expression);
    return scan;
}

/// The name the loop's `|payload|` capture binds, past the `*` of a pointer capture, or null for a
/// loop without one.
fn payload_name(tree: *const Ast, loop: Ast.full.While) ?[]const u8 {
    var token = loop.payload_token orelse return null;
    if (tree.tokenTag(token) == .asterisk) token += 1;
    return tree.tokenSlice(token);
}

/// Every `assign*` tag but the destructuring one, whose targets are not a single node and which
/// `BodyScan` treats as a possible change outright.
fn is_assignment(tag: Node.Tag) bool {
    if (tag == .assign_destructure) return false;
    return std.mem.startsWith(u8, @tagName(tag), "assign");
}

/// True when one chain is the other, or a prefix of it at a dot boundary.
fn is_related(left: []const u8, right: []const u8) bool {
    return ast.has_prefix_at_dot(left, right) or ast.has_prefix_at_dot(right, left);
}

fn is_comparison(tag: Node.Tag) bool {
    return switch (tag) {
        .less_than,
        .less_or_equal,
        .greater_than,
        .greater_or_equal,
        .equal_equal,
        .bang_equal,
        => true,
        else => false,
    };
}

/// The chain of the length read in a comparison between a length read and an integer literal, or
/// null when the condition is any other expression.
pub fn length_read_against_literal(
    tree: *const Ast,
    node: Node.Index,
    reader_names: []const []const u8,
    buffer: *[ast.max_chain_bytes]u8,
) ?[]const u8 {
    if (!is_comparison(tree.nodeTag(node))) return null;
    const left, const right = tree.nodeData(node).node_and_node;
    const names = reader_names;
    if (tree.nodeTag(right) == .number_literal) return length_read(tree, left, names, buffer);
    if (tree.nodeTag(left) == .number_literal) return length_read(tree, right, names, buffer);
    return null;
}

/// The chain of a length read: `reader.remaining` for the call `reader.remaining()`, `chunk.len`
/// for the field `chunk.len`. Null when the expression is anything else.
fn length_read(
    tree: *const Ast,
    node: Node.Index,
    reader_names: []const []const u8,
    buffer: *[ast.max_chain_bytes]u8,
) ?[]const u8 {
    const read = if (ast.is_call(tree.nodeTag(node))) ast.callee(tree, node) else node;
    const chain = ast.chain_text(tree, read, buffer) orelse return null;
    const last = ast.last_segment(chain);
    for (reader_names) |reader_name| {
        if (std.mem.eql(u8, last, reader_name)) return chain;
    }
    return null;
}

// Tests. The rule's tests, which drive these scans through whole files, are in
// `unbounded_loop_test.zig`.

const testing = std.testing;

test "a bound is a listed segment anywhere in the chain or a listed suffix on its last segment" {
    const bound: Bound = .{ .segments = &.{"limits"}, .last_segment_suffixes = &.{"_max"} };
    try testing.expect(bound.names("limits.frame_count"));
    try testing.expect(bound.names("self.limits.frame_count"));
    try testing.expect(bound.names("frame_count_max"));
    try testing.expect(bound.names("config.frame_count_max"));
    try testing.expect(!bound.names("limitsx.frame_count"));
    try testing.expect(!bound.names("frame_count_max.value"));
    try testing.expect(!(Bound{}).names("limits.frame_count_max"));
}

test "is_assignment names every assignment tag but destructuring" {
    try testing.expect(is_assignment(.assign));
    try testing.expect(is_assignment(.assign_add_wrap));
    try testing.expect(!is_assignment(.assign_destructure));
    try testing.expect(!is_assignment(.add));
}

test "is_related holds for a chain, its prefixes and its extensions at a dot boundary" {
    try testing.expect(is_related("self.state", "self.state.running"));
    try testing.expect(is_related("self.state.running", "self.state"));
    try testing.expect(is_related("running", "running"));
    try testing.expect(!is_related("self.stat", "self.state"));
}
