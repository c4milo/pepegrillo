//! Tests of the relative-import rule. Each fixture pins one shape from the header of
//! `relative_import.zig`, under one of two configurations:
//!
//! - `ByParent`: `.parent_or_absolute` over `src/` alone, with a text the configuration supplies.
//! - `BySubsystem`: `.leaves_subsystem` over every Zig file, with the default text.

const std = @import("std");
const testing = std.testing;
const harness = @import("../harness.zig");
const relative_import = @import("relative_import.zig");

const ByParent = relative_import.Rule(.{
    .scope = .{ .extensions = &.{".zig"}, .include_directories = &.{"src"} },
    .mode = .parent_or_absolute,
    .message = "@import(\"{[path]s}\") reaches out of the module by path; import its build name",
});

const BySubsystem = relative_import.Rule(.{
    .scope = .{ .extensions = &.{".zig"} },
    .mode = .leaves_subsystem,
});

fn by_parent(comptime path: []const u8) []const u8 {
    return "@import(\"" ++ path ++ "\") reaches out of the module by path; import its build name";
}

fn by_subsystem(comptime path: []const u8) []const u8 {
    return "@import(\"" ++ path ++ "\") leaves the module; import the module by name";
}

fn expect_findings(
    comptime rule: type,
    path: []const u8,
    source: [:0]const u8,
    expected: []const []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), rule, path, source);
    try harness.expect_messages(findings, expected);
}

// Both modes.

const absolute = "/home/someone/project/src/core/core.zig";

test "both modes flag a parent path to another module and an absolute path, at the @import" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source =
        \\const core = @import("../core/core.zig");
        \\const pinned = @import("/home/someone/project/src/core/core.zig");
        \\const sideways = @import("../../tools/lint/ast.zig");
    ;
    const arena = arena_state.allocator();
    const by_subsystem_findings = try harness.run(arena, BySubsystem, "src/store/page.zig", source);
    try harness.expect_messages(by_subsystem_findings, &.{
        by_subsystem("../core/core.zig"),
        by_subsystem(absolute),
        by_subsystem("../../tools/lint/ast.zig"),
    });
    try testing.expectEqual(1, by_subsystem_findings[0].line);
    try testing.expectEqual(14, by_subsystem_findings[0].column);
    try expect_findings(ByParent, "src/store/page.zig", source, &.{
        by_parent("../core/core.zig"),
        by_parent(absolute),
        by_parent("../../tools/lint/ast.zig"),
    });
}

test "both modes flag an @import nested inside an expression" {
    const source =
        \\const Header = @import("../core/core.zig").message.Header;
        \\fn read() void {
        \\    const table = @import("../index/table.zig").Table;
        \\    _ = table;
        \\}
    ;
    const expected_by_subsystem = [_][]const u8{
        by_subsystem("../core/core.zig"),
        by_subsystem("../index/table.zig"),
    };
    try expect_findings(BySubsystem, "src/store/page.zig", source, &expected_by_subsystem);
    const expected_by_parent = [_][]const u8{
        by_parent("../core/core.zig"),
        by_parent("../index/table.zig"),
    };
    try expect_findings(ByParent, "src/store/page.zig", source, &expected_by_parent);
}

test "both modes pass module names, sibling files and subdirectories" {
    const source =
        \\const std = @import("std");
        \\const core = @import("core");
        \\const constants = @import("constants.zig");
        \\const header = @import("journal/journal_header.zig");
        \\const dotted = @import("page.b.zig");
        \\const corpus = @embedFile("../golden/entries.bin");
    ;
    try expect_findings(BySubsystem, "src/store/page.zig", source, &.{});
    try expect_findings(ByParent, "src/store/page.zig", source, &.{});
}

test "both modes pass other builtins and a computed name" {
    const source =
        \\const bytes = @embedFile("../fixture.bin");
        \\const module = @import(module_name);
        \\const number = @as(u32, 1);
    ;
    try expect_findings(BySubsystem, "src/store/page.zig", source, &.{});
    try expect_findings(ByParent, "src/store/page.zig", source, &.{});
}

// `.leaves_subsystem`.

