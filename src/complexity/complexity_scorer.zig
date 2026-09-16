//! Scores one parsed Zig file against SonarSource's Cognitive Complexity definition.
//! `complexity.zig` states the mapping from that definition onto Zig syntax; this file is the
//! walk that applies it. The tests are `complexity_scorer_test.zig` and
//! `complexity_scorer_declaration_test.zig`.
//!
//! Two walks run over each file. `Collector` records every `fn` declaration with a body and every
//! `test` block, at any container depth. `Scorer` then walks one body and adds one increment per
//! construct, carrying the nesting level down the recursion so that no rule looks back up the
//! tree. Both walks hand children over through `for_each_child` in `../lint/ast.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Node = Ast.Node;
const ast = @import("../lint/ast.zig");
const for_each_child = ast.for_each_child;

/// Deepest AST node either walk recurses into, shared with the lint rules. A file nested deeper
/// is reported as `error.NestingTooDeep` rather than scored.
pub const max_tree_depth = ast.max_tree_depth;

/// Functions and test blocks recorded per file. A file holding more is reported as
/// `error.TooManyFunctions` rather than scored in part.
pub const max_functions_per_file: usize = 4096;

/// One scored function or test block. `path` and `name` are owned by the arena passed to
/// `score_source`, so a result outlives the parsed tree.
pub const FunctionScore = struct {
    path: []const u8,
    /// 1-based line of the name token.
    line: usize,
    /// 1-based column of the name token. Orders two declarations that share a line; never
    /// printed.
    column: usize,
    name: []const u8,
    score: u32,
};

pub const ScoreError = error{ ParseFailed, TooManyFunctions, NestingTooDeep } || Allocator.Error;

fn is_block(tag: Node.Tag) bool {
    return switch (tag) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => true,
        else => false,
    };
}

/// Walks a whole tree and records every declaration that carries a body.
const Collector = struct {
    tree: *const Ast,
    declarations: *std.ArrayList(Node.Index),
    depth: u32 = 0,
    truncated: bool = false,
    too_deep: bool = false,

    pub fn child(self: *Collector, node: Node.Index) void {
        if (self.depth >= max_tree_depth) {
            self.too_deep = true;
            return;
        }
        self.depth += 1;
        defer self.depth -= 1;
        const tag = self.tree.nodeTag(node);
        if (tag == .fn_decl or tag == .test_decl) self.record(node);
        for_each_child(self.tree, node, self);
    }

    fn record(self: *Collector, node: Node.Index) void {
        if (self.declarations.items.len >= max_functions_per_file) {
            self.truncated = true;
            return;
        }
        self.declarations.appendAssumeCapacity(node);
    }
};

