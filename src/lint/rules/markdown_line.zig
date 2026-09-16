//! The readers the markdown checks apply to one line: the marker of a pseudo list item, the column
//! of a pipe inside a code span, and the column count of a table row.
//!
//! Split off `markdown.zig` so that file holds the configuration and the checks, and this one holds
//! the reads.

const std = @import("std");

/// The byte that opens and closes a code span, in a run of one or more.
pub const code_span_marker: u8 = '`';

/// The cell separator of a table row.
pub const cell_separator: u8 = '|';

/// The byte that escapes a cell separator inside a cell or a code span.
const escape: u8 = '\\';

/// Which letters a pseudo list item marker may hold after its digits.
pub const LetterCase = enum {
    /// `3b.` and not `3B.`.
    lowercase,
    /// `3b.` and `3B.`.
    any,
};

/// The `3b.` of a line that starts with digits, one letter of `letters`, a period and a space.
pub fn pseudo_list_marker(line: []const u8, letters: LetterCase) ?[]const u8 {
    var index: usize = 0;
    while (index < line.len and std.ascii.isDigit(line[index])) index += 1;
    if (index == 0) return null;
    if (index + 2 >= line.len) return null;
    if (!is_letter(line[index], letters)) return null;
    if (line[index + 1] != '.' or line[index + 2] != ' ') return null;
    return line[0 .. index + 2];
}

fn is_letter(byte: u8, letters: LetterCase) bool {
    return switch (letters) {
        .lowercase => std.ascii.isLower(byte),
        .any => std.ascii.isAlphabetic(byte),
    };
}

/// The 1-based column of the first unescaped `|` inside a code span. A run of backticks opens a
/// span that the next run of the same length closes, as CommonMark reads it; a run with no
/// closing run is text.
pub fn pipe_in_code_span(line: []const u8) ?usize {
    var index: usize = 0;
    while (std.mem.indexOfScalarPos(u8, line, index, code_span_marker)) |open| {
        const run = backtick_run(line, open);
        const span_start = open + run;
        const close = closing_run(line, span_start, run) orelse {
            index = span_start;
            continue;
        };
        if (unescaped_pipe(line[span_start..close])) |offset| return span_start + offset + 1;
        index = close + run;
    }
    return null;
}

/// The number of backticks in the run that starts at `start`.
fn backtick_run(line: []const u8, start: usize) usize {
    var end = start;
    while (end < line.len and line[end] == code_span_marker) end += 1;
    return end - start;
}

/// The index of the first backtick run at or after `from` that holds exactly `length` backticks.
fn closing_run(line: []const u8, from: usize, length: usize) ?usize {
    var index = from;
    while (std.mem.indexOfScalarPos(u8, line, index, code_span_marker)) |start| {
        const run = backtick_run(line, start);
        if (run == length) return start;
        index = start + run;
    }
    return null;
}

/// The offset of the first `|` in `span` that no backslash precedes.
fn unescaped_pipe(span: []const u8) ?usize {
    for (span, 0..) |byte, offset| {
        if (byte != cell_separator) continue;
        if (offset > 0 and span[offset - 1] == escape) continue;
        return offset;
    }
    return null;
}

/// The number of cells a table row holds. The outer separators are not cells, so `| a | b |`
/// holds two; a separator escaped as `\|` is content and does not split a cell. A `|` inside a
/// code span splits a cell, as it does on GitHub.
pub fn count_columns(row: []const u8) usize {
    const trimmed = std.mem.trimEnd(u8, row, " \t");
    var body = trimmed;
    if (body.len != 0 and body[0] == cell_separator) body = body[1..];
    // A final separator is not a cell. An escaped one is left for the loop, which skips it.
    if (body.len != 0 and body[body.len - 1] == cell_separator) body = body[0 .. body.len - 1];
    var cells: usize = 1;
    for (body, 0..) |byte, index| {
        if (byte != cell_separator) continue;
        if (index != 0 and body[index - 1] == escape) continue;
        cells += 1;
    }
    return cells;
}

// Tests.

const testing = std.testing;

test "pseudo_list_marker reads digits, one letter, a period and a space" {
    try testing.expectEqualStrings("3b.", pseudo_list_marker("3b. text", .any).?);
    try testing.expectEqualStrings("0a.", pseudo_list_marker("0a. text", .lowercase).?);
    try testing.expectEqualStrings("12A.", pseudo_list_marker("12A. text", .any).?);
    try testing.expectEqual(null, pseudo_list_marker("12A. text", .lowercase));
    try testing.expectEqual(null, pseudo_list_marker("3. text", .any));
    try testing.expectEqual(null, pseudo_list_marker("3b.text", .any));
    try testing.expectEqual(null, pseudo_list_marker("b. text", .any));
    try testing.expectEqual(null, pseudo_list_marker("3b.", .any));
    try testing.expectEqual(null, pseudo_list_marker("3bc. text", .any));
}

test "pipe_in_code_span finds the first unescaped pipe inside a span" {
    try testing.expectEqual(13, pipe_in_code_span("| flags | `a|b` |"));
    try testing.expectEqual(null, pipe_in_code_span("| ok | `a\\|b` |"));
    try testing.expectEqual(null, pipe_in_code_span("| plain | a|b |"));
    try testing.expectEqual(12, pipe_in_code_span("| x | ``foo|bar`` |"));
    try testing.expectEqual(null, pipe_in_code_span("| y | `` `a` b|c |"));
    try testing.expectEqual(null, pipe_in_code_span("| w | `a` `` b |"));
    try testing.expectEqual(null, pipe_in_code_span("| v | `a | b`` |"));
}

test "count_columns counts a table's cells the way GitHub splits them" {
    try testing.expectEqual(2, count_columns("| a | b |"));
    try testing.expectEqual(2, count_columns("|---|---|"));
    try testing.expectEqual(3, count_columns("| a | b | c |"));
    try testing.expectEqual(2, count_columns("| a \\| b | c |"));
    try testing.expectEqual(2, count_columns("| a `x | y` |"));
    try testing.expectEqual(2, count_columns("| a | b"));
    try testing.expectEqual(2, count_columns("| a | b \\|"));
    try testing.expectEqual(1, count_columns("|"));
}
