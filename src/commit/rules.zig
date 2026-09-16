//! The eight commit-message rules, one named function each, over the `Message` of `message.zig`
//! and the project's `Config`. Every finding names the rule that produced it.
//!
//!  1. subject-format: the subject reads `type(scope)!: description`, as `subject.zig` states.
//!  2. subject-description: the description is non-empty, starts with a lowercase letter, does not
//!     end with a period, and is imperative. A first word ending in `ed` or `ing`, or one of
//!     `third_person_forms`, is not imperative unless it is one of `imperative_exceptions`. The
//!     four checks report separately, so a subject that breaks two of them says so twice.
//!  3. subject-length: the whole subject line is at most `max_subject_columns` columns.
//!  4. scope-known: when `known_scopes` is set, a well-formed scope outside it draws a finding of
//!     `unknown_scope_severity`. The grammar of rule 1 accepts any well-formed scope, so a project
//!     whose scope list grows with its code can warn on a new scope rather than refuse it.
//!  5. body-separation: when a body exists, exactly one blank line sits between it and the subject.
//!  6. body-line-length: every body line is at most `max_body_columns` columns.
//!  7. body-size: the body is at most `max_body_paragraphs` paragraphs and `max_body_words` words.
//!  8. whitespace: no line ends in whitespace, and the message ends with at most
//!     `max_trailing_blank_lines` blank lines.
//!
//! Rule 3 reads the subject and nothing else. Rules 5, 6 and 7 read the body with the trailer
//! block left out, so a `Co-Authored-By` line is neither a body line nor a body word, and no column
//! limit applies to it: an address or a URL a trailer carries is as long as it is. Rule 8 reads
//! every line, trailers included, because a trailer ending in a space is still a defect.
//!
//! Rules 2 and 4 report nothing when rule 1 could not parse the subject: there is no description
//! and no scope to judge, and rule 1 has already said so.

const std = @import("std");
const Config = @import("config.zig").Config;
const findings_model = @import("findings.zig");
const Findings = findings_model.Findings;
const message_model = @import("message.zig");
const Message = message_model.Message;
const subject = @import("subject.zig");

/// The word ending that marks a past tense, and the one that marks a gerund.
const past_tense_suffix = "ed";
const gerund_suffix = "ing";

/// The byte a description may not end with.
const description_period: u8 = '.';

pub const subject_format_rule = "subject-format";
pub const subject_description_rule = "subject-description";
pub const subject_length_rule = "subject-length";
pub const scope_known_rule = "scope-known";
pub const body_separation_rule = "body-separation";
pub const body_line_length_rule = "body-line-length";
pub const body_size_rule = "body-size";
pub const whitespace_rule = "whitespace";

/// Runs every rule over one message, in the order the header numbers them.
pub fn check_all(
    comptime config: Config,
    findings: *Findings,
    source: []const u8,
    message: *const Message,
) !void {
    try check_subject_format(config, findings, source, message);
    try check_subject_description(config, findings, source, message);
    try check_subject_length(config, findings, source, message);
    try check_scope_known(config, findings, source, message);
    try check_body_separation(findings, source, message);
    try check_body_line_length(config, findings, source, message);
    try check_body_size(config, findings, source, message);
    try check_whitespace(config, findings, source, message);
}

// Rule 1: the subject grammar.

fn check_subject_format(
    comptime config: Config,
    findings: *Findings,
    source: []const u8,
    message: *const Message,
) !void {
    _ = subject.parse_subject(config, message.subject) catch |err| {
        const text = subject.error_text(config, err);
        try findings.add(source, subject_format_rule, "{s}: \"{s}\"", .{ text, message.subject });
    };
}

// Rule 2: the description.

fn check_subject_description(
    comptime config: Config,
    findings: *Findings,
    source: []const u8,
    message: *const Message,
) !void {
    const parts = subject.parse_subject(config, message.subject) catch return;
    const description = parts.description;
    const rule = subject_description_rule;
    if (description.len == 0) {
        try findings.add(source, rule, "the description is empty", .{});
        return;
    }
    if (!std.ascii.isLower(description[0])) {
        const format = "the description does not start with a lowercase letter: \"{s}\"";
        try findings.add(source, rule, format, .{description});
    }
    if (description[description.len - 1] == description_period) {
        const format = "the description ends with a period: \"{s}\"";
        try findings.add(source, rule, format, .{description});
    }
    const word = message_model.first_word(description);
    if (non_imperative_reason(config, word)) |reason| {
        try findings.add(source, rule, "\"{s}\" is {s}, not imperative", .{ word, reason });
    }
}

