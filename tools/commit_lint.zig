//! pepegrillo's commit-message rules: CLAUDE.md, Commits, as a configuration of the linter.
//!
//! Run: `zig build lint-commits`, or hooks/pre-push on every push once `zig build hooks` ran.

const std = @import("std");
const pepegrillo = @import("pepegrillo");

/// The scopes of CLAUDE.md, Commits: one per tool, plus the hook and the build.
const scopes = [_][]const u8{ "lint", "complexity", "commit", "tla", "lean", "hooks", "build" };

pub const config: pepegrillo.commit.Config = .{
    .scope_admits_digits = false,
    .known_scopes = &scopes,
    .unknown_scope_reason = "is not one of the scopes CLAUDE.md names",
    .third_person_forms = &.{
        "adds",    "fixes", "updates", "removes", "implements", "splits",
        "renames", "moves", "makes",   "drops",   "lands",      "keeps",
    },
    .imperative_exceptions = &.{
        "bring",   "embed",   "seed", "speed", "feed",   "exceed",
        "proceed", "succeed", "shed", "ring",  "string",
    },
};

pub fn main(init: std.process.Init) !void {
    return pepegrillo.commit.main(init, config);
}

// Tests. The rules carry their own; these pin this configuration.

const testing = std.testing;
const commit = pepegrillo.commit;

/// Lints `text` under this configuration and checks each finding as `severity: rule: message`.
fn expect_findings(text: []const u8, expected: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var results: commit.Findings = .{ .arena = arena, .max_findings = config.max_findings };
    try commit.lint_message_text(arena, config, &results, "message", text);
    try testing.expectEqual(expected.len, results.items.items.len);
    for (results.items.items, expected) |finding, wanted| {
        const line = try std.fmt.allocPrint(arena, "{s}: {s}: {s}", .{
            finding.severity.text(), finding.rule, finding.message,
        });
        try testing.expectEqualStrings(wanted, line);
    }
}

test "every scope CLAUDE.md names passes" {
    for (scopes) |scope| {
        var buffer: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "feat({s}): add the reader\n", .{scope});
        try expect_findings(text, &.{});
    }
}

test "a scope CLAUDE.md does not name draws a warning, and a digit is refused" {
    try expect_findings("feat(store): add the reader\n", &.{
        "warning: scope-known: the scope \"store\" is not one of the scopes CLAUDE.md names " ++
            "(lint, complexity, commit, tla, lean, hooks, build)",
    });
    try expect_findings("feat(h2): add the reader\n", &.{
        "violation: subject-format: the scope holds a byte that is not a lowercase letter or a " ++
            "hyphen: \"feat(h2): add the reader\"",
    });
}

test "a third-person first word is refused and a listed exception passes" {
    try expect_findings("fix(lint): moves the reader\n", &.{
        "violation: subject-description: \"moves\" is a third-person form, not imperative",
    });
    try expect_findings("fix(lint): string the fields together\n", &.{});
}
