//! kept-options-pointer: an `init` copies what it keeps of a `*const` parameter.
//!
//! TigerStyle passes an argument over 16 bytes as `*const`, so the caller makes no copy on the
//! stack. The standard library copies an options struct, such as `std.Thread.SpawnConfig`, and
//! keeps no pointer to it. An `init` that stores the pointer itself makes the caller keep the
//! options alive for the life of the value, and no type states that rule. docs/api.md gives the
//! form that satisfies both: take `*const`, and copy what the value keeps.
//!
//! Over every Zig file in `scope`, the rule reads each `pub` function declared as a member of a
//! container whose name is one of `function_names`. A `*const` parameter is one whose type is a
//! single-item pointer to `const`. The self parameter is the first parameter whose type is a
//! single-item pointer that is not `const`. In the function's body, the rule reports:
//!
//! 1. An assignment to a field of the self parameter, `self.config = config`, or to the whole of
//!    it, `self.* = .{ .config = config }`.
//! 2. A `return` of a struct literal, `return .{ .config = config }`.
//!
//! It reports a value that is a `*const` parameter, or the address of a field of one, such as
//! `&config.limits`. A struct literal inside a struct literal is read too. The message is `<function>
//! keeps the *const parameter <parameter> in .<field> after it returns: copy what it keeps`.
//!
//! The rule reads syntax, so it does not see a pointer that reaches a field through a local
//! variable, a helper function, or a call such as `append`. It does not see a slice or a
//! many-item pointer, nor a field of a `*const` parameter that is itself a pointer or a slice.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const ast = @import("../ast.zig");
const report = @import("../report.zig");
const Scope = @import("../scope.zig").Scope;

/// The most parameters of one function the rule reads. A function with more is read for the
/// first ones alone.
pub const parameters_max: usize = 32;

pub const Config = struct {
    /// The rule name findings are reported under and `--rule` selects.
    name: []const u8 = "kept-options-pointer",
    /// The files the rule reads.
    scope: Scope,
    /// The names of the functions the rule reads.
    function_names: []const []const u8 = &.{"init"},
};

/// The rule for one configuration: a type with the `name` and `check` the driver dispatches to.
pub fn Rule(comptime config: Config) type {
    comptime std.debug.assert(config.name.len != 0);
    comptime std.debug.assert(config.function_names.len != 0);
    return struct {
        pub const name = config.name;
        const settings: Config = config;

        pub fn check(context: *report.Context, file: report.File) !void {
            if (!settings.scope.applies(file.path)) return;
            const tree = file.tree orelse return;
            var visitor: Visitor = .{
                .tree = tree,
                .findings = &context.findings,
                .path = file.path,
                .name = settings.name,
                .function_names = settings.function_names,
            };
            visitor.check_members(tree.rootDecls());
            for (tree.rootDecls()) |declaration| visitor.child(declaration);
            if (visitor.failure) |failure| return failure;
        }
    };
}

/// Walks every container of a file and hands each member function the configuration names to a
/// `Body`.
const Visitor = struct {
    tree: *const Ast,
    findings: *report.Findings,
    path: []const u8,
    name: []const u8,
    function_names: []const []const u8,
    depth: u32 = 0,
    failure: ?anyerror = null,

    pub fn child(self: *Visitor, node: Node.Index) void {
        self.depth += 1;
        defer self.depth -= 1;
        std.debug.assert(self.depth <= ast.max_tree_depth);
        var buffer: [2]Node.Index = undefined;
        if (self.tree.fullContainerDecl(&buffer, node)) |container| {
            self.check_members(container.ast.members);
        }
        ast.for_each_child(self.tree, node, self);
    }

    fn check_members(self: *Visitor, members: []const Node.Index) void {
        for (members) |member| {
            if (self.tree.nodeTag(member) != .fn_decl) continue;
            self.check_function(member);
        }
    }

    fn check_function(self: *Visitor, declaration: Node.Index) void {
        const prototype_node, const body_node = self.tree.nodeData(declaration).node_and_node;
        var buffer: [1]Node.Index = undefined;
        const prototype = self.tree.fullFnProto(&buffer, prototype_node).?;
        const visibility = prototype.visib_token orelse return;
        if (self.tree.tokenTag(visibility) != .keyword_pub) return;
        const name_token = prototype.name_token orelse return;
        const function_name = self.tree.tokenSlice(name_token);
        if (!is_any_of(function_name, self.function_names)) return;
        var body: Body = .{ .visitor = self, .function_name = function_name };
        body.read_parameters(prototype);
        body.child(body_node);
    }
};

