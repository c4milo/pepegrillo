//! The shape of one commit message, as the rules of `rules.zig` read it: the subject line, the
//! body, and the trailer block. This file only splits text.
//!
//! `parse` splits the text into lines the way an editor shows them: one trailing newline is
//! removed first, so `subject\n` is one line and `subject\n\n` is two, the second blank. Line 0 is
//! the subject. The final block of `Key: value` lines whose keys are all in the configured
//! `trailer_keys` is the trailer block; it is parsed off, so the body rules never count it against
//! the paragraph, word or column limits. The body is what is left between the subject and the
//! trailer block, with the blank lines at either end left out.
//!
//! The trailer keys are a closed set because an open one lets a paragraph opt out of the body
//! rules by opening with one capitalised word and a colon. A final paragraph starting `Note: ` is
//! body, counted like any other body line.
//!
//! A block counts as trailers only when it is the last paragraph: the line before it is blank, or
//! it is the first line after the subject. A run of `Key: value` lines at the end of a longer
//! paragraph stays body.
//!
//! `strip_comments` drops the lines git's editor template writes, the ones starting with `#`. The
//! linter calls it on a `--message` file and never on `git log` output, where a body may open a
//! line with `#`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The byte that ends a line.
pub const line_feed: u8 = '\n';

/// The bytes that count as whitespace inside a line and at its end.
pub const whitespace = " \t\r";

/// The byte an editor comment line starts with in a message file git wrote.
pub const comment_prefix: u8 = '#';

/// The byte that separates a trailer key from its value.
pub const trailer_colon: u8 = ':';

/// The byte a trailer value starts with, after the colon.
pub const trailer_space: u8 = ' ';

/// One commit message split into the parts the rules check. `body_start`, `body_end`,
/// `trailer_start` and `trailer_end` index `lines`, so a rule can name the line a finding sits on.
pub const Message = struct {
    lines: []const []const u8,
    /// Line 0, or empty when the message holds no line at all.
    subject: []const u8,
    body_start: usize,
    body_end: usize,
    trailer_start: usize,
    trailer_end: usize,

    pub fn body_lines(self: *const Message) []const []const u8 {
        return self.lines[self.body_start..self.body_end];
    }

    pub fn trailer_lines(self: *const Message) []const []const u8 {
        return self.lines[self.trailer_start..self.trailer_end];
    }

    /// The 1-based line number of body line `index`.
    pub fn body_line_number(self: *const Message, index: usize) usize {
        return self.body_start + index + 1;
    }

    /// The index into `lines` of the first non-blank line after the subject, or null when the
    /// message is a subject and nothing else.
    pub fn first_content_index(self: *const Message) ?usize {
        var index: usize = 1;
        while (index < self.lines.len) : (index += 1) {
            if (!is_blank(self.lines[index])) return index;
        }
        return null;
    }
};

/// Splits `text` into a `Message`. A message of more than `max_lines` lines is an error.
pub fn parse(
    arena: Allocator,
    text: []const u8,
    trailer_keys: []const []const u8,
    max_lines: usize,
) !Message {
    const lines = try split_lines(arena, text, max_lines);
    if (lines.len == 0) {
        return .{
            .lines = lines,
            .subject = "",
            .body_start = 0,
            .body_end = 0,
            .trailer_start = 0,
            .trailer_end = 0,
        };
    }
    const content_end = last_content_end(lines);
    const trailer_start = trailer_start_index(lines, content_end, trailer_keys);
    var body_start: usize = 1;
    while (body_start < trailer_start and is_blank(lines[body_start])) body_start += 1;
    var body_end = trailer_start;
    while (body_end > body_start and is_blank(lines[body_end - 1])) body_end -= 1;
    return .{
        .lines = lines,
        .subject = lines[0],
        .body_start = body_start,
        .body_end = body_end,
        .trailer_start = trailer_start,
        .trailer_end = content_end,
    };
}