test "leaves_subsystem allows a subdirectory reaching its own subsystem" {
    try expect_findings(BySubsystem, "src/store/journal/journal_open.zig",
        \\const constants = @import("../constants.zig");
        \\const superblock = @import("../superblock.zig");
        \\const sibling = @import("journal_slots.zig");
        \\const core = @import("core");
    , &.{});
}

test "leaves_subsystem flags a subdirectory reaching another subsystem" {
    try expect_findings(BySubsystem, "src/test/disk/disk.zig",
        \\const key = @import("../../index/key.zig");
    , &.{by_subsystem("../../index/key.zig")});
}

test "a scope of every Zig file reads tools too, and no other file kind" {
    const source = "const out = @import(\"../../src/core/core.zig\");";
    try expect_findings(BySubsystem, "tools/lint/main.zig", source, &.{
        by_subsystem("../../src/core/core.zig"),
    });
    try expect_findings(BySubsystem, "docs/guide.md", source, &.{});
}

test "leaves_subsystem reads its subsystem from source_root" {
    const Library = relative_import.Rule(.{
        .scope = .{ .extensions = &.{".zig"} },
        .mode = .leaves_subsystem,
        .source_root = "lib",
        .message = "{[path]s}",
    });
    const source = "const constants = @import(\"../constants.zig\");";
    try expect_findings(Library, "lib/store/journal/open.zig", source, &.{});
    try expect_findings(Library, "src/store/journal/open.zig", source, &.{});
    try expect_findings(BySubsystem, "lib/store/journal/open.zig", source, &.{});
    const climb = "const core = @import(\"../../core.zig\");";
    try expect_findings(Library, "src/store/journal/open.zig", climb, &.{});
    try expect_findings(Library, "lib/store/journal/open.zig", climb, &.{"../../core.zig"});
}

// `.parent_or_absolute`.

test "a scope of src reads src alone" {
    const source = "const core = @import(\"../core/core.zig\");";
    try expect_findings(ByParent, "tools/graph.zig", source, &.{});
    try expect_findings(ByParent, "build/modules.zig", source, &.{});
    const expected = [_][]const u8{by_parent("../core/core.zig")};
    try expect_findings(ByParent, "./src/store/page.zig", source, &expected);
}

// The switch. Each fixture holds a shape the two modes disagree on.

test "the two modes read the disagreement fixtures each their own way" {
    const own_constants = "const constants = @import(\"../constants.zig\");";
    try expect_findings(BySubsystem, "src/store/journal/open.zig", own_constants, &.{});
    try expect_findings(ByParent, "src/store/journal/open.zig", own_constants, &.{
        by_parent("../constants.zig"),
    });
    const from_source_root = "const page = @import(\"store/page.zig\");";
    try expect_findings(BySubsystem, "src/main.zig", from_source_root, &.{
        by_subsystem("store/page.zig"),
    });
    try expect_findings(ByParent, "src/main.zig", from_source_root, &.{});
}

test "the rule name comes from the config" {
    const Renamed = relative_import.Rule(.{
        .name = "module-path",
        .scope = .{ .extensions = &.{".zig"} },
        .mode = .parent_or_absolute,
    });
    try testing.expectEqualStrings("module-path", Renamed.name);
    try testing.expectEqualStrings("relative-import", BySubsystem.name);
}

// Parameter types.

const ByParentSimplePrototypes = relative_import.Rule(.{
    .scope = .{ .extensions = &.{".zig"}, .include_directories = &.{"src"} },
    .mode = .parent_or_absolute,
    .message = "@import(\"{[path]s}\") reaches out of the module by path; import its build name",
    .parameter_types = .simple_prototypes_only,
});

test "parameter_types decides whether an import in a two-parameter prototype is read" {
    const source =
        \\fn open(file: @import("../file.zig").File, flags: u32) void {
        \\    _ = file;
        \\    _ = flags;
        \\}
        \\fn close(file: @import("../handle.zig").Handle) void {
        \\    _ = file;
        \\}
    ;
    const path = "src/store/page.zig";
    try expect_findings(ByParent, path, source, &.{
        by_parent("../file.zig"),
        by_parent("../handle.zig"),
    });
    try expect_findings(ByParentSimplePrototypes, path, source, &.{by_parent("../handle.zig")});
}
