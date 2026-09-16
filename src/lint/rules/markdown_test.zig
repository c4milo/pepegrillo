//! Tests of the markdown rule. Each fixture pins one shape from the header of `markdown.zig`, under
//! one of two configurations:
//!
//! - `DocumentsOnly`: checks 1 and 2 over `.md` files directly inside a `docs` directory, with
//!   lowercase markers recorded at the marker's column and the default texts.
//! - `EveryCheck`: checks 1, 3, 4 and 5 over every `.md` file, with markers of either case
//!   recorded at column 1 and a check 1 text the configuration supplies.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const harness = @import("../harness.zig");
const report = @import("../report.zig");
const markdown = @import("markdown.zig");

const DocumentsOnly = markdown.Rule(.{
    .scope = .{ .extensions = &.{".md"}, .parent_directory_names = &.{"docs"} },
    .pseudo_list_item = true,
    .pseudo_list_letters = .lowercase,
    .pseudo_list_column = .marker,
    .code_span_pipe = true,
});

const EveryCheck = markdown.Rule(.{
    .scope = .{ .extensions = &.{".md"} },
    .pseudo_list_item = true,
    .fence_language = true,
    .table_columns = true,
    .trailing_whitespace = true,
    .messages = .{
        .pseudo_list_item = "bare \"{[marker]s}\" folds into the paragraph above; nest it",
    },
});

fn pseudo_item(comptime marker: []const u8) []const u8 {
    return "bare pseudo list item \"" ++ marker ++ "\" folds into the paragraph above on GitHub;" ++
        " nest it as a list item";
}

fn bare(comptime marker: []const u8) []const u8 {
    return "bare \"" ++ marker ++ "\" folds into the paragraph above; nest it";
}

const code_span_pipe = "pipe inside a code span on a table row splits the cell on GitHub;" ++
    " write it as \\|";
const no_language = "fenced code block opened with no language";
const trailing = "trailing whitespace";

fn findings_of(
    arena: Allocator,
    comptime rule: type,
    path: []const u8,
    source: [:0]const u8,
) ![]const report.Finding {
    return harness.run(arena, rule, path, source);
}

fn expect_findings(
    comptime rule: type,
    path: []const u8,
    source: [:0]const u8,
    expected: []const []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), rule, path, source);
    try harness.expect_messages(findings, expected);
}

// Checks 1 and 2, over documents alone.

test "pseudo_list_item flags a marker, indented or not, outside a fence, at the marker's column" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), DocumentsOnly, "docs/pseudo.md",
        \\3b. Folded into the paragraph above.
        \\  10c. Indented, still folded.
        \\```text
        \\0a. Code, not a list.
        \\```
        \\0a. After the fence.
    );
    try harness.expect_messages(findings, &.{
        pseudo_item("3b."),
        pseudo_item("10c."),
        pseudo_item("0a."),
    });
    try testing.expectEqual(2, findings[1].line);
    try testing.expectEqual(3, findings[1].column);
    try testing.expectEqual(6, findings[2].line);
}

test "pseudo_list_item passes a real list marker, a nested item, no space, an uppercase letter" {
    try expect_findings(DocumentsOnly, "docs/lists.md",
        \\3. A real ordered item.
        \\- 3b. Nested under a list marker.
        \\3b.Not followed by a space.
        \\3B. Uppercase is not the shape under lowercase.
    , &.{});
}

test "code_span_pipe flags an unescaped pipe inside a code span on a table row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), DocumentsOnly, "docs/pipes.md",
        \\| Name | Value |
        \\| --- | --- |
        \\| flags | `a|b` |
        \\| ok | `a\|b` |
        \\| plain | a|b |
        \\Not a row: `a|b`.
    );
    try harness.expect_messages(findings, &.{code_span_pipe});
    try testing.expectEqual(3, findings[0].line);
    try testing.expectEqual(13, findings[0].column);
}

test "code_span_pipe reads a run of backticks as one code span delimiter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), DocumentsOnly, "docs/runs.md",
        \\| a | b |
        \\| --- | --- |
        \\| x | ``foo|bar`` |
        \\| y | `` `a` b|c |
        \\| z | ``` `a` b|c |
        \\| w | `a` `` b |
        \\| v | `a | b`` |
    );
    try harness.expect_messages(findings, &.{code_span_pipe});
    try testing.expectEqual(3, findings[0].line);
    try testing.expectEqual(12, findings[0].column);
}

test "a scope of docs reads only .md files directly inside docs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = "3b. Folded.";
    try expect_findings(DocumentsOnly, "README.md", source, &.{});
    try expect_findings(DocumentsOnly, "spec/model/README.md", source, &.{});
    try expect_findings(DocumentsOnly, "docs/sub/guide.md", source, &.{});
    try expect_findings(DocumentsOnly, "docs/guide.txt", source, &.{});
    const inside = try findings_of(arena, DocumentsOnly, "./docs/scope.md", source);
    try testing.expectEqual(1, inside.len);
}

