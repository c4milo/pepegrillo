//! undefined-fill: a function's local array is not set to `undefined`.
//!
//! In Debug and ReleaseSafe, Zig writes 0xAA over every value set to `undefined`, so
//! `var messages: [32]Message = undefined;` stores the whole array each time the function runs,
//! whether it uses one element or none. A large array is filled by a call to `memset`, which on
//! Linux is compiler_rt's loop of one byte at a time.
//!
//! Over every Zig file in `scope`, the rule reads each `var` declared inside a function body: not
//! one inside a `test` block, not one that is a member of a container, and, when
//! `stop_at_testing_import` is set, not one after the file's `const testing = std.testing;`, where a
//! project that puts its tests last begins them. It reports a `var` whose declared type is an array
//! and whose value is `undefined`, with `var <name> is an array set to undefined, which Debug and
//! ReleaseSafe fill on every call: write into the caller's memory, or declare it only where it is
//! used`. It reports none when:
//!
//! 1. The array's length is a number, not a name, of at most `literal_elements_max`: a few stores.
//! 2. The declaration shows the array's size, and it is under `bytes_min`: a length written as a
//!    number, or as a name the file sets to one number, times an element of a primitive type such
//!    as `u8`, `u32` or `f64`.
//! 3. `allowed` names the file and the variable: a path that runs once or rarely, which the project
//!    names.
//!
//! The rule reads syntax, so it cannot tell how large a named element type is, nor what a length
//! named in another file holds, and it reports those arrays.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const ast = @import("../ast.zig");
const report = @import("../report.zig");
const Scope = @import("../scope.zig").Scope;

/// The most elements an array whose length is a number may have and not be reported, unless the
/// project says otherwise: eight stores or so.
pub const literal_elements_default: u64 = 8;

/// The size under which an array whose size its declaration shows is not reported, unless the
/// project says otherwise: a cache line, which a few stores fill.
pub const bytes_min_default: u64 = 64;

/// The bytes the rule takes a `usize` or an `isize` to hold: a 64-bit target's, the larger, so a
/// 32-bit build never passes an array a 64-bit build would report.
const pointer_bytes: u64 = 8;

/// A variable the rule does not report: the file it is in and its name.
pub const Allowed = struct {
    path: []const u8,
    variable: []const u8,
};

pub const Config = struct {
    /// The rule name findings are reported under and `--rule` selects.
    name: []const u8 = "undefined-fill",
    /// The files the rule reads.
    scope: Scope,
    /// The most elements an array whose length is a number may have and not be reported.
    literal_elements_max: u64 = literal_elements_default,
    /// The size an array whose size its declaration shows must reach to be reported. 0 turns the
    /// exemption off.
    bytes_min: u64 = bytes_min_default,
    /// The variables on a path that runs once or rarely, which the rule does not report.
    allowed: []const Allowed = &.{},
    /// Stop reading a file at its `const testing = std.testing;`, for a project whose files put
    /// their tests, and the helpers only tests call, after that line.
    stop_at_testing_import: bool = false,
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
                .settings = &settings,
            };
            for (tree.rootDecls()) |declaration| {
                if (settings.stop_at_testing_import and is_testing_import(tree, declaration)) break;
                visitor.child(declaration);
            }
            if (visitor.failure) |failure| return failure;
        }
    };
}