/// The lines of `text`, with one trailing newline removed first. Empty text holds no line at all;
/// `"\n"` holds one blank line.
fn split_lines(arena: Allocator, text: []const u8, max_lines: usize) ![]const []const u8 {
    if (text.len == 0) return &.{};
    const trimmed = if (text[text.len - 1] == line_feed) text[0 .. text.len - 1] else text;
    var list: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, trimmed, line_feed);
    while (iterator.next()) |line| {
        if (list.items.len >= max_lines) return error.TooManyLines;
        try list.append(arena, line);
    }
    return list.items;
}

/// One past the last non-blank line, never below 1, so the subject stays.
fn last_content_end(lines: []const []const u8) usize {
    var end = lines.len;
    while (end > 1 and is_blank(lines[end - 1])) end -= 1;
    return end;
}

/// The first line of the trailer block ending at `end`, or `end` itself when the last paragraph is
/// not a trailer block.
fn trailer_start_index(lines: []const []const u8, end: usize, keys: []const []const u8) usize {
    var start = end;
    while (start > 1 and is_trailer_line(lines[start - 1], keys)) start -= 1;
    if (start == end) return end;
    if (start > 1 and !is_blank(lines[start - 1])) return end;
    return start;
}

/// True when the line reads `Key: value` with a key of `keys`, the shape git calls a trailer.
pub fn is_trailer_line(line: []const u8, keys: []const []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, line, trailer_colon) orelse return false;
    if (!is_trailer_key(line[0..colon], keys)) return false;
    const value = line[colon + 1 ..];
    if (value.len == 0 or value[0] != trailer_space) return false;
    return std.mem.trim(u8, value, whitespace).len != 0;
}

/// True when the key is one of `keys`, whatever its case.
fn is_trailer_key(key: []const u8, keys: []const []const u8) bool {
    for (keys) |known| {
        if (std.ascii.eqlIgnoreCase(key, known)) return true;
    }
    return false;
}

/// True when the line holds nothing but whitespace.
pub fn is_blank(line: []const u8) bool {
    return std.mem.trim(u8, line, whitespace).len == 0;
}

/// The columns the line occupies: its codepoints, or its bytes when the line is not valid UTF-8.
pub fn columns(line: []const u8) usize {
    return std.unicode.utf8CountCodepoints(line) catch line.len;
}

/// The first whitespace-delimited word of the text, or empty text.
pub fn first_word(text: []const u8) []const u8 {
    var iterator = std.mem.tokenizeAny(u8, text, whitespace);
    return iterator.next() orelse "";
}

/// Blocks of consecutive non-blank lines.
pub fn count_paragraphs(lines: []const []const u8) usize {
    var count: usize = 0;
    var inside = false;
    for (lines) |line| {
        if (is_blank(line)) {
            inside = false;
            continue;
        }
        if (!inside) {
            count += 1;
            inside = true;
        }
    }
    return count;
}

/// Whitespace-delimited words across the lines.
pub fn count_words(lines: []const []const u8) usize {
    var count: usize = 0;
    for (lines) |line| {
        var iterator = std.mem.tokenizeAny(u8, line, whitespace);
        while (iterator.next()) |_| count += 1;
    }
    return count;
}

/// Blank lines at the end of the message.
pub fn count_trailing_blank_lines(lines: []const []const u8) usize {
    var count: usize = 0;
    while (count < lines.len and is_blank(lines[lines.len - 1 - count])) count += 1;
    return count;
}

/// The text with every `#` line removed, byte for byte otherwise, so the newline the message
/// ended with is the newline the copy ends with.
pub fn strip_comments(arena: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, text.len);
    var start: usize = 0;
    while (start < text.len) {
        const newline = std.mem.indexOfScalarPos(u8, text, start, line_feed);
        const end = if (newline) |index| index + 1 else text.len;
        if (text[start] != comment_prefix) out.appendSliceAssumeCapacity(text[start..end]);
        start = end;
    }
    return out.items;
}

// Tests. Each one pins a shape the header states, because every rule reads this split and a split
// that silently changed would move the rules off the lines they report.

