//! pepegrillo's lint over itself: the generic rules configured for this tree.
//!
//! Run: `zig build lint`, which passes build.zig, the source directories and the documents.

const std = @import("std");
const pepegrillo = @import("pepegrillo");
const rules = pepegrillo.lint.rules;

/// CLAUDE.md, Conventions: a hand-written file stays at or under 500 lines, its tests included.
pub const file_length = rules.file_length.Rule(.{
    .scope = .{ .extensions = &.{ ".zig", ".sh" }, .basenames = &.{"pre-push"} },
    .message_suffix = "; split the file",
});

/// CLAUDE.md, Conventions: every Markdown file renders on GitHub as written.
pub const markdown = rules.markdown.Rule(.{
    .scope = .{ .extensions = &.{".md"} },
    .pseudo_list_item = true,
    .code_span_pipe = true,
    .fence_language = true,
    .table_columns = true,
    .trailing_whitespace = true,
});

const Linter = pepegrillo.lint.Linter(.{ file_length, markdown });

pub fn main(init: std.process.Init) !void {
    return Linter.main(init);
}

// Tests. The rules carry their own; these pin this configuration.

const testing = std.testing;
const harness = pepegrillo.lint.harness;

test "file-length reads Zig files, shell scripts and the pre-push hook" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A comment line parses as Zig, so the same source serves every path.
    const long_source: [:0]const u8 = "//\n" ** 501;
    for ([_][]const u8{ "src/store/page.zig", "tools/run.sh", "hooks/pre-push" }) |path| {
        const findings = try harness.run(arena, file_length, path, long_source);
        const expected = "501 lines, over the 500-line limit; split the file";
        try harness.expect_messages(findings, &.{expected});
    }
    const document = try harness.run(arena, file_length, "docs/design.md", long_source);
    try harness.expect_messages(document, &.{});
}

test "markdown runs every check over every Markdown file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), markdown, "README.md",
        \\3b. Folded.
        \\
        \\```
        \\code
        \\```
        \\
        \\| a | b |
        \\| --- | --- |
        \\| `x|y` | z |
        \\| only |
        \\trailing 
        \\
    );
    try harness.expect_messages(findings, &.{
        "bare pseudo list item \"3b.\" folds into the paragraph above on GitHub;" ++
            " nest it as a list item",
        "fenced code block opened with no language",
        "table row holds 3 columns; its header holds 2",
        "pipe inside a code span on a table row splits the cell on GitHub; write it as \\|",
        "table row holds 1 columns; its header holds 2",
        "trailing whitespace",
    });
}
