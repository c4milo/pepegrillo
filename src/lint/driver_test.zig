//! Tests for `driver.zig`: the walk, the arguments, the parse pseudo-rule and the exit status,
//! driven through two probe rules so no generic rule's verdicts are pinned here.

const std = @import("std");
const Ast = std.zig.Ast;
const Io = std.Io;
const testing = std.testing;
const driver = @import("driver.zig");
const paths = @import("paths.zig");
const report = @import("report.zig");

/// Reports every parsed `.zig` file once, at its first line.
const ZigProbe = struct {
    pub const name = "zig-probe";
    pub fn check(context: *report.Context, file: report.File) !void {
        if (file.tree == null) return;
        try context.findings.add(name, file.path, 1, 1, "parsed", .{});
    }
};

/// Reports every `.md` file once, at its first line.
const MarkdownProbe = struct {
    pub const name = "markdown-probe";
    pub fn check(context: *report.Context, file: report.File) !void {
        if (!paths.has_extension(file.path, ".md")) return;
        try context.findings.add(name, file.path, 1, 1, "read", .{});
    }
};

const Linter = driver.Linter(.{ ZigProbe, MarkdownProbe });

fn new_run(arena: std.mem.Allocator) driver.Run {
    return .{ .context = .{ .arena = arena, .io = testing.io, .findings = .{ .arena = arena } } };
}

fn exit_status_of(run: *const driver.Run) u8 {
    return driver.exit_status(run.context.findings.count(), run.file_errors);
}

test "parse_arguments reads --rule and paths, and defaults to every rule" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const arguments = [_][]const u8{ "--rule", "markdown-probe", "src", "docs" };
    const options = try Linter.parse_arguments(arena, &arguments);
    try testing.expect(options.enabled[Linter.rule_index_of("markdown-probe").?]);
    try testing.expect(!options.enabled[Linter.rule_index_of("zig-probe").?]);
    try testing.expectEqual(2, options.paths.len);
    try testing.expectEqualStrings("docs", options.paths[1]);

    const defaults = try Linter.parse_arguments(arena, &.{"src"});
    for (defaults.enabled) |enabled| try testing.expect(enabled);
}

test "parse_arguments reports usage errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parse = Linter.parse_arguments;
    try testing.expectError(error.NoPaths, parse(arena, &.{ "--rule", "zig-probe" }));
    try testing.expectError(error.MissingValue, parse(arena, &.{ "src", "--rule" }));
    try testing.expectError(error.UnknownRule, parse(arena, &.{ "--rule", "tabs", "src" }));
    try testing.expectError(error.UnknownFlag, parse(arena, &.{ "--max", "src" }));
}

test "rules are looked up by name in the order they were given" {
    try testing.expectEqual(2, Linter.count);
    try testing.expectEqual(0, Linter.rule_index_of("zig-probe").?);
    try testing.expectEqual(1, Linter.rule_index_of("markdown-probe").?);
    try testing.expectEqual(null, Linter.rule_index_of("zig"));
}

test "the exit status is 1 on a finding or a file error and 0 otherwise" {
    try testing.expectEqual(driver.exit_clean, driver.exit_status(0, 0));
    try testing.expectEqual(driver.exit_findings, driver.exit_status(1, 0));
    try testing.expectEqual(driver.exit_findings, driver.exit_status(0, 1));
    try testing.expectEqual(driver.exit_findings, driver.exit_status(3, 2));
}

/// Writes the fixture tree the walk test reads: two files to lint, one under a subdirectory, and
/// one under each skipped directory.
fn write_walk_fixture(dir: Io.Dir) !void {
    const io = testing.io;
    const source = "pub fn spin() void {}\n";
    try dir.createDirPath(io, "src/store");
    try dir.writeFile(io, .{ .sub_path = "src/store/store.zig", .data = source });
    try dir.createDirPath(io, "docs");
    try dir.writeFile(io, .{ .sub_path = "docs/design.md", .data = "# Design\n" });
    try dir.createDirPath(io, ".zig-cache/deep");
    try dir.writeFile(io, .{ .sub_path = ".zig-cache/deep/cached.zig", .data = source });
    try dir.createDirPath(io, "zig-out");
    try dir.writeFile(io, .{ .sub_path = "zig-out/built.zig", .data = source });
    try dir.createDirPath(io, ".git/hooks");
    try dir.writeFile(io, .{ .sub_path = ".git/hooks/hook.md", .data = "# Hook\n" });
}