/// Scores one body. `nesting` travels down the recursion as an argument; `score`, `depth` and
/// `too_deep` are the only mutable state.
const Scorer = struct {
    tree: *const Ast,
    function_name: []const u8,
    score: u32 = 0,
    depth: u32 = 0,
    too_deep: bool = false,

    /// Adapter `for_each_child` calls: every child of a node that carries no increment keeps its
    /// parent's nesting level.
    const ChildVisitor = struct {
        scorer: *Scorer,
        nesting: u32,

        pub fn child(self: ChildVisitor, node: Node.Index) void {
            self.scorer.visit(node, self.nesting);
        }
    };

    /// An `if` written after an `else` adds 1 in total rather than 2, and its body sits at the
    /// level of the first `if`'s body.
    const IfKind = enum { fresh, else_if };

    fn visit(self: *Scorer, node: Node.Index, nesting: u32) void {
        if (self.depth >= max_tree_depth) {
            self.too_deep = true;
            return;
        }
        self.depth += 1;
        defer self.depth -= 1;
        switch (self.tree.nodeTag(node)) {
            .if_simple, .@"if" => self.visit_if(node, nesting, .fresh),
            .while_simple, .while_cont, .@"while" => self.visit_while(node, nesting),
            .for_simple, .@"for" => self.visit_for(node, nesting),
            .@"switch", .switch_comma => self.visit_switch(node, nesting),
            .@"catch" => self.visit_catch(node, nesting),
            .@"orelse" => self.visit_orelse(node, nesting),
            .bool_and, .bool_or => self.visit_logical_sequence(node, nesting),
            .@"break", .@"continue" => self.visit_jump(node, nesting),
            .call_one, .call_one_comma, .call, .call_comma => self.visit_call(node, nesting),
            .fn_decl => self.visit_nested_function(node, nesting),
            else => self.visit_children(node, nesting),
        }
    }

    fn visit_children(self: *Scorer, node: Node.Index, nesting: u32) void {
        for_each_child(self.tree, node, ChildVisitor{ .scorer = self, .nesting = nesting });
    }

    fn visit_if(self: *Scorer, node: Node.Index, nesting: u32, kind: IfKind) void {
        const full_if = self.tree.fullIf(node).?;
        self.score += if (kind == .else_if) 1 else 1 + nesting;
        self.visit(full_if.ast.cond_expr, nesting);
        self.visit_branches(full_if.ast.then_expr, full_if.ast.else_expr, nesting);
    }

    /// The body of a structural construct sits one level deeper. An `else` adds 1 and raises no
    /// level of its own; an `else if` is scored as `.else_if`.
    fn visit_branches(
        self: *Scorer,
        then_expr: Node.Index,
        else_expr: Node.OptionalIndex,
        nesting: u32,
    ) void {
        self.visit(then_expr, nesting + 1);
        const else_node = else_expr.unwrap() orelse return;
        switch (self.tree.nodeTag(else_node)) {
            .if_simple, .@"if" => self.visit_if(else_node, nesting, .else_if),
            else => {
                self.score += 1;
                self.visit(else_node, nesting + 1);
            },
        }
    }

    fn visit_while(self: *Scorer, node: Node.Index, nesting: u32) void {
        const full_while = self.tree.fullWhile(node).?;
        self.score += 1 + nesting;
        self.visit(full_while.ast.cond_expr, nesting);
        if (full_while.ast.cont_expr.unwrap()) |cont_expr| self.visit(cont_expr, nesting + 1);
        self.visit_branches(full_while.ast.then_expr, full_while.ast.else_expr, nesting);
    }

    fn visit_for(self: *Scorer, node: Node.Index, nesting: u32) void {
        const full_for = self.tree.fullFor(node).?;
        self.score += 1 + nesting;
        for (full_for.ast.inputs) |input| self.visit(input, nesting);
        self.visit_branches(full_for.ast.then_expr, full_for.ast.else_expr, nesting);
    }

    /// One increment for the whole switch, never one per prong. Prong values and bodies sit one
    /// level deeper; prongs add no level of their own.
    fn visit_switch(self: *Scorer, node: Node.Index, nesting: u32) void {
        const full_switch = self.tree.fullSwitch(node).?;
        self.score += 1 + nesting;
        self.visit(full_switch.ast.condition, nesting);
        for (full_switch.ast.cases) |case_node| {
            const case = self.tree.fullSwitchCase(case_node).?;
            for (case.ast.values) |value| self.visit(value, nesting + 1);
            self.visit(case.ast.target_expr, nesting + 1);
        }
    }

    /// Every `catch` is structural: its operand, a block or an expression, sits one level deeper.
    fn visit_catch(self: *Scorer, node: Node.Index, nesting: u32) void {
        const lhs, const rhs = self.tree.nodeData(node).node_and_node;
        self.score += 1 + nesting;
        self.visit(lhs, nesting);
        self.visit(rhs, nesting + 1);
    }

    /// `orelse` whose operand is a block is structural and raises the level. `orelse return` and
    /// the like add 1 and raise no level.
    fn visit_orelse(self: *Scorer, node: Node.Index, nesting: u32) void {
        const lhs, const rhs = self.tree.nodeData(node).node_and_node;
        const structural = is_block(self.tree.nodeTag(rhs));
        self.score += if (structural) 1 + nesting else 1;
        self.visit(lhs, nesting);
        self.visit(rhs, if (structural) nesting + 1 else nesting);
    }

    /// One increment for a whole run of like operators. An operand joined by the same operator
    /// continues the run; any other operand starts a new expression, and a run inside it is
    /// counted on its own.
    fn visit_logical_sequence(self: *Scorer, node: Node.Index, nesting: u32) void {
        self.score += 1;
        self.visit_logical_operands(node, self.tree.nodeTag(node), nesting);
    }

    fn visit_logical_operands(
        self: *Scorer,
        node: Node.Index,
        operator: Node.Tag,
        nesting: u32,
    ) void {
        const lhs, const rhs = self.tree.nodeData(node).node_and_node;
        for ([_]Node.Index{ lhs, rhs }) |operand| {
            if (self.tree.nodeTag(operand) == operator) {
                self.visit_logical_operands(operand, operator, nesting);
            } else {
                self.visit(operand, nesting);
            }
        }
    }

    /// A `break` or `continue` that names a label adds 1. An unlabelled one adds nothing.
    fn visit_jump(self: *Scorer, node: Node.Index, nesting: u32) void {
        const label, const target = self.tree.nodeData(node).opt_token_and_opt_node;
        if (label != .none) self.score += 1;
        if (target.unwrap()) |target_node| self.visit(target_node, nesting);
    }

    fn visit_call(self: *Scorer, node: Node.Index, nesting: u32) void {
        var buffer: [1]Node.Index = undefined;
        const call = self.tree.fullCall(&buffer, node).?;
        if (self.is_recursive_callee(call.ast.fn_expr)) self.score += 1;
        self.visit(call.ast.fn_expr, nesting);
        for (call.ast.params) |param| self.visit(param, nesting);
    }

    /// A call through a field access (`self.name()`) adds nothing: the tool has no type
    /// information and cannot tell which function that names.
    fn is_recursive_callee(self: *const Scorer, callee: Node.Index) bool {
        if (self.tree.nodeTag(callee) != .identifier) return false;
        const callee_name = self.tree.tokenSlice(self.tree.nodeMainToken(callee));
        return std.mem.eql(u8, callee_name, self.function_name);
    }

    /// A function declared inside a body is scored twice: on its own, by the collector, and here
    /// as part of the enclosing body one level deeper. Its parameter and return types stay at the
    /// enclosing level.
    fn visit_nested_function(self: *Scorer, node: Node.Index, nesting: u32) void {
        const proto, const body = self.tree.nodeData(node).node_and_node;
        self.visit_children(proto, nesting);
        self.visit(body, nesting + 1);
    }
};

