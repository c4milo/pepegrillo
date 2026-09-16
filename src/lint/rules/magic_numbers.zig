//! magic-numbers: a limit is named in a constant, never written inline.
//!
//! Over every Zig file in `scope`, the rule reports every integer literal whose value is greater
//! than `largest_allowed_literal`, as written, with `integer literal <literal>`. A literal too
//! large for `u64` is reported too. A float literal is not an integer and is not reported. The
//! literal is reported wherever it appears, an array length `[4]u8`, a shift `1 << 3`, a hex or
//! underscored literal, with three exceptions:
//!
//! 1. The whole value of a `const` declaration or of a container field, alone or negated, names
//!    the number: `const max = 4096;`, an enum member `commit = 3`, a field default
//!    `retries: u8 = 3`. The type of such a declaration is still read. `var n = 4096;` and
//!    `const bit = 1 << 3;` do not name their numbers.
//! 2. A `test` block, when `skip_test_blocks` is set.
//! 3. A `comptime` block, when `skip_comptime_blocks` is set: a layout assert checks a number, it
//!    does not use one as a limit.
//!
//! `parameter_types` chooses which parameter types the walk reads, as in `forbidden_references`.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const ast = @import("../ast.zig");
const report = @import("../report.zig");
const Scope = @import("../scope.zig").Scope;

/// The largest literal a configuration allows when it names none: 0 and 1 are structure, not
/// limits.
pub const default_largest_allowed_literal: u64 = 1;

pub const ParameterTypes = ast.ParameterTypes;

pub const Config = struct {
    /// The rule name findings are reported under and `--rule` selects.
    name: []const u8 = "magic-numbers",
    /// The files the rule reads. A project exempts its constants files here.
    scope: Scope,
    /// The largest integer literal that needs no name.
    largest_allowed_literal: u64 = default_largest_allowed_literal,
    /// Whether the inside of a `test` block is left unread.
    skip_test_blocks: bool = true,
    /// Whether the inside of a `comptime` block is left unread.
    skip_comptime_blocks: bool = true,
    parameter_types: ParameterTypes = .every_prototype,
};

/// The rule for one configuration: a type with the `name` and `check` the driver dispatches to.
pub fn Rule(comptime config: Config) type {
    comptime std.debug.assert(config.name.len != 0);
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
                .config = &settings,
            };
            for (tree.rootDecls()) |declaration| visitor.child(declaration);
            if (visitor.failure) |failure| return failure;
        }
    };
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
        if (self.visit_named_value(node)) return;
        const tag = self.tree.nodeTag(node);
        if (self.is_skipped_block(tag)) return;
        if (tag == .number_literal) return self.check_literal(node);
        ast.for_each_child_reading(self.tree, node, self.config.parameter_types, self);
    }

    /// Reads only the type of a declaration or field whose whole value is one literal, and returns
    /// true; returns false for every other node.
    fn visit_named_value(self: *Visitor, node: Node.Index) bool {
        if (self.tree.fullVarDecl(node)) |declaration| {
            if (is_named_constant(self.tree, declaration)) {
                if (declaration.ast.type_node.unwrap()) |type_node| self.child(type_node);
                return true;
            }
        }
        if (self.tree.fullContainerField(node)) |field| {
            if (is_whole_literal(self.tree, field.ast.value_expr)) {
                if (field.ast.type_expr.unwrap()) |type_expr| self.child(type_expr);
                return true;
            }
        }
        return false;
    }

    fn is_skipped_block(self: *const Visitor, tag: Node.Tag) bool {
        return switch (tag) {
            .test_decl => self.config.skip_test_blocks,
            .@"comptime" => self.config.skip_comptime_blocks,
            else => false,
        };
    }

    fn check_literal(self: *Visitor, node: Node.Index) !void {
        const literal = self.tree.tokenSlice(self.tree.nodeMainToken(node));
        if (!is_magic(literal, self.config.largest_allowed_literal)) return;
        const location = ast.node_location(self.tree, node);
        try self.findings.add(
            self.config.name,
            self.path,
            location.line,
            location.column,
            "integer literal {s}",
            .{literal},
        );
    }
};

/// True for `const NAME = literal;` or `const NAME = -literal;`: the whole initializer is one
/// literal, so the declaration names it.
fn is_named_constant(tree: *const Ast, declaration: Ast.full.VarDecl) bool {
    if (tree.tokenTag(declaration.ast.mut_token) != .keyword_const) return false;
    return is_whole_literal(tree, declaration.ast.init_node);
}

/// True when `value` is present and is one number literal, alone or negated.
fn is_whole_literal(tree: *const Ast, value: Node.OptionalIndex) bool {
    const node = value.unwrap() orelse return false;
    return switch (tree.nodeTag(node)) {
        .number_literal => true,
        .negation => tree.nodeTag(tree.nodeData(node).node) == .number_literal,
        else => false,
    };
}

/// True for an integer literal over `largest_allowed_literal`, including one too large for u64.
fn is_magic(literal: []const u8, largest_allowed_literal: u64) bool {
    return switch (std.zig.number_literal.parseNumberLiteral(literal)) {
        .int => |value| value > largest_allowed_literal,
        .big_int => true,
        .float, .failure => false,
    };
}

test {
    _ = @import("magic_numbers_test.zig");
}
