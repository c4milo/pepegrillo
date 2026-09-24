//! static-alignment: a container-level `var` states its own alignment.
//!
//! Zig 0.16's x86_64 backend, which builds Debug on x86_64, places a global without the alignment
//! its type gets from an aligned field, unless the variable declares the alignment itself. With
//! `struct { small: u8, memory: [100]u8 align(64) }`, `@alignOf` is 64 and a global of that type
//! can land 48 bytes past a 64-byte boundary. LLVM places it right. A comptime check cannot see
//! this: the type's alignment is correct, and only the address the backend gives the global is
//! wrong. Writing `var holder: Holder align(@alignOf(Holder)) = undefined;` is placed right by
//! every backend, and this rule asks for it.
//!
//! Over every Zig file in `scope`, the rule reads every `var` that is a member of a container: the
//! file's top level, or a `struct`, `union`, `enum` or `opaque`, including one declared inside a
//! function or a `test` block. A function's local variables are not read. It reports a `var` that
//! declares no `align(...)`, with `var <name> declares no alignment: write align(@alignOf(<type>))`,
//! where `<type>` is the declared type under any arrays and optionals, since an array or an optional
//! has its element's alignment. It reports none when:
//!
//! 1. It is `extern`: another object defines it.
//! 2. Its declared type is a primitive (`u8`, `usize`, `bool`, `f64`, `c_int`, ...), a pointer or
//!    a slice, or an array or an optional of one of those.
//!
//! A `var` that declares no type is reported with `var <name> declares no type, so its alignment
//! cannot be stated: declare both`.
//!
//! The rule reads syntax, so it cannot tell a struct from an enum or from an alias of an integer.
//! It reports every named type, and restating a type's alignment is correct for all of them. A
//! `const` is not read: a file's imports and type aliases are all `const`, and the backend was
//! seen misplacing a `var`.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const ast = @import("../ast.zig");
const report = @import("../report.zig");
const Scope = @import("../scope.zig").Scope;

/// The most wrappers, arrays and optionals, the rule looks through to reach a declared type's
/// element. Deeper than any type a person writes; a deeper one is reported as needing alignment.
pub const max_type_depth: u32 = 16;

pub const Config = struct {
    /// The rule name findings are reported under and `--rule` selects.
    name: []const u8 = "static-alignment",
    /// The files the rule reads.
    scope: Scope,
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
                .name = settings.name,
            };
            visitor.check_members(tree.rootDecls());
            for (tree.rootDecls()) |declaration| visitor.child(declaration);
            if (visitor.failure) |failure| return failure;
        }
    };
}

const Visitor = struct {
    tree: *const Ast,
    findings: *report.Findings,
    path: []const u8,
    name: []const u8,
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
            self.check_member(member) catch |failure| {
                self.failure = failure;
            };
        }
    }

    fn check_member(self: *Visitor, member: Node.Index) !void {
        const declaration = self.tree.fullVarDecl(member) orelse return;
        if (self.tree.tokenTag(declaration.ast.mut_token) != .keyword_var) return;
        if (declaration.ast.align_node != .none) return;
        if (is_extern(self.tree, declaration)) return;
        const name_token = declaration.ast.mut_token + 1;
        const variable = self.tree.tokenSlice(name_token);
        const location = ast.token_location(self.tree, name_token);
        const type_node = declaration.ast.type_node.unwrap() orelse {
            return self.findings.add(
                self.name,
                self.path,
                location.line,
                location.column,
                "var {s} declares no type, so its alignment cannot be stated: declare both",
                .{variable},
            );
        };
        const element = element_needing_alignment(self.tree, type_node) orelse return;
        try self.findings.add(
            self.name,
            self.path,
            location.line,
            location.column,
            "var {s} declares no alignment: write align(@alignOf({s}))",
            .{ variable, self.tree.getNodeSource(element) },
        );
    }
};

fn is_extern(tree: *const Ast, declaration: Ast.full.VarDecl) bool {
    const token = declaration.extern_export_token orelse return false;
    return tree.tokenTag(token) == .keyword_extern;
}

/// The part of a declared type whose alignment a global of that type must state: the type under
/// any arrays and optionals. Null when the global is placed right whatever the backend: its type
/// is a primitive, a pointer or a slice, or an array or an optional of one of those.
fn element_needing_alignment(tree: *const Ast, type_node: Node.Index) ?Node.Index {
    var node = type_node;
    var depth: u32 = 0;
    while (depth < max_type_depth) : (depth += 1) {
        switch (tree.nodeTag(node)) {
            .identifier => {
                const type_name = tree.tokenSlice(tree.nodeMainToken(node));
                return if (std.zig.primitives.isPrimitive(type_name)) null else node;
            },
            .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => return null,
            .optional_type => node = tree.nodeData(node).node,
            .array_type, .array_type_sentinel => node = tree.fullArrayType(node).?.ast.elem_type,
            else => return node,
        }
    }
    return node;
}

test {
    _ = @import("static_alignment_test.zig");
}