/// The name token and the body of one declaration. A `test` block with no name is named by its
/// own keyword.
fn name_and_body(tree: *const Ast, node: Node.Index) ?struct { Ast.TokenIndex, Node.Index } {
    if (tree.nodeTag(node) == .test_decl) {
        const name, const body = tree.nodeData(node).opt_token_and_node;
        return .{ name.unwrap() orelse tree.nodeMainToken(node), body };
    }
    var buffer: [1]Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, node).?;
    _, const body = tree.nodeData(node).node_and_node;
    return .{ proto.name_token orelse return null, body };
}

/// Scores one `fn_decl` or `test_decl` node without the collector's walk, and sets `too_deep`
/// when the body nests past `max_tree_depth`. Returns null for a function declaration with no
/// name token. `path` is left empty for the caller to fill.
pub fn score_declaration(tree: *const Ast, node: Node.Index, too_deep: *bool) ?FunctionScore {
    const name_token, const body = name_and_body(tree, node) orelse return null;
    const name = tree.tokenSlice(name_token);
    var scorer: Scorer = .{ .tree = tree, .function_name = name };
    scorer.visit(body, 0);
    if (scorer.too_deep) too_deep.* = true;
    const location = tree.tokenLocation(0, name_token);
    return .{
        .path = "",
        .line = location.line + 1,
        .column = location.column + 1,
        .name = name,
        .score = scorer.score,
    };
}

/// Parses `source` and scores every function and test block in it, in source order. `path` and
/// each name are copied into `arena`, so the results outlive `source`.
pub fn score_source(
    arena: Allocator,
    path: []const u8,
    source: [:0]const u8,
) ScoreError![]FunctionScore {
    var tree = try Ast.parse(arena, source, .zig);
    defer tree.deinit(arena);
    if (tree.errors.len != 0) return error.ParseFailed;

    var declarations: std.ArrayList(Node.Index) = .empty;
    defer declarations.deinit(arena);
    try declarations.ensureTotalCapacity(arena, max_functions_per_file);
    var collector: Collector = .{ .tree = &tree, .declarations = &declarations };
    for (tree.rootDecls()) |declaration| collector.child(declaration);
    if (collector.truncated) return error.TooManyFunctions;
    if (collector.too_deep) return error.NestingTooDeep;

    const owned_path = try arena.dupe(u8, path);
    var too_deep = false;
    var results: std.ArrayList(FunctionScore) = .empty;
    try results.ensureTotalCapacity(arena, declarations.items.len);
    for (declarations.items) |declaration| {
        var result = score_declaration(&tree, declaration, &too_deep) orelse continue;
        result.path = owned_path;
        result.name = try arena.dupe(u8, result.name);
        results.appendAssumeCapacity(result);
    }
    // The collector walked every node of every body one or more levels deeper than the scorer
    // counts it, and found none past `max_tree_depth`, so the scorer cannot find one either.
    std.debug.assert(!too_deep);
    return results.items;
}

test {
    _ = @import("complexity_scorer_test.zig");
    _ = @import("complexity_scorer_declaration_test.zig");
}
