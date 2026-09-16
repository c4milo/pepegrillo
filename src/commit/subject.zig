//! The subject grammar: `type(scope)!: description`, with the scope and the `!` optional. The type
//! is one of the configured `commit_types`. The scope, when present, holds lowercase letters and
//! hyphens, and digits too when `scope_admits_digits` is set. One space follows the colon.
//!
//! `parse_subject` splits a subject into its parts or names the first way it breaks the grammar.
//! `error_text` is the sentence the `subject-format` rule prints for that error.

const std = @import("std");
const Config = @import("config.zig").Config;

/// The bytes the subject grammar is written with.
const type_separator: u8 = ':';
const separator_space: u8 = ' ';
const breaking_marker: u8 = '!';
const scope_open: u8 = '(';
const scope_close: u8 = ')';
const scope_hyphen: u8 = '-';

pub const SubjectError = error{
    MissingSeparator,
    UnknownType,
    UnclosedScope,
    EmptyScope,
    ScopeNotLowercase,
    MissingSpaceAfterColon,
};

pub const SubjectParts = struct {
    type_name: []const u8,
    scope: ?[]const u8,
    breaking: bool,
    description: []const u8,
};

pub fn parse_subject(comptime config: Config, subject: []const u8) SubjectError!SubjectParts {
    const colon = std.mem.indexOfScalar(u8, subject, type_separator) orelse
        return error.MissingSeparator;
    const marked = strip_breaking(subject[0..colon]);
    const scoped = try strip_scope(marked.head, config.scope_admits_digits);
    if (!is_any_of(scoped.head, config.commit_types)) return error.UnknownType;
    return .{
        .type_name = scoped.head,
        .scope = scoped.scope,
        .breaking = marked.breaking,
        .description = try description_after(subject[colon + 1 ..]),
    };
}

const Marked = struct { head: []const u8, breaking: bool };

fn strip_breaking(head: []const u8) Marked {
    if (head.len != 0 and head[head.len - 1] == breaking_marker) {
        return .{ .head = head[0 .. head.len - 1], .breaking = true };
    }
    return .{ .head = head, .breaking = false };
}

const Scoped = struct { head: []const u8, scope: ?[]const u8 };

fn strip_scope(head: []const u8, admits_digits: bool) SubjectError!Scoped {
    if (head.len == 0 or head[head.len - 1] != scope_close) {
        if (std.mem.indexOfScalar(u8, head, scope_open) != null) return error.UnclosedScope;
        return .{ .head = head, .scope = null };
    }
    const open = std.mem.indexOfScalar(u8, head, scope_open) orelse return error.UnclosedScope;
    const scope = head[open + 1 .. head.len - 1];
    if (scope.len == 0) return error.EmptyScope;
    if (!is_well_formed_scope(scope, admits_digits)) return error.ScopeNotLowercase;
    return .{ .head = head[0..open], .scope = scope };
}

fn description_after(rest: []const u8) SubjectError![]const u8 {
    if (rest.len == 0 or rest[0] != separator_space) return error.MissingSpaceAfterColon;
    return rest[1..];
}

/// True when `word` is one of `set`, byte for byte.
pub fn is_any_of(word: []const u8, set: []const []const u8) bool {
    for (set) |item| {
        if (std.mem.eql(u8, word, item)) return true;
    }
    return false;
}

/// True when every byte of the scope is a lowercase letter or a hyphen, or a digit when
/// `admits_digits` is set.
pub fn is_well_formed_scope(scope: []const u8, admits_digits: bool) bool {
    for (scope) |byte| {
        if (std.ascii.isLower(byte) or byte == scope_hyphen) continue;
        if (admits_digits and std.ascii.isDigit(byte)) continue;
        return false;
    }
    return true;
}

/// The items joined with `, `, so a message prints the same list the check reads.
pub fn joined(comptime items: []const []const u8) []const u8 {
    comptime {
        var text: []const u8 = "";
        for (items, 0..) |item, index| {
            text = text ++ (if (index == 0) "" else ", ") ++ item;
        }
        return text;
    }
}

pub fn error_text(comptime config: Config, err: SubjectError) []const u8 {
    return switch (err) {
        error.MissingSeparator => "no `type(scope)!: description` colon",
        error.UnknownType => "the type is not one of " ++ comptime joined(config.commit_types),
        error.UnclosedScope => "the scope is not closed with `)`",
        error.EmptyScope => "the scope is empty",
        error.ScopeNotLowercase => if (config.scope_admits_digits)
            "the scope holds a byte that is not a lowercase letter, a digit, or a hyphen"
        else
            "the scope holds a byte that is not a lowercase letter or a hyphen",
        error.MissingSpaceAfterColon => "the colon is not followed by one space",
    };
}

// Tests. The rules' tests in `rules_test.zig` pin the sentences; these pin the parts.

const testing = std.testing;

const digits: Config = .{
    .scope_admits_digits = true,
    .third_person_forms = &.{},
    .imperative_exceptions = &.{},
};

const letters_only: Config = .{
    .scope_admits_digits = false,
    .third_person_forms = &.{},
    .imperative_exceptions = &.{},
};

test "parse_subject splits the type, the scope, the ! and the description" {
    const parts = try parse_subject(digits, "feat(h2)!: add the frame reader");
    try testing.expectEqualStrings("feat", parts.type_name);
    try testing.expectEqualStrings("h2", parts.scope.?);
    try testing.expectEqual(true, parts.breaking);
    try testing.expectEqualStrings("add the frame reader", parts.description);
    const plain = try parse_subject(digits, "docs: describe the page cache");
    try testing.expectEqual(null, plain.scope);
    try testing.expectEqual(false, plain.breaking);
    try testing.expectEqualStrings("describe the page cache", plain.description);
}

test "parse_subject names the first way a subject breaks the grammar" {
    try testing.expectError(error.MissingSeparator, parse_subject(digits, "add x"));
    try testing.expectError(error.UnknownType, parse_subject(digits, "feature: add x"));
    try testing.expectError(error.UnknownType, parse_subject(digits, "(store): add x"));
    try testing.expectError(error.UnclosedScope, parse_subject(digits, "feat(store: add x"));
    try testing.expectError(error.UnclosedScope, parse_subject(digits, "featstore): add x"));
    try testing.expectError(error.EmptyScope, parse_subject(digits, "feat(): add x"));
    try testing.expectError(error.ScopeNotLowercase, parse_subject(digits, "feat(Store): add x"));
    try testing.expectError(error.MissingSpaceAfterColon, parse_subject(digits, "feat:add x"));
}

test "scope_admits_digits decides whether a digit is part of a well-formed scope" {
    try testing.expect(is_well_formed_scope("h2", true));
    try testing.expect(!is_well_formed_scope("h2", false));
    try testing.expect(is_well_formed_scope("page-cache", false));
    try testing.expect(!is_well_formed_scope("page_cache", true));
    try testing.expect(!is_well_formed_scope("H2", true));
    const refused = parse_subject(letters_only, "feat(h2): add x");
    try testing.expectError(error.ScopeNotLowercase, refused);
}

test "joined separates the items with a comma and a space" {
    try testing.expectEqualStrings("", comptime joined(&.{}));
    try testing.expectEqualStrings("store", comptime joined(&.{"store"}));
    try testing.expectEqualStrings("store, net, h2", comptime joined(&.{ "store", "net", "h2" }));
}
