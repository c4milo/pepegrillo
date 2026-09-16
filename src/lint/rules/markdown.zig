//! markdown: a Markdown file renders on GitHub as it is written.
//!
//! Over every file `scope` selects, the rule reads one line at a time and makes up to five checks.
//! The configuration switches each one on.
//!
//! 1. `pseudo_list_item`: a line that starts, after its indentation, with digits, one letter, a
//!    period and a space, such as `3b. `. GitHub folds it into the paragraph above instead of
//!    rendering a list item. `pseudo_list_letters` says which letters count, and
//!    `pseudo_list_column` says which column the finding records.
//! 2. `code_span_pipe`: an unescaped `|` inside a code span on a table row, a line that starts
//!    with `|` after its indentation. GitHub splits the cell there unless the pipe is written
//!    `\|`. The finding records the pipe's column.
//! 3. `fence_language`: a fenced code block opened with no language, three backticks with nothing
//!    after them.
//! 4. `table_columns`: a table row whose column count differs from its header's, the first row of
//!    the run of rows it belongs to. Cells are split on every `|` no backslash escapes, the way
//!    GitHub splits them, so a `|` inside a code span counts as a cell boundary. A separator row
//!    is measured too.
//! 5. `trailing_whitespace`: a line whose last byte before its newline is a space or a tab. Two
//!    trailing spaces are a hard line break, which the source does not show and the render does.
//!
//! A line that starts with three backticks after its indentation opens or closes a fenced code
//! block. Checks 1 to 4 skip the inside of a fence, where the text is not Markdown. Check 5 does
//! not: trailing whitespace inside a fence is still trailing whitespace in the file. Checks 3, 4
//! and 5 record column 1.
//!
//! What the rule does not check: the render itself. It reads lines, not a document tree, so a
//! table written without its outer pipes, or a fence opened inside a list item's indentation, is
//! outside what it can see.

const std = @import("std");
const report = @import("../report.zig");
const text = @import("../text.zig");
const Scope = @import("../scope.zig").Scope;
const line_read = @import("markdown_line.zig");

pub const LetterCase = line_read.LetterCase;

/// The line that opens and closes a fenced code block.
const fence_marker = "```";

/// The bytes a line's indentation is made of.
const indentation = " \t";

/// Which column check 1 records. The report does not print the column; it orders two findings on
/// one line.
pub const Column = enum {
    /// Column 1.
    first,
    /// The column of the marker's first digit, after the indentation.
    marker,
};

/// The finding texts. Each is a `std.fmt` format string, so a literal brace is written `{{` or
/// `}}`, and each must use every argument its comment names.
pub const Messages = struct {
    /// Check 1. `marker`: the marker without its space, such as `3b.`.
    pseudo_list_item: []const u8 = "bare pseudo list item \"{[marker]s}\" folds into the" ++
        " paragraph above on GitHub; nest it as a list item",
    /// Check 2. No arguments.
    code_span_pipe: []const u8 = "pipe inside a code span on a table row splits the cell on" ++
        " GitHub; write it as \\|",
    /// Check 3. No arguments.
    fence_language: []const u8 = "fenced code block opened with no language",
    /// Check 4. `columns`: the row's count. `header_columns`: the header's count.
    table_columns: []const u8 = "table row holds {[columns]d} columns; its header holds" ++
        " {[header_columns]d}",
    /// Check 5. No arguments.
    trailing_whitespace: []const u8 = "trailing whitespace",
};

pub const Config = struct {
    /// The name `--rule` selects and the report prints.
    name: []const u8 = "markdown",
    /// The files the rule reads.
    scope: Scope,
    /// Check 1.
    pseudo_list_item: bool = false,
    pseudo_list_letters: LetterCase = .any,
    pseudo_list_column: Column = .first,
    /// Check 2.
    code_span_pipe: bool = false,
    /// Check 3.
    fence_language: bool = false,
    /// Check 4.
    table_columns: bool = false,
    /// Check 5.
    trailing_whitespace: bool = false,
    messages: Messages = .{},
};

pub fn Rule(comptime config: Config) type {
    return struct {
        pub const name = config.name;

        pub fn check(context: *report.Context, file: report.File) !void {
            if (!config.scope.applies(file.path)) return;
            var scanner: Scanner = .{ .findings = &context.findings, .path = file.path };
            var lines: text.LineIterator = .{ .source = file.source };
            while (lines.next()) |line| try scanner.read(config, line);
        }
    };
}