// Checks 1, 3, 4 and 5, over every document.

test "every check passes a document that renders as written" {
    try expect_findings(EveryCheck, "docs/guide.md",
        \\# Guide
        \\
        \\1. Step one.
        \\    1. Step one, part b.
        \\2. Step two.
        \\
        \\| Module | Imports |
        \\|---|---|
        \\| `store` | `core`, `wire` |
        \\| `index` | `core`, `store` |
        \\
        \\| One | Two | Three |
        \\|---|---|---|
        \\
        \\```zig
        \\const store = @import("store");
        \\```
        \\
        \\A cell may hold an escaped separator: `a \| b`.
    , &.{});
}

test "every check flags a bare pseudo list item, a wide table row and a fence with no language" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), EveryCheck, "docs/guide.md",
        \\# Guide
        \\
        \\3b. This folds into the paragraph above.
        \\
        \\| Module | Imports |
        \\|---|---|
        \\| `store` | `core` | `wire` |
        \\
        \\```
        \\const store = @import("store");
        \\```
    );
    try harness.expect_messages(findings, &.{
        bare("3b."),
        "table row holds 3 columns; its header holds 2",
        no_language,
    });
    try testing.expectEqual(3, findings[0].line);
    try testing.expectEqual(7, findings[1].line);
    try testing.expectEqual(9, findings[2].line);
}

test "trailing_whitespace flags a line inside a fence as well as outside" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = "# Guide  \n\n```zig\nconst a = 1;\t\n```\nclean\nspace then return \r\n";
    const findings = try findings_of(arena_state.allocator(), EveryCheck, "docs/guide.md", source);
    try harness.expect_messages(findings, &.{ trailing, trailing });
    try testing.expectEqual(1, findings[0].line);
    try testing.expectEqual(4, findings[1].line);
}

test "fence_language flags a fence followed by whitespace alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = "```  \ncode\n```\n";
    const findings = try findings_of(arena_state.allocator(), EveryCheck, "docs/guide.md", source);
    try harness.expect_messages(findings, &.{ trailing, no_language });
}

test "every check leaves the inside of a fence alone but for trailing whitespace" {
    try expect_findings(EveryCheck, "docs/guide.md",
        \\```text
        \\3b. Not a list item here.
        \\| one | two |
        \\| one | two | three |
        \\```
        \\| one | two |
        \\```text
        \\```
        \\| one | two | three |
    , &.{});
}

test "a scope of every .md file reads README files and no other file kind" {
    const source = "3b. Folded.";
    try expect_findings(EveryCheck, "README.md", source, &.{bare("3b.")});
    try expect_findings(EveryCheck, "./notes/README.md", source, &.{bare("3b.")});
    try expect_findings(EveryCheck, "src/store/page.zig.txt", source, &.{});
    try expect_findings(EveryCheck, "docs/guide.txt", source, &.{});
}

// The switches. One fixture holds every shape the two configurations above disagree on.

const disagreements: [:0]const u8 =
    "  3B. An uppercase marker, indented.\n" ++
    "| Name | Value |\n" ++
    "| --- | --- |\n" ++
    "| flags | `a|b` |\n" ++
    "\n" ++
    "```\n" ++
    "code \n" ++
    "```\n";

test "the two configurations read the disagreement fixture each their own way" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expect_findings(DocumentsOnly, "docs/guide.md", disagreements, &.{code_span_pipe});
    const every = try findings_of(arena, EveryCheck, "docs/guide.md", disagreements);
    try harness.expect_messages(every, &.{
        bare("3B."),
        "table row holds 3 columns; its header holds 2",
        no_language,
        trailing,
    });
    try testing.expectEqual(1, every[0].column);
    try testing.expectEqual(4, every[1].line);
}

test "pseudo_list_column and pseudo_list_letters come from the config" {
    const Marker = markdown.Rule(.{
        .scope = .{ .extensions = &.{".md"} },
        .pseudo_list_item = true,
        .pseudo_list_column = .marker,
    });
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const findings = try findings_of(arena, Marker, "docs/guide.md", disagreements);
    try harness.expect_messages(findings, &.{pseudo_item("3B.")});
    try testing.expectEqual(3, findings[0].column);
}

test "every check off reports nothing, and the rule name comes from the config" {
    const Off = markdown.Rule(.{ .name = "documents", .scope = .{ .extensions = &.{".md"} } });
    try expect_findings(Off, "docs/guide.md", disagreements, &.{});
    try testing.expectEqualStrings("documents", Off.name);
    try testing.expectEqualStrings("markdown", EveryCheck.name);
}