test "the walk visits every regular file, skips build output and .git, and joins the root" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try write_walk_fixture(tmp.dir);

    var run = new_run(arena_state.allocator());
    // The reported path is the root label joined with the entry's path; the files are read
    // through `tmp.dir`, so the label need not exist.
    var root_buffer: [driver.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try Linter.walk_directory(&run, tmp.dir, root);
    run.context.findings.sort();

    try testing.expectEqual(2, run.files_seen);
    try testing.expectEqual(0, run.file_errors);
    const findings = run.context.findings.items.items;
    try testing.expectEqual(2, findings.len);
    try testing.expectEqualStrings("markdown-probe", findings[0].rule);
    try testing.expect(std.mem.endsWith(u8, findings[0].path, "/docs/design.md"));
    try testing.expectEqualStrings("zig-probe", findings[1].rule);
    try testing.expect(std.mem.startsWith(u8, findings[1].path, root));
}

test "lint_path on a single file runs the rules, and a missing path is a file error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "clean.zig", .data = "const one = 1;\n" });
    var path_buffer: [driver.max_path_bytes]u8 = undefined;
    const path_format = ".zig-cache/tmp/{s}/clean.zig";
    const path = try std.fmt.bufPrint(&path_buffer, path_format, .{tmp.sub_path});

    const arena = arena_state.allocator();
    var run = new_run(arena);
    run.quiet = true;
    const markdown_only = [_][]const u8{ "--rule", "markdown-probe", "x" };
    run.enabled = (try Linter.parse_arguments(arena, &markdown_only)).enabled;
    try Linter.lint_path(&run, path);
    try testing.expectEqual(1, run.files_seen);
    try testing.expectEqual(driver.exit_clean, exit_status_of(&run));
    try Linter.lint_path(&run, ".zig-cache/tmp/no-such-directory/missing.zig");
    try testing.expectEqual(1, run.file_errors);
    try testing.expectEqual(driver.exit_findings, exit_status_of(&run));
}

test "a .zig file that does not parse is reported under the parse pseudo-rule" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "broken.zig", .data = "fn broken( {\n" });
    var path_buffer: [driver.max_path_bytes]u8 = undefined;
    const path_format = ".zig-cache/tmp/{s}/broken.zig";
    const path = try std.fmt.bufPrint(&path_buffer, path_format, .{tmp.sub_path});

    var run = new_run(arena_state.allocator());
    try Linter.lint_path(&run, path);
    const findings = run.context.findings.items.items;
    try testing.expectEqual(1, findings.len);
    try testing.expectEqualStrings(driver.parse_rule_name, findings[0].rule);
    try testing.expectEqual(1, findings[0].line);
    try testing.expect(findings[0].message.len != 0);
}

test "--rule limits the dispatch to the named rules" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source: [:0]const u8 = "const page = 1;\n";
    var tree = try Ast.parse(arena, source, .zig);
    defer tree.deinit(arena);

    var run = new_run(arena);
    const file: report.File = .{ .path = "src/store/page.zig", .source = source, .tree = &tree };
    try Linter.dispatch(&run, file);
    try testing.expectEqual(1, run.context.findings.count());
    const markdown_only = [_][]const u8{ "--rule", "markdown-probe", "src" };
    run.enabled = (try Linter.parse_arguments(arena, &markdown_only)).enabled;
    try Linter.dispatch(&run, file);
    try testing.expectEqual(1, run.context.findings.count());
}