/// Reads a document one line at a time, carrying what a line check needs from the lines before
/// it: whether the line is inside a fenced code block, and the column count of the table header
/// above it.
const Scanner = struct {
    findings: *report.Findings,
    path: []const u8,
    inside_fence: bool = false,
    /// Columns the header of the table being read declared, or null between tables.
    table_columns: ?usize = null,

    fn read(self: *Scanner, comptime config: Config, line: text.Line) !void {
        if (config.trailing_whitespace) try self.check_trailing_whitespace(config, line);
        const trimmed = std.mem.trimStart(u8, line.text, indentation);
        if (std.mem.startsWith(u8, trimmed, fence_marker)) {
            return self.read_fence(config, line, trimmed);
        }
        if (self.inside_fence) return;
        if (config.pseudo_list_item) try self.check_pseudo_list_item(config, line, trimmed);
        if (config.code_span_pipe) try self.check_code_span_pipe(config, line, trimmed);
        if (config.table_columns) try self.check_table_row(config, line, trimmed);
    }

    /// Opens or closes a fence, and runs check 3 on an opening one.
    fn read_fence(
        self: *Scanner,
        comptime config: Config,
        line: text.Line,
        trimmed: []const u8,
    ) !void {
        self.table_columns = null;
        self.inside_fence = !self.inside_fence;
        // A closing fence carries no language, so only the opening one is checked.
        if (!config.fence_language or !self.inside_fence) return;
        const language = std.mem.trim(u8, trimmed[fence_marker.len..], indentation);
        if (language.len != 0) return;
        try self.add(config, line.number, 1, config.messages.fence_language, .{});
    }

    /// Check 1.
    fn check_pseudo_list_item(
        self: *Scanner,
        comptime config: Config,
        line: text.Line,
        trimmed: []const u8,
    ) !void {
        const marker = line_read.pseudo_list_marker(trimmed, config.pseudo_list_letters) orelse {
            return;
        };
        const column = switch (config.pseudo_list_column) {
            .first => 1,
            .marker => line.text.len - trimmed.len + 1,
        };
        const arguments = .{ .marker = marker };
        try self.add(config, line.number, column, config.messages.pseudo_list_item, arguments);
    }

    /// Check 2.
    fn check_code_span_pipe(
        self: *Scanner,
        comptime config: Config,
        line: text.Line,
        trimmed: []const u8,
    ) !void {
        if (trimmed.len == 0 or trimmed[0] != line_read.cell_separator) return;
        const column = line_read.pipe_in_code_span(line.text) orelse return;
        try self.add(config, line.number, column, config.messages.code_span_pipe, .{});
    }

    /// Check 4. Every line outside a fence passes through here, so a line that is not a table row
    /// ends the table.
    fn check_table_row(
        self: *Scanner,
        comptime config: Config,
        line: text.Line,
        trimmed: []const u8,
    ) !void {
        if (trimmed.len == 0 or trimmed[0] != line_read.cell_separator) {
            self.table_columns = null;
            return;
        }
        const columns = line_read.count_columns(trimmed);
        const header_columns = self.table_columns orelse {
            self.table_columns = columns;
            return;
        };
        if (columns == header_columns) return;
        const arguments = .{ .columns = columns, .header_columns = header_columns };
        try self.add(config, line.number, 1, config.messages.table_columns, arguments);
    }

    /// Check 5, read on the line as written: a line ending in a carriage return ends in no space.
    fn check_trailing_whitespace(self: *Scanner, comptime config: Config, line: text.Line) !void {
        if (line.raw.len == 0) return;
        const last = line.raw[line.raw.len - 1];
        if (last != ' ' and last != '\t') return;
        try self.add(config, line.number, 1, config.messages.trailing_whitespace, .{});
    }

    fn add(
        self: *Scanner,
        comptime config: Config,
        line_number: usize,
        column: usize,
        comptime format: []const u8,
        arguments: anytype,
    ) !void {
        try self.findings.add(config.name, self.path, line_number, column, format, arguments);
    }
};

test {
    _ = line_read;
    _ = @import("markdown_test.zig");
}