const testing = std.testing;

/// The trailer keys the tests below parse with.
const test_keys = [_][]const u8{
    "Co-Authored-By", "Signed-off-by", "Reviewed-by", "Refs", "Closes",
};

/// The line cap the tests below parse with.
const test_max_lines: usize = 64;

fn parse_test(arena: Allocator, text: []const u8) !Message {
    return parse(arena, text, &test_keys, test_max_lines);
}

test "parse splits lines the way an editor shows them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(0, (try parse_test(arena, "")).lines.len);
    try testing.expectEqual(1, (try parse_test(arena, "\n")).lines.len);
    try testing.expectEqual(1, (try parse_test(arena, "feat(store): add x\n")).lines.len);
    try testing.expectEqual(2, (try parse_test(arena, "feat(store): add x\n\n")).lines.len);
    const unterminated = try parse_test(arena, "feat(store): add x");
    try testing.expectEqualStrings("feat(store): add x", unterminated.subject);
}

test "parse refuses a message over max_lines, never truncating it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(3, (try parse(arena, "a\nb\nc\n", &test_keys, 3)).lines.len);
    try testing.expectError(error.TooManyLines, parse(arena, "a\nb\nc\nd\n", &test_keys, 3));
}

test "parse takes the last Key: value block as trailers and leaves it out of the body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const message = try parse_test(arena,
        \\feat(store): add the page cache
        \\
        \\Why it exists.
        \\
        \\Co-Authored-By: A <a@example.com>
        \\Signed-off-by: B <b@example.com>
        \\
    );
    try testing.expectEqual(1, message.body_lines().len);
    try testing.expectEqualStrings("Why it exists.", message.body_lines()[0]);
    try testing.expectEqual(2, message.trailer_lines().len);
    try testing.expectEqualStrings("Signed-off-by: B <b@example.com>", message.trailer_lines()[1]);
    try testing.expectEqual(3, message.body_line_number(0));
}

test "a Key: value tail inside a paragraph stays body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const message = try parse_test(arena,
        \\feat(store): add the page cache
        \\
        \\Why it exists.
        \\Refs: https://example.com/issues/1
        \\
    );
    try testing.expectEqual(0, message.trailer_lines().len);
    try testing.expectEqual(2, message.body_lines().len);
}

test "the trailer block is parsed off the body, not left in it" {
    // Pins the split itself: a `trailer_start_index` that always answered `end` would leave these
    // two lines in the body and count them against the body limits.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const message = try parse_test(arena, "feat(store): add x\n\nwhy\n\nRefs: a\nCloses: b\n");
    try testing.expectEqual(2, message.trailer_lines().len);
    try testing.expectEqual(1, message.body_lines().len);
    try testing.expectEqualStrings("why", message.body_lines()[0]);
}

test "blank lines after the trailer block leave it trailers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const message = try parse_test(arena, "feat(store): add x\n\nwhy\n\nRefs: a\n\n\n");
    try testing.expectEqual(1, message.trailer_lines().len);
    try testing.expectEqualStrings("Refs: a", message.trailer_lines()[0]);
    try testing.expectEqual(1, message.body_lines().len);
}

test "a trailer block right under the subject is still trailers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const message = try parse_test(arena, "feat(store): add x\nRefs: a\n");
    try testing.expectEqual(1, message.trailer_lines().len);
    try testing.expectEqual(0, message.body_lines().len);
}

test "a subject with no body has an empty body and no trailers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const message = try parse_test(arena, "feat(store): add x\n");
    try testing.expectEqual(0, message.body_lines().len);
    try testing.expectEqual(0, message.trailer_lines().len);
    try testing.expectEqual(null, message.first_content_index());
}

test "first_content_index finds the first non-blank line after the subject" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const texts = [_][]const u8{ "feat: x\nbody\n", "feat: x\n\nbody\n", "feat: x\n\n\nbody\n" };
    for (texts, 1..) |text, want| {
        try testing.expectEqual(want, (try parse_test(arena, text)).first_content_index());
    }
}