const Visitor = struct {
    tree: *const Ast,
    findings: *report.Findings,
    path: []const u8,
    settings: *const Config,
    /// True while the walk is inside a function body and outside any container declared there, so
    /// a `var` met now is one of the function's locals.
    in_function: bool = false,
    depth: u32 = 0,
    failure: ?anyerror = null,

    pub fn child(self: *Visitor, node: Node.Index) void {
        self.depth += 1;
        defer self.depth -= 1;
        std.debug.assert(self.depth <= ast.max_tree_depth);
        switch (self.tree.nodeTag(node)) {
            // A test's locals run in tests alone.
            .test_decl => return,
            .fn_decl => return self.walk(node, true),
            else => {},
        }
        var buffer: [2]Node.Index = undefined;
        if (self.tree.fullContainerDecl(&buffer, node) != null) return self.walk(node, false);
        if (self.in_function) {
            self.check_local(node) catch |failure| {
                self.failure = failure;
            };
        }
        ast.for_each_child(self.tree, node, self);
    }

    /// Walks the children of `node` with `in_function` set as given, and restores it after.
    fn walk(self: *Visitor, node: Node.Index, in_function: bool) void {
        const outer = self.in_function;
        self.in_function = in_function;
        defer self.in_function = outer;
        ast.for_each_child(self.tree, node, self);
    }

    fn check_local(self: *Visitor, node: Node.Index) !void {
        const declaration = self.tree.fullVarDecl(node) orelse return;
        if (self.tree.tokenTag(declaration.ast.mut_token) != .keyword_var) return;
        const type_node = declaration.ast.type_node.unwrap() orelse return;
        const init_node = declaration.ast.init_node.unwrap() orelse return;
        if (!is_undefined(self.tree, init_node)) return;
        const array = self.tree.fullArrayType(type_node) orelse return;
        if (self.small_literal(array.ast.elem_count)) return;
        if (self.small_bytes(array)) return;
        const name_token = declaration.ast.mut_token + 1;
        const variable = self.tree.tokenSlice(name_token);
        if (self.is_allowed(variable)) return;
        const location = ast.token_location(self.tree, name_token);
        try self.findings.add(
            self.settings.name,
            self.path,
            location.line,
            location.column,
            "var {s} is an array set to undefined, which Debug and ReleaseSafe fill on every call: " ++
                "write into the caller's memory, or declare it only where it is used",
            .{variable},
        );
    }

    /// True when the array's length is a number no larger than `literal_elements_max`. Only a
    /// number's main token parses as one: a name, an expression or a call does not.
    fn small_literal(self: *const Visitor, count: Node.Index) bool {
        const text = self.tree.tokenSlice(self.tree.nodeMainToken(count));
        const elements = std.fmt.parseInt(u64, text, 0) catch return false;
        return elements <= self.settings.literal_elements_max;
    }

    /// True when the declaration shows the array's size and it is under `bytes_min`.
    fn small_bytes(self: *const Visitor, array: Ast.full.ArrayType) bool {
        const elements = self.shown_length(array.ast.elem_count) orelse return false;
        const element_bytes = primitive_bytes(self.tree.getNodeSource(array.ast.elem_type)) orelse return false;
        const sentinel: u64 = @intFromBool(array.ast.sentinel.unwrap() != null);
        const count = std.math.add(u64, elements, sentinel) catch return false;
        const bytes = std.math.mul(u64, count, element_bytes) catch return false;
        return bytes < self.settings.bytes_min;
    }

    /// The array's length when it is a number, or a name the file sets to exactly one number.
    fn shown_length(self: *const Visitor, count: Node.Index) ?u64 {
        if (number_of(self.tree, count)) |elements| return elements;
        if (self.tree.nodeTag(count) != .identifier) return null;
        return named_number(self.tree, self.tree.tokenSlice(self.tree.nodeMainToken(count)));
    }

    fn is_allowed(self: *const Visitor, variable: []const u8) bool {
        for (self.settings.allowed) |allowed| {
            if (std.mem.eql(u8, allowed.path, self.path) and std.mem.eql(u8, allowed.variable, variable)) {
                return true;
            }
        }
        return false;
    }
};

/// The value of a number literal, or null for any other node.
fn number_of(tree: *const Ast, node: Node.Index) ?u64 {
    if (tree.nodeTag(node) != .number_literal) return null;
    return std.fmt.parseInt(u64, tree.tokenSlice(tree.nodeMainToken(node)), 0) catch null;
}

/// The number every `const` named `name` in the file is set to. Null when none is, when one is set
/// to anything else, or when two are set to different numbers.
fn named_number(tree: *const Ast, name: []const u8) ?u64 {
    var found: ?u64 = null;
    for (0..tree.nodes.len) |index| {
        const declaration = tree.fullVarDecl(@enumFromInt(@as(u32, @intCast(index)))) orelse continue;
        if (tree.tokenTag(declaration.ast.mut_token) != .keyword_const) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(declaration.ast.mut_token + 1), name)) continue;
        const init_node = declaration.ast.init_node.unwrap() orelse return null;
        const value = number_of(tree, init_node) orelse return null;
        if (found != null and found.? != value) return null;
        found = value;
    }
    return found;
}

/// The bytes one element of a primitive type takes: `bool`, `u<bits>` and `i<bits>` in whole
/// bytes rounded up to a power of two, `f16` to `f128`, and `usize` and `isize` as
/// `pointer_bytes`. Null for any other type.
fn primitive_bytes(name: []const u8) ?u64 {
    if (std.mem.eql(u8, name, "bool")) return 1;
    if (std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize")) return pointer_bytes;
    if (name.len < 2) return null;
    const bits = std.fmt.parseInt(u16, name[1..], 10) catch return null;
    return switch (name[0]) {
        'u', 'i' => if (bits == 0) null else std.math.ceilPowerOfTwoAssert(u64, (@as(u64, bits) + 7) / 8),
        'f' => switch (bits) {
            16 => 2,
            32 => 4,
            64 => 8,
            80, 128 => 16,
            else => null,
        },
        else => null,
    };
}

/// True for `const testing = std.testing;`.
fn is_testing_import(tree: *const Ast, node: Node.Index) bool {
    const declaration = tree.fullVarDecl(node) orelse return false;
    if (tree.tokenTag(declaration.ast.mut_token) != .keyword_const) return false;
    if (!std.mem.eql(u8, tree.tokenSlice(declaration.ast.mut_token + 1), "testing")) return false;
    const init_node = declaration.ast.init_node.unwrap() orelse return false;
    return std.mem.eql(u8, tree.getNodeSource(init_node), "std.testing");
}

fn is_undefined(tree: *const Ast, node: Node.Index) bool {
    if (tree.nodeTag(node) != .identifier) return false;
    return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "undefined");
}

test {
    _ = @import("undefined_fill_test.zig");
}