/// Why the first word is not a command, or null when it reads as one. The exception list is read
/// first, because it names commands the suffix test below would otherwise refuse.
pub fn non_imperative_reason(comptime config: Config, word: []const u8) ?[]const u8 {
    if (subject.is_any_of(word, config.imperative_exceptions)) return null;
    if (subject.is_any_of(word, config.third_person_forms)) return "a third-person form";
    if (std.mem.endsWith(u8, word, gerund_suffix)) return "a gerund";
    if (std.mem.endsWith(u8, word, past_tense_suffix)) return "a past tense";
    return null;
}

// Rule 3: the subject length.

fn check_subject_length(
    comptime config: Config,
    findings: *Findings,
    source: []const u8,
    message: *const Message,
) !void {
    const width = message_model.columns(message.subject);
    const limit = config.max_subject_columns;
    if (width <= limit) return;
    const format = "the subject is {d} columns, over the {d}-column limit";
    try findings.add(source, subject_length_rule, format, .{ width, limit });
}

// Rule 4: the scope against the project's known scopes.

fn check_scope_known(
    comptime config: Config,
    findings: *Findings,
    source: []const u8,
    message: *const Message,
) !void {
    const known = config.known_scopes orelse return;
    const parts = subject.parse_subject(config, message.subject) catch return;
    const scope = parts.scope orelse return;
    if (subject.is_any_of(scope, known)) return;
    const reason = config.unknown_scope_reason;
    const list = comptime subject.joined(known);
    const format = "the scope \"{s}\" {s} ({s})";
    try findings.record(config.unknown_scope_severity, source, scope_known_rule, format, .{
        scope,
        reason,
        list,
    });
}

// Rule 5: the blank line under the subject.

fn check_body_separation(findings: *Findings, source: []const u8, message: *const Message) !void {
    const content = message.first_content_index() orelse return;
    const rule = body_separation_rule;
    if (content == 1) {
        try findings.add(source, rule, "no blank line between the subject and the body", .{});
        return;
    }
    if (content > 2) {
        const format = "{d} blank lines between the subject and the body, want exactly one";
        try findings.add(source, rule, format, .{content - 1});
    }
}

// Rule 6: the body line length.

fn check_body_line_length(
    comptime config: Config,
    findings: *Findings,
    source: []const u8,
    message: *const Message,
) !void {
    const limit = config.max_body_columns;
    for (message.body_lines(), 0..) |line, index| {
        const width = message_model.columns(line);
        if (width <= limit) continue;
        const format = "line {d} is {d} columns, over the {d}-column limit";
        const line_number = message.body_line_number(index);
        try findings.add(source, body_line_length_rule, format, .{ line_number, width, limit });
    }
}

// Rule 7: the body size.

fn check_body_size(
    comptime config: Config,
    findings: *Findings,
    source: []const u8,
    message: *const Message,
) !void {
    const body = message.body_lines();
    const paragraphs = message_model.count_paragraphs(body);
    const paragraph_limit = config.max_body_paragraphs;
    if (paragraphs > paragraph_limit) {
        const format = "the body has {d} paragraphs, over the limit of {d}";
        try findings.add(source, body_size_rule, format, .{ paragraphs, paragraph_limit });
    }
    const words = message_model.count_words(body);
    const word_limit = config.max_body_words;
    if (words > word_limit) {
        const format = "the body has {d} words, over the limit of {d}";
        try findings.add(source, body_size_rule, format, .{ words, word_limit });
    }
}

// Rule 8: the whitespace.

fn check_whitespace(
    comptime config: Config,
    findings: *Findings,
    source: []const u8,
    message: *const Message,
) !void {
    for (message.lines, 0..) |line, index| {
        if (std.mem.trimEnd(u8, line, message_model.whitespace).len == line.len) continue;
        try findings.add(source, whitespace_rule, "line {d} ends with whitespace", .{index + 1});
    }
    const blanks = message_model.count_trailing_blank_lines(message.lines);
    const limit = config.max_trailing_blank_lines;
    if (blanks > limit) {
        const format = "the message ends with {d} blank lines, over the limit of {d}";
        try findings.add(source, whitespace_rule, format, .{ blanks, limit });
    }
}