test "is_trailer_line wants a known key, one space, and a value" {
    try testing.expect(is_trailer_line("Co-Authored-By: A <a@example.com>", &test_keys));
    try testing.expect(is_trailer_line("Refs: 1", &test_keys));
    try testing.expect(!is_trailer_line("Refs:1", &test_keys));
    try testing.expect(!is_trailer_line("Refs: ", &test_keys));
    try testing.expect(!is_trailer_line("no colon here", &test_keys));
    try testing.expect(!is_trailer_line("1st: x", &test_keys));
    try testing.expect(!is_trailer_line("two words: x", &test_keys));
    try testing.expect(!is_trailer_line(": x", &test_keys));
}

test "is_trailer_line takes every key of the closed set, in any case" {
    for (test_keys) |key| {
        var line_buffer: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buffer, "{s}: a value", .{key});
        try testing.expect(is_trailer_line(line, &test_keys));
        var lower_buffer: [128]u8 = undefined;
        const lowered = std.ascii.lowerString(&lower_buffer, key);
        var lowered_line: [128]u8 = undefined;
        const lowered_text = try std.fmt.bufPrint(&lowered_line, "{s}: a value", .{lowered});
        try testing.expect(is_trailer_line(lowered_text, &test_keys));
    }
}

test "is_trailer_line refuses a key outside the closed set" {
    try testing.expect(!is_trailer_line("Note: why it exists", &test_keys));
    try testing.expect(!is_trailer_line("Reason: why it exists", &test_keys));
    try testing.expect(!is_trailer_line("Body: why it exists", &test_keys));
}

test "is_trailer_line reads the keys it is given and no others" {
    const keys = [_][]const u8{"Change-Id"};
    try testing.expect(is_trailer_line("Change-Id: I0123", &keys));
    try testing.expect(!is_trailer_line("Refs: 1", &keys));
    try testing.expect(!is_trailer_line("Refs: 1", &.{}));
}

test "a final Note: paragraph is body, not trailers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const message = try parse_test(arena, "feat(store): add x\n\nNote: why it exists\n");
    try testing.expectEqual(0, message.trailer_lines().len);
    try testing.expectEqual(1, message.body_lines().len);
}

test "columns counts codepoints and falls back to bytes" {
    try testing.expectEqual(3, columns("abc"));
    try testing.expectEqual(1, columns("é"));
    try testing.expectEqual(2, columns("\xff\xfe"));
}

test "paragraphs, words and trailing blank lines are counted over the lines given" {
    const lines = [_][]const u8{ "one two", "", "three", "", "" };
    try testing.expectEqual(2, count_paragraphs(&lines));
    try testing.expectEqual(3, count_words(&lines));
    try testing.expectEqual(2, count_trailing_blank_lines(&lines));
    try testing.expectEqual(0, count_paragraphs(&.{}));
    try testing.expectEqual(2, count_trailing_blank_lines(&.{ "", "" }));
}

test "is_blank takes a space, a tab and a carriage return as whitespace" {
    try testing.expect(is_blank(""));
    try testing.expect(is_blank(" \t\r"));
    try testing.expect(!is_blank(" x "));
}

test "first_word takes the leading word" {
    try testing.expectEqualStrings("adds", first_word("adds a thing"));
    try testing.expectEqualStrings("add", first_word("  add"));
    try testing.expectEqualStrings("", first_word("   "));
}

test "strip_comments drops # lines and keeps every other byte" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const template = "feat: add x\n# please enter\n";
    try testing.expectEqualStrings("feat: add x\n", try strip_comments(arena, template));
    try testing.expectEqualStrings("a\nb", try strip_comments(arena, "a\n#c\nb"));
    const indented = " # not a comment\n";
    try testing.expectEqualStrings(indented, try strip_comments(arena, indented));
    try testing.expectEqualStrings("", try strip_comments(arena, "#only\n"));
}