/// Reads one function's body for the assignments and returns the rule reports.
const Body = struct {
    visitor: *Visitor,
    function_name: []const u8,
    self_name: ?[]const u8 = null,
    pointers: [parameters_max][]const u8 = undefined,
    pointers_count: usize = 0,
    depth: u32 = 0,

    fn read_parameters(body: *Body, prototype: Ast.full.FnProto) void {
        const tree = body.visitor.tree;
        var parameters = prototype.iterate(tree);
        var read: usize = 0;
        while (parameters.next()) |parameter| : (read += 1) {
            if (read == parameters_max) break;
            const name_token = parameter.name_token orelse continue;
            const type_node = parameter.type_expr orelse continue;
            const pointer = tree.fullPtrType(type_node) orelse continue;
            if (pointer.size != .one) continue;
            if (pointer.const_token != null) {
                body.pointers[body.pointers_count] = tree.tokenSlice(name_token);
                body.pointers_count += 1;
            } else if (body.self_name == null) {
                body.self_name = tree.tokenSlice(name_token);
            }
        }
        std.debug.assert(body.pointers_count <= parameters_max);
    }

    pub fn child(body: *Body, node: Node.Index) void {
        body.depth += 1;
        defer body.depth -= 1;
        std.debug.assert(body.depth <= ast.max_tree_depth);
        const tree = body.visitor.tree;
        var buffer: [2]Node.Index = undefined;
        // A nested container's functions are the container walk's to read.
        if (tree.fullContainerDecl(&buffer, node) != null) return;
        switch (tree.nodeTag(node)) {
            .assign => body.check_assign(node),
            .@"return" => if (tree.nodeData(node).opt_node.unwrap()) |value| body.check_literal(value),
            else => {},
        }
        ast.for_each_child(tree, node, body);
    }

    fn check_assign(body: *Body, node: Node.Index) void {
        const tree = body.visitor.tree;
        const self_name = body.self_name orelse return;
        const target, const value = tree.nodeData(node).node_and_node;
        if (tree.nodeTag(target) == .deref) {
            const operand = tree.nodeData(target).node;
            if (!is_identifier(tree, operand, self_name)) return;
            return body.check_literal(value);
        }
        var chain_buffer: [ast.max_chain_bytes]u8 = undefined;
        const chain = ast.chain_text(tree, target, &chain_buffer) orelse return;
        // A chain of the self parameter alone is an assignment to a parameter, which Zig refuses.
        if (!std.mem.eql(u8, ast.first_segment(chain), self_name)) return;
        body.check_value(value, ast.last_segment(chain));
    }

    /// Reads each field of a struct literal, and of each struct literal one of its fields holds.
    fn check_literal(body: *Body, node: Node.Index) void {
        const tree = body.visitor.tree;
        var buffer: [2]Node.Index = undefined;
        const literal = tree.fullStructInit(&buffer, node) orelse return;
        for (literal.ast.fields) |field_value| {
            const field_name = tree.tokenSlice(tree.firstToken(field_value) - 2);
            body.check_value(field_value, field_name);
            body.check_literal(field_value);
        }
    }

    fn check_value(body: *Body, value: Node.Index, field_name: []const u8) void {
        const parameter = body.kept_pointer(value) orelse return;
        const location = ast.node_start_location(body.visitor.tree, value);
        body.visitor.findings.add(
            body.visitor.name,
            body.visitor.path,
            location.line,
            location.column,
            "{s} keeps the *const parameter {s} in .{s} after it returns: copy what it keeps",
            .{ body.function_name, parameter, field_name },
        ) catch |failure| {
            body.visitor.failure = failure;
        };
    }

    /// The `*const` parameter `value` keeps: the parameter itself, or the address of a field of it.
    fn kept_pointer(body: *const Body, value: Node.Index) ?[]const u8 {
        const tree = body.visitor.tree;
        var chain_buffer: [ast.max_chain_bytes]u8 = undefined;
        if (tree.nodeTag(value) == .address_of) {
            const chain = ast.chain_text(tree, tree.nodeData(value).node, &chain_buffer) orelse
                return null;
            if (std.mem.findScalar(u8, chain, '.') == null) return null;
            return body.pointer_named(ast.first_segment(chain));
        }
        if (tree.nodeTag(value) != .identifier) return null;
        return body.pointer_named(tree.tokenSlice(tree.nodeMainToken(value)));
    }

    fn pointer_named(body: *const Body, identifier: []const u8) ?[]const u8 {
        for (body.pointers[0..body.pointers_count]) |pointer| {
            if (std.mem.eql(u8, pointer, identifier)) return pointer;
        }
        return null;
    }
};

fn is_identifier(tree: *const Ast, node: Node.Index, wanted: []const u8) bool {
    if (tree.nodeTag(node) != .identifier) return false;
    return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), wanted);
}

fn is_any_of(value: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

test {
    _ = @import("kept_options_pointer_test.zig");
}
