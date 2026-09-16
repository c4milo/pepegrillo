//! relative-import: a Zig file reaches another module by the name the build gives it, never by a
//! path. A module can `@import` only what the build hands it, so the build enforces the direction
//! of every dependency, and an `@import` that climbs out of its module by path goes around that.
//!
//! Over every Zig file `scope` selects, the rule reads every `@import` of a string literal, and
//! `mode` decides which paths are findings:
//!
//! - `.parent_or_absolute`: a path that holds `../` anywhere, or starts with `/`. A file reaching
//!   a sibling or a subdirectory, `@import("page_header.zig")` or `@import("journal/slots.zig")`,
//!   is untouched.
//! - `.leaves_subsystem`: a path that, resolved against the directory of the importing file,
//!   names a file outside the importing file's subsystem, and every absolute path. A file in
//!   `src/store/journal/` may reach `../constants.zig`, which is `src/store/constants.zig`, and
//!   may not reach `../../core/core.zig`. `relative_import_path.zig` defines the subsystem.
//!
//! Under both modes a module name, such as `@import("std")`, is never a finding. An absolute path
//! names one machine rather than the tree, so it is always a finding.
//!
//! The rule reads the literal string only. `@import(module_name)` with a computed name is invisible
//! to it, and so is `@embedFile`, on purpose: a data file lives beside the code that reads it and
//! is not a module edge.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const ast = @import("../ast.zig");
const report = @import("../report.zig");
const Scope = @import("../scope.zig").Scope;
const import_path = @import("relative_import_path.zig");

pub const max_resolved_segments = import_path.max_resolved_segments;

/// Which import paths are findings.
pub const Mode = enum {
    /// A path that holds `../` or starts with `/`.
    parent_or_absolute,
    /// A path that resolves outside the importing file's subsystem, or starts with `/`.
    leaves_subsystem,
};

pub const Config = struct {
    /// The name `--rule` selects and the report prints.
    name: []const u8 = "relative-import",
    /// The files the rule reads. A file that does not parse is skipped.
    scope: Scope,
    mode: Mode,
    /// Under `.leaves_subsystem`, the directory whose children are each a subsystem. Unread under
    /// `.parent_or_absolute`.
    source_root: []const u8 = "src",
    /// The finding text, a `std.fmt` format string. `path`: the imported path without its quotes.
    message: []const u8 = "@import(\"{[path]s}\") leaves the module; import the module by name",
    /// Which function parameter types the walk reads. `.simple_prototypes_only` reproduces a
    /// walker that read the parameter types of one-parameter prototypes alone.
    parameter_types: ast.ParameterTypes = .every_prototype,
};

pub fn Rule(comptime config: Config) type {
    return struct {
        pub const name = config.name;

        pub fn check(context: *report.Context, file: report.File) !void {
            return check_file(config, context, file);
        }
    };
}

fn check_file(comptime config: Config, context: *report.Context, file: report.File) !void {
    if (!config.scope.applies(file.path)) return;
    const tree = file.tree orelse return;
    var walker: Walker(config) = .{
        .tree = tree,
        .findings = &context.findings,
        .path = file.path,
    };
    for (tree.rootDecls()) |declaration| walker.child(declaration);
    if (walker.failure) |failure| return failure;
}

/// The walk over every node of one file. `child` is what `ast.for_each_child_reading` calls.
fn Walker(comptime config: Config) type {
    return struct {
        tree: *const Ast,
        findings: *report.Findings,
        path: []const u8,
        depth: u32 = 0,
        /// The first error `visit` returned. `child` returns nothing, so the walk keeps it here
        /// and `check_file` returns it.
        failure: ?anyerror = null,

        pub fn child(self: *@This(), node: Node.Index) void {
            self.depth += 1;
            defer self.depth -= 1;
            std.debug.assert(self.depth <= ast.max_tree_depth);
            visit(config, self, node) catch |failure| {
                self.failure = failure;
            };
        }
    };
}

fn visit(comptime config: Config, walker: *Walker(config), node: Node.Index) !void {
    if (ast.imported_path(walker.tree, node)) |imported| {
        if (is_finding(config, walker.path, imported)) {
            const location = ast.node_location(walker.tree, node);
            try walker.findings.add(
                config.name,
                walker.path,
                location.line,
                location.column,
                config.message,
                .{ .path = imported },
            );
        }
    }
    ast.for_each_child_reading(walker.tree, node, config.parameter_types, walker);
}

fn is_finding(comptime config: Config, path: []const u8, imported: []const u8) bool {
    return switch (config.mode) {
        .parent_or_absolute => import_path.holds_parent_or_absolute(imported),
        .leaves_subsystem => import_path.leaves_subsystem(config.source_root, path, imported),
    };
}

test {
    _ = import_path;
    _ = @import("relative_import_test.zig");
}
