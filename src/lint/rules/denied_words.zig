//! denied-words: no file in scope spells a word or a domain the project denies, such as the name
//! of a vendor a provider-neutral project must not mention.
//!
//! Over every file in `scope`, one line at a time, the rule reports, in any case:
//!
//! 1. Every whole-word occurrence of one of `words`, where a word is delimited by bytes that are
//!    not letters, digits or underscores, so `pencil` and `pen_holder` do not hold `pen`. The
//!    finding is `<word_label> "<text>"`, with the text as written.
//! 2. Every one of `domain_suffixes` that follows a hostname: the byte before it is a letter, a
//!    digit or a hyphen, and the hostname does not go on after it with another such byte or with a
//!    `.` that one follows. So for `.example`, `api.example/`, `host.example` and
//!    `See api.example.` are findings, and `dir.examples()` and `x.example.org` are not. The
//!    finding is `<domain_label> "<hostname>"`, the hostname being the labels and dots before the
//!    suffix together with the suffix.
//!
//! The file that holds a project's list spells the words it denies, so a project excludes it in
//! `scope.exclude_paths`.

const std = @import("std");
const report = @import("../report.zig");
const Scope = @import("../scope.zig").Scope;
const text = @import("../text.zig");

pub const Config = struct {
    /// The rule name findings are reported under and `--rule` selects.
    name: []const u8 = "denied-words",
    /// The files the rule reads.
    scope: Scope,
    /// Words matched whole, in any case.
    words: []const []const u8 = &.{},
    /// Domain suffixes, dot included, matched after a hostname in any case.
    domain_suffixes: []const []const u8 = &.{},
    /// What a word finding calls the word.
    word_label: []const u8 = "denied word",
    /// What a domain finding calls the hostname.
    domain_label: []const u8 = "denied domain",
};

/// The rule for one configuration: a type with the `name` and `check` the driver dispatches to.
pub fn Rule(comptime config: Config) type {
    comptime std.debug.assert(config.name.len != 0);
    comptime for (config.words) |word| std.debug.assert(word.len != 0);
    comptime for (config.domain_suffixes) |suffix| std.debug.assert(suffix.len != 0);
    return struct {
        pub const name = config.name;
        const settings: Config = config;

        pub fn check(context: *report.Context, file: report.File) !void {
            if (!settings.scope.applies(file.path)) return;
            try check_lines(context, file, &settings);
        }
    };
}

fn check_lines(context: *report.Context, file: report.File, config: *const Config) !void {
    var lines: text.LineIterator = .{ .source = file.source };
    while (lines.next()) |line| {
        const reader: LineReader = .{
            .findings = &context.findings,
            .path = file.path,
            .line = line,
            .config = config,
        };
        for (config.words) |word| try reader.check_word(word);
        for (config.domain_suffixes) |suffix| try reader.check_domain_suffix(suffix);
    }
}

/// The checks over one line.
const LineReader = struct {
    findings: *report.Findings,
    path: []const u8,
    line: text.Line,
    config: *const Config,

    fn check_word(self: *const LineReader, word: []const u8) !void {
        const line = self.line.text;
        var from: usize = 0;
        while (std.ascii.indexOfIgnoreCasePos(line, from, word)) |index| : (from = index + 1) {
            const end = index + word.len;
            if (index > 0 and text.is_word_byte(line[index - 1])) continue;
            if (end < line.len and text.is_word_byte(line[end])) continue;
            try self.add(index, self.config.word_label, line[index..end]);
        }
    }

    fn check_domain_suffix(self: *const LineReader, suffix: []const u8) !void {
        const line = self.line.text;
        var from: usize = 0;
        while (std.ascii.indexOfIgnoreCasePos(line, from, suffix)) |index| : (from = index + 1) {
            const end = index + suffix.len;
            if (index == 0 or !is_hostname_byte(line[index - 1])) continue;
            if (continues_hostname(line, end)) continue;
            const hostname_start = find_hostname_start(line, index);
            try self.add(hostname_start, self.config.domain_label, line[hostname_start..end]);
        }
    }

    fn add(self: *const LineReader, index: usize, label: []const u8, written: []const u8) !void {
        const name = self.config.name;
        try self.findings.add(name, self.path, self.line.number, index + 1, "{s} \"{s}\"", .{
            label, written,
        });
    }
};

/// True when the hostname goes on past `end`: the byte there is a hostname byte, or a `.` that a
/// hostname byte follows. A `.` that ends the line or precedes a space ends a sentence.
fn continues_hostname(line: []const u8, end: usize) bool {
    if (end >= line.len) return false;
    if (is_hostname_byte(line[end])) return true;
    if (line[end] != '.') return false;
    return end + 1 < line.len and is_hostname_byte(line[end + 1]);
}

/// A byte of a hostname label: a letter, a digit, or a hyphen.
fn is_hostname_byte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-';
}

/// The index where the hostname that ends at `suffix_index` begins: the labels and dots before
/// the suffix.
fn find_hostname_start(line: []const u8, suffix_index: usize) usize {
    var start = suffix_index;
    while (start > 0 and (is_hostname_byte(line[start - 1]) or line[start - 1] == '.')) start -= 1;
    return start;
}

test {
    _ = @import("denied_words_test.zig");
}
