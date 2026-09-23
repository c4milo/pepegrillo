//! The walk of the forbidden-references rule: one pass over a parsed file that applies the four
//! checks `forbidden_references.zig` states, in the order the rule's header gives them. Under
//! `resolve_file_aliases`, a first pass over the top-level declarations collects the file's
//! aliases.

const std = @import("std");
const Allocator = std.mem.Allocator;
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
    const aliases: Aliases = if (config.resolve_file_aliases)
        try collect_aliases(context.arena, tree)
    else
        .empty;
    var visitor: Visitor = .{
        .tree = tree,
        .arena = context.arena,
        .findings = &context.findings,
        .path = path,
        .config = config,
        .aliases = &aliases,
    };
    for (tree.rootDecls()) |declaration| visitor.child(declaration);
    if (visitor.failure) |failure| return failure;
}

const Visitor = struct {
    tree: *const Ast,
    arena: Allocator,
    findings: *report.Findings,
    path: []const u8,
    config: *const Config,
    aliases: *const Aliases,
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
            return self.visit_chain(node, chain);
        }
        const tag = self.tree.nodeTag(node);
        if (ast.is_call(tag)) try self.visit_call(node);
        ast.for_each_child_reading(self.tree, node, self.config.parameter_types, self);
        // A `fn_decl` holds its prototype as a child, which the walk has just read. The check runs
        // after the children, so a forbidden chain that starts a parameter's type is recorded
        // before the parameter finding at the same token.
        if (tag != .fn_decl) try self.visit_prototype(node);
    }

    /// Check 1: the chain as written, then the chain its alias stands for.
    fn visit_chain(self: *Visitor, node: Node.Index, chain: []const u8) !void {
        const location = ast.node_start_location(self.tree, node);
        if (rule.is_forbidden_chain(self.config, chain)) return self.add_reference(location, chain);
        const resolved = try self.forbidden_through_alias(chain) orelse return;
        try self.add_aliased_reference(location, resolved, ast.first_segment(chain));
    }

    /// The chain `chain` stands for, when its first segment names a file-level alias and check 1
    /// forbids the chain it stands for. Null otherwise.
    fn forbidden_through_alias(self: *Visitor, chain: []const u8) !?[]const u8 {
        const root = ast.first_segment(chain);
        const value = self.aliases.get(root) orelse return null;
        const resolved = try std.mem.concat(self.arena, u8, &.{ value, chain[root.len..] });
        if (!rule.is_forbidden_chain(self.config, resolved)) return null;
        return resolved;
    }

    fn visit_call(self: *Visitor, node: Node.Index) !void {
        const callee = ast.callee(self.tree, node);
        var buffer: [ast.max_chain_bytes]u8 = undefined;
        const chain = ast.chain_text(self.tree, callee, &buffer) orelse return;
        try self.visit_method_call(callee, chain);
        // A chain check 1 forbids, as written or through an alias, is reported when the callee is
        // visited as a child.
        if (!rule.is_forbidden_callee(self.config, chain)) return;
        if (try self.forbidden_through_alias(chain) != null) return;
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

    fn add_aliased_reference(
        self: *Visitor,
        location: ast.Location,
        resolved: []const u8,
        alias: []const u8,
    ) !void {
        const line = location.line;
        const column = location.column;
        const name = self.config.name;
        const format = "reference to {s} through {s}";
        const reason = self.config.reason orelse {
            return self.findings.add(name, self.path, line, column, format, .{ resolved, alias });
        };
        try self.findings.add(name, self.path, line, column, format ++ ": {s}", .{
            resolved, alias, reason,
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

/// A file's top-level aliases: each alias's name, and the chain it stands for with every alias in
/// that chain already resolved, so one lookup resolves a chain.
const Aliases = std.StringHashMapUnmanaged([]const u8);

/// Reads the aliases the rule's header defines from the top-level declarations of `tree`. An alias
/// whose value leads back to itself is left out: the compiler refuses such a file.
fn collect_aliases(arena: Allocator, tree: *const Ast) !Aliases {
    var written: Aliases = .empty;
    for (tree.rootDecls()) |declaration| {
        var buffer: [ast.max_chain_bytes]u8 = undefined;
        const alias = alias_declaration(tree, declaration, &buffer) orelse continue;
        try written.put(arena, alias.name, try arena.dupe(u8, alias.value));
    }
    var resolved: Aliases = .empty;
    var iterator = written.iterator();
    while (iterator.next()) |entry| {
        const chain = try resolve_value(arena, &written, entry.value_ptr.*) orelse continue;
        try resolved.put(arena, entry.key_ptr.*, chain);
    }
    return resolved;
}

const Alias = struct {
    name: []const u8,
    value: []const u8,
};

/// The alias `declaration` makes, when it is a `const` whose value is a chain or `@import("std")`
/// and names something other than itself. `const std = @import("std");` makes none.
fn alias_declaration(
    tree: *const Ast,
    declaration: Node.Index,
    buffer: *[ast.max_chain_bytes]u8,
) ?Alias {
    const variable = tree.fullVarDecl(declaration) orelse return null;
    if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
    const value_node = variable.ast.init_node.unwrap() orelse return null;
    const name = tree.tokenSlice(variable.ast.mut_token + 1);
    const chain = ast.chain_text(tree, value_node, buffer) orelse
        standard_library(tree, value_node) orelse return null;
    if (std.mem.eql(u8, chain, name)) return null;
    return .{ .name = name, .value = chain };
}

/// `std` when `node` is `@import("std")`. Null otherwise.
fn standard_library(tree: *const Ast, node: Node.Index) ?[]const u8 {
    const path = ast.imported_path(tree, node) orelse return null;
    if (!std.mem.eql(u8, path, "std")) return null;
    return "std";
}

/// `value` with every alias at its start replaced by that alias's value, or null when the aliases
/// form a cycle. Without a cycle, a value passes through each other alias at most once, so the
/// loop needs one step for each other alias and one more that finds no alias: one step per alias.
/// A value still starting with an alias after that has met a cycle.
fn resolve_value(arena: Allocator, written: *const Aliases, value: []const u8) !?[]const u8 {
    var chain = value;
    for (0..written.count()) |_| {
        const root = ast.first_segment(chain);
        const replacement = written.get(root) orelse return chain;
        chain = try std.mem.concat(arena, u8, &.{ replacement, chain[root.len..] });
    }
    return null;
}

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

const clock_reason = "reads a clock";
const fixture_path = "src/store/page.zig";

/// The clocks forbidden by prefix, with `resolve_file_aliases` left at its default.
const clock_as_written: Config = .{
    .name = "clock",
    .scope = .{ .extensions = &.{".zig"} },
    .prefixes = &.{ "std.time", "std.os.linux.clock_gettime", "std.Io.Clock" },
    .raw_prefixes = &.{"std.posix.clock_"},
    .reason = clock_reason,
};

const clock_through_aliases: Config = through: {
    var config = clock_as_written;
    config.resolve_file_aliases = true;
    break :through config;
};

/// Aliases of the namespaces above each clock, one of them an alias of an alias declared before
/// the alias it names, and one clock written in full.
const aliased_clocks: [:0]const u8 =
    \\const std = @import("std");
    \\const zig_std = @import("std");
    \\const linux = os.linux;
    \\const os = std.os;
    \\const posix = std.posix;
    \\const Io = std.Io;
    \\pub fn read(io: Io, now: *linux.timespec) void {
    \\    _ = linux.clock_gettime(.MONOTONIC, now);
    \\    _ = posix.clock_gettime(.MONOTONIC);
    \\    _ = Io.Clock.Timestamp.fromNow(io, .{});
    \\    _ = zig_std.time.nanoTimestamp();
    \\    _ = std.time.nanoTimestamp();
    \\}
;

test "resolve_file_aliases reads a chain through every top-level alias to its clock" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const Clock = rule.Rule(clock_through_aliases);
    const findings = try harness.run(arena_state.allocator(), Clock, fixture_path, aliased_clocks);
    try harness.expect_messages(findings, &.{
        "reference to std.os.linux.clock_gettime through linux: " ++ clock_reason,
        "reference to std.posix.clock_gettime through posix: " ++ clock_reason,
        "reference to std.Io.Clock.Timestamp.fromNow through Io: " ++ clock_reason,
        "reference to std.time.nanoTimestamp through zig_std: " ++ clock_reason,
        "reference to std.time.nanoTimestamp: " ++ clock_reason,
    });
    try testing.expectEqual(8, findings[0].line);
    try testing.expectEqual(9, findings[0].column);
}

test "by default only the clock written in full is reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const Clock = rule.Rule(clock_as_written);
    const findings = try harness.run(arena_state.allocator(), Clock, fixture_path, aliased_clocks);
    const written = "reference to std.time.nanoTimestamp: " ++ clock_reason;
    try harness.expect_messages(findings, &.{written});
}

test "check 2 reports a call once when check 1 forbids its callee through an alias" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const by_callee = comptime callee: {
        var config = clock_through_aliases;
        config.callee_names = &.{"clock_gettime"};
        break :callee config;
    };
    const Clock = rule.Rule(by_callee);
    const findings = try harness.run(arena_state.allocator(), Clock, fixture_path,
        \\const linux = std.os.linux;
        \\fn read(now: *Timespec) void {
        \\    _ = linux.clock_gettime(.MONOTONIC, now);
        \\    _ = vdso.clock_gettime(.MONOTONIC, now);
        \\}
    );
    try harness.expect_messages(findings, &.{
        "reference to std.os.linux.clock_gettime through linux: " ++ clock_reason,
        "reference to vdso.clock_gettime: " ++ clock_reason,
    });
}

test "an alias in a function, a variable, and aliases that form a cycle resolve nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const Clock = rule.Rule(clock_through_aliases);
    const findings = try harness.run(arena_state.allocator(), Clock, fixture_path,
        \\const first = second.linux;
        \\const second = first.os;
        \\var host = std.os;
        \\fn read(now: *Timespec) void {
        \\    const linux = std.os.linux;
        \\    _ = linux.clock_gettime(.MONOTONIC, now);
        \\    _ = host.linux.clock_gettime(.MONOTONIC, now);
        \\    _ = first.clock_gettime(.MONOTONIC, now);
        \\}
    );
    try harness.expect_messages(findings, &.{});
}

test "resolve_value resolves an alias of an alias and gives up on a cycle" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var written: Aliases = .empty;
    try written.put(arena, "linux", "os.linux");
    try written.put(arena, "os", "std.os");
    const resolved = try resolve_value(arena, &written, "os.linux");
    try testing.expectEqualStrings("std.os.linux", resolved.?);
    var cycle: Aliases = .empty;
    try cycle.put(arena, "first", "second.linux");
    try cycle.put(arena, "second", "first.os");
    try testing.expectEqual(null, try resolve_value(arena, &cycle, "second.linux"));
}
