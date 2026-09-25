//! global-state: a container-level `var` is `threadlocal`.
//!
//! A program that runs one thread per core, each with its own loop and nothing shared between
//! them, has no state that every thread reads and writes. A `var` at container level is such
//! state: one copy for the whole process, which two threads race on. This rule refuses it, so the
//! state is handed in, or made the thread's own with `threadlocal`.
//!
//! Over every Zig file in `scope`, the rule reads every `var` that is a member of a container: the
//! file's top level, or a `struct`, `union`, `enum` or `opaque`, including one declared inside a
//! function or a `test` block. A function's local variables are not read, and neither is a
//! `const`. It reports a `var` that is not `threadlocal`, with `var <name> is state every thread
//! shares: make it threadlocal, or hand it in`. It reports none for an `extern` one: another object
//! defines it, and that object's threads are its own to answer for.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const ast = @import("../ast.zig");
const report = @import("../report.zig");
const Scope = @import("../scope.zig").Scope;

pub const Config = struct {
    /// The rule name findings are reported under and `--rule` selects.
    name: []const u8 = "global-state",
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
        if (declaration.threadlocal_token != null) return;
        if (is_extern(self.tree, declaration)) return;
        const name_token = declaration.ast.mut_token + 1;
        const location = ast.token_location(self.tree, name_token);
        try self.findings.add(
            self.name,
            self.path,
            location.line,
            location.column,
            "var {s} is state every thread shares: make it threadlocal, or hand it in",
            .{self.tree.tokenSlice(name_token)},
        );
    }
};

fn is_extern(tree: *const Ast, declaration: Ast.full.VarDecl) bool {
    const token = declaration.extern_export_token orelse return false;
    return tree.tokenTag(token) == .keyword_extern;
}

test {
    _ = @import("global_state_test.zig");
}
