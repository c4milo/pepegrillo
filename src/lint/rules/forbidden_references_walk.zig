//! The walk of the forbidden-references rule: one pass over a parsed file that applies the four
//! checks `forbidden_references.zig` states, in the order the rule's header gives them.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const ast = @import("../ast.zig");
const report = @import("../report.zig");
const rule = @import("forbidden_references.zig");
const Config = rule.Config;

/// The name check 4 reports a prototype under when it has no name token: a function type in a
/// field or a variable, `fn (Allocator) void`.
pub const anonymous_function_name = "an anonymous function type";

/// Applies every check `config` enables to `tree`, reporting under `path`.
pub fn scan(
    context: *report.Context,
    path: []const u8,
    tree: *const Ast,
    config: *const Config,
) !void {
    var visitor: Visitor = .{
        .tree = tree,
        .findings = &context.findings,
        .path = path,
        .config = config,
    };
    for (tree.rootDecls()) |declaration| visitor.child(declaration);
    if (visitor.failure) |failure| return failure;
}

const Visitor = struct {
    tree: *const Ast,
    findings: *report.Findings,
    path: []const u8,
    config: *const Config,
    depth: u32 = 0,
    failure: ?anyerror = null,

    pub fn child(self: *Visitor, node: Node.Index) void {
        self.depth += 1;
        defer self.depth -= 1;
        std.debug.assert(self.depth <= ast.max_tree_depth);
        self.visit(node) catch |failure| {
            self.failure = failure;
        };
    }

    fn visit(self: *Visitor, node: Node.Index) !void {
        var buffer: [ast.max_chain_bytes]u8 = undefined;
        if (ast.chain_text(self.tree, node, &buffer)) |chain| {
            // A chain has no children beside its own segments, so it is read whole and never
            // descended into.
            if (!rule.is_forbidden_chain(self.config, chain)) return;
            return self.add_reference(ast.node_start_location(self.tree, node), chain);
        }
        const tag = self.tree.nodeTag(node);
        if (ast.is_call(tag)) try self.visit_call(node);
        ast.for_each_child_reading(self.tree, node, self.config.parameter_types, self);
        // A `fn_decl` holds its prototype as a child, which the walk has just read. The check runs
        // after the children, so a forbidden chain that starts a parameter's type is recorded
        // before the parameter finding at the same token.
        if (tag != .fn_decl) try self.visit_prototype(node);
    }

    fn visit_call(self: *Visitor, node: Node.Index) !void {
        const callee = ast.callee(self.tree, node);
        var buffer: [ast.max_chain_bytes]u8 = undefined;
        const chain = ast.chain_text(self.tree, callee, &buffer) orelse return;
        try self.visit_method_call(callee, chain);
        // A chain check 1 forbids is reported when the callee is visited as a child.
        if (!rule.is_forbidden_callee(self.config, chain)) return;
        try self.add_reference(ast.node_start_location(self.tree, callee), chain);
    }

    fn visit_method_call(self: *Visitor, callee: Node.Index, chain: []const u8) !void {
        if (self.tree.nodeTag(callee) != .field_access) return;
        const method = ast.last_segment(chain);
        const receiver = chain[0 .. chain.len - method.len - 1];
        if (!rule.is_forbidden_method_call(&self.config.method_calls, method, receiver)) return;
        _, const name_token = self.tree.nodeData(callee).node_and_token;
        try self.add_reference(ast.token_location(self.tree, name_token), method);
    }

    fn visit_prototype(self: *Visitor, node: Node.Index) !void {
        const parameter_check = self.config.parameter_check orelse return;
        var buffer: [1]Node.Index = undefined;
        const prototype = self.tree.fullFnProto(&buffer, node) orelse return;
        const function_name = if (prototype.name_token) |token|
            self.tree.tokenSlice(token)
        else
            anonymous_function_name;
        for (prototype.ast.params) |parameter| {
            if (!names_segment(self.tree, parameter, parameter_check.type_segment)) continue;
            const location = ast.node_start_location(self.tree, parameter);
            try self.add_parameter(location, function_name, parameter_check.description);
        }
    }

    fn add_reference(self: *Visitor, location: ast.Location, identifier: []const u8) !void {
        const line = location.line;
        const column = location.column;
        const name = self.config.name;
        const reason = self.config.reason orelse {
            return self.findings.add(name, self.path, line, column, "reference to {s}", .{
                identifier,
            });
        };
        try self.findings.add(name, self.path, line, column, "reference to {s}: {s}", .{
            identifier, reason,
        });
    }

    fn add_parameter(
        self: *Visitor,
        location: ast.Location,
        function_name: []const u8,
        description: []const u8,
    ) !void {
        const line = location.line;
        const column = location.column;
        const name = self.config.name;
        const reason = self.config.reason orelse {
            return self.findings.add(name, self.path, line, column, "{s} takes {s}", .{
                function_name, description,
            });
        };
        try self.findings.add(name, self.path, line, column, "{s} takes {s}: {s}", .{
            function_name, description, reason,
        });
    }
};

/// True when the type expression at `node` holds a chain with the segment `wanted` anywhere
/// inside it.
fn names_segment(tree: *const Ast, node: Node.Index, wanted: []const u8) bool {
    var search: TypeSearch = .{ .tree = tree, .wanted = wanted };
    search.child(node);
    return search.found;
}

/// Walks one parameter's type expression and records whether a chain in it holds `wanted`.
const TypeSearch = struct {
    tree: *const Ast,
    wanted: []const u8,
    found: bool = false,
    depth: u32 = 0,

    pub fn child(self: *TypeSearch, node: Node.Index) void {
        self.depth += 1;
        defer self.depth -= 1;
        std.debug.assert(self.depth <= ast.max_tree_depth);
        var buffer: [ast.max_chain_bytes]u8 = undefined;
        if (ast.chain_text(self.tree, node, &buffer)) |chain| {
            if (ast.has_segment(chain, self.wanted)) self.found = true;
            return;
        }
        ast.for_each_child(self.tree, node, self);
    }
};

// Tests. The walk's ordering and reach; the checks themselves are pinned in
// `forbidden_references_test.zig`.

const testing = std.testing;
const harness = @import("../harness.zig");

const ordering = rule.Rule(.{
    .name = "ordering",
    .scope = .{ .extensions = &.{".zig"} },
    .prefixes = &.{"std.heap"},
    .parameter_check = .{ .type_segment = "Allocator", .description = "an allocator" },
});

test "a chain that starts a parameter's type is recorded before the parameter finding" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), ordering, "src/store/page.zig",
        \\fn grow(pool: std.heap.Allocator) void {}
    );
    try harness.expect_messages(findings, &.{
        "reference to std.heap.Allocator",
        "grow takes an allocator",
    });
    try testing.expectEqual(findings[0].column, findings[1].column);
}

test "the walk reaches a chain nested inside an expression and a call's arguments" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), ordering, "src/store/page.zig",
        \\fn open(name: []const u8) !void {
        \\    if (name.len == 0) return;
        \\    const pages = try load(name, std.heap.page_allocator, .{});
        \\    _ = pages;
        \\}
    );
    try harness.expect_messages(findings, &.{"reference to std.heap.page_allocator"});
    try testing.expectEqual(3, findings[0].line);
    try testing.expectEqual(34, findings[0].column);
}
