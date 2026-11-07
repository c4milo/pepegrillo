//! type-function-suffix: a public type function is named for the thing it returns.
//!
//! The Zig standard library names a function that returns a type for the thing that type is:
//! `std.ArrayList(T)`, `std.HashMap(K, V, ...)` and `std.StaticBitSet(size)`, never
//! `ArrayListOf(T)`. A name with a suffix such as `Of` makes a dependent learn a second
//! convention for one idea. docs/api.md gives the rule and its reason.
//!
//! Over every Zig file in `scope`, the rule reads each function declared as a member of a
//! container: the file's top level, or a `struct`, `union`, `enum` or `opaque`, including one
//! declared inside a function. It reports a function that is `pub`, whose return type is the
//! identifier `type`, in parentheses or not, and whose name ends with one of `suffixes` and is
//! longer than it. The message is `pub fn <name> returns a type: name it <stem>, for the thing it returns, as std
//! names ArrayList and StaticBitSet`, where `<stem>` is the name without the suffix.
//!
//! The rule reads syntax. It does not see a return type written as an alias of `type`, nor a type
//! function a file exports under another name with `pub const`.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const ast = @import("../ast.zig");
const report = @import("../report.zig");
const Scope = @import("../scope.zig").Scope;

pub const Config = struct {
    /// The rule name findings are reported under and `--rule` selects.
    name: []const u8 = "type-function-suffix",
    /// The files the rule reads.
    scope: Scope,
    /// The name endings the rule refuses on a public type function.
    suffixes: []const []const u8 = &.{"Of"},
};

/// The rule for one configuration: a type with the `name` and `check` the driver dispatches to.
pub fn Rule(comptime config: Config) type {
    comptime std.debug.assert(config.name.len != 0);
    comptime for (config.suffixes) |suffix| std.debug.assert(suffix.len != 0);
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
                .suffixes = settings.suffixes,
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
    suffixes: []const []const u8,
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
        const name_token = public_type_function(self.tree, member) orelse return;
        const function_name = self.tree.tokenSlice(name_token);
        const suffix = matching_suffix(function_name, self.suffixes) orelse return;
        const stem = function_name[0 .. function_name.len - suffix.len];
        const location = ast.token_location(self.tree, name_token);
        try self.findings.add(
            self.name,
            self.path,
            location.line,
            location.column,
            "pub fn {s} returns a type: name it {s}, for the thing it returns," ++
                " as std names ArrayList and StaticBitSet",
            .{ function_name, stem },
        );
    }
};

/// The name token of `member` when it is a `pub` function, with or without a body, whose return
/// type is the identifier `type`.
fn public_type_function(tree: *const Ast, member: Node.Index) ?Ast.TokenIndex {
    var buffer: [1]Node.Index = undefined;
    const prototype = tree.fullFnProto(&buffer, member) orelse return null;
    // Zig has one visibility keyword, `pub`.
    _ = prototype.visib_token orelse return null;
    var return_type = prototype.ast.return_type.unwrap() orelse return null;
    // A return type in parentheses, `(type)`, is the same type.
    var removed: usize = 0;
    while (tree.nodeTag(return_type) == .grouped_expression) : (removed += 1) {
        std.debug.assert(removed < ast.max_tree_depth);
        return_type = tree.nodeData(return_type).node_and_token[0];
    }
    if (tree.nodeTag(return_type) != .identifier) return null;
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(return_type)), "type")) return null;
    return prototype.name_token;
}

/// The first of `suffixes` that `function_name` ends with and is longer than, or null.
fn matching_suffix(function_name: []const u8, suffixes: []const []const u8) ?[]const u8 {
    for (suffixes) |suffix| {
        if (function_name.len <= suffix.len) continue;
        if (std.mem.endsWith(u8, function_name, suffix)) return suffix;
    }
    return null;
}

test {
    _ = @import("type_function_suffix_test.zig");
}
