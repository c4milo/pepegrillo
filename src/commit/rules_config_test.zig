//! Tests of each `Config` switch the rules read. Every test lints one message under two
//! configurations that differ in one field and checks that the verdict moves with the field.
//! `rules_test.zig` holds the tests of the rules under one configuration.

const std = @import("std");
const testing = std.testing;
const Config = @import("config.zig").Config;
const Findings = @import("findings.zig").Findings;
const message_model = @import("message.zig");
const rules = @import("rules.zig");
const rules_test = @import("rules_test.zig");

const expect_findings_with = rules_test.expect_findings_with;

/// Scopes of lowercase letters only, no scope list, and the shorter word lists.
const letters: Config = .{
    .scope_admits_digits = false,
    .third_person_forms = &.{
        "adds", "fixes", "updates", "removes", "implements", "splits", "renames",
    },
    .imperative_exceptions = &.{
        "bring", "embed", "seed", "speed", "feed", "exceed", "proceed", "succeed", "shed", "ring",
    },
};

/// Scopes that admit digits, a scope list, and the longer word lists: `rules_test.test_config`.
const digits = rules_test.test_config;

/// `digits` with the scope list switched off.
const digits_any_scope: Config = blk: {
    var config = digits;
    config.known_scopes = null;
    break :blk config;
};

// The subject grammar.

test "scope_admits_digits decides whether a digit scope is refused" {
    const text = "feat(h2): add the frame reader\n";
    try expect_findings_with(letters, text, &.{
        "violation: subject-format: the scope holds a byte that is not a lowercase letter or a " ++
            "hyphen: \"feat(h2): add the frame reader\"",
    });
    try expect_findings_with(digits_any_scope, text, &.{});
}

test "commit_types is the closed set the type is read against, and the set the message prints" {
    const config: Config = comptime blk: {
        var config = letters;
        config.commit_types = &.{ "feat", "wip" };
        break :blk config;
    };
    try expect_findings_with(config, "wip: add the page cache\n", &.{});
    try expect_findings_with(config, "fix: add the page cache\n", &.{
        "violation: subject-format: the type is not one of feat, wip: \"fix: add the page cache\"",
    });
    try expect_findings_with(letters, "wip: add the page cache\n", &.{
        "violation: subject-format: the type is not one of " ++
            "feat, fix, docs, test, refactor, perf, build, ci, chore: \"wip: add the page cache\"",
    });
}

// The known scopes.

test "known_scopes null accepts every well-formed scope" {
    try expect_findings_with(letters, "feat(frobnicator): add the page cache\n", &.{});
    try expect_findings_with(digits_any_scope, "feat(frobnicator): add the page cache\n", &.{});
}

test "unknown_scope_reason is printed between the scope and the known scopes" {
    const config: Config = comptime blk: {
        var config = digits;
        config.unknown_scope_reason = "is not a module of the graph";
        break :blk config;
    };
    try expect_findings_with(config, "feat(obj): add the page cache\n", &.{
        "warning: scope-known: the scope \"obj\" is not a module of the graph (store, net, h2)",
    });
}

test "unknown_scope_severity decides whether an unknown scope refuses the commit" {
    const config: Config = comptime blk: {
        var config = digits;
        config.unknown_scope_severity = .violation;
        break :blk config;
    };
    try expect_findings_with(config, "feat(obj): add the page cache\n", &.{
        "violation: scope-known: the scope \"obj\" is not one of the known scopes (store, net, h2)",
    });
    try expect_findings_with(digits, "feat(obj): add the page cache\n", &.{
        "warning: scope-known: the scope \"obj\" is not one of the known scopes (store, net, h2)",
    });
}

// The description.

test "third_person_forms is the list a first word is refused from" {
    const text = "fix: moves the reader\n";
    try expect_findings_with(letters, text, &.{});
    try expect_findings_with(digits, text, &.{
        "violation: subject-description: \"moves\" is a third-person form, not imperative",
    });
}

test "imperative_exceptions is read before the suffix test" {
    const text = "feat: string the fields together\n";
    try expect_findings_with(letters, text, &.{
        "violation: subject-description: \"string\" is a gerund, not imperative",
    });
    try expect_findings_with(digits, text, &.{});
}

// The trailer keys.

test "trailer_keys decides which final paragraph the body rules leave out" {
    const config: Config = comptime blk: {
        var config = letters;
        config.trailer_keys = &.{"Change-Id"};
        break :blk config;
    };
    const text = "feat: add x\n\none\n\ntwo\n\nthree\n\nChange-Id: I0123\n";
    try expect_findings_with(config, text, &.{});
    try expect_findings_with(letters, text, &.{
        "violation: body-size: the body has 4 paragraphs, over the limit of 3",
    });
}

// The limits. Each one is lowered and the message that passed at the default is refused.

fn with_limits(comptime base: Config, comptime limits: anytype) Config {
    var config = base;
    inline for (std.meta.fields(@TypeOf(limits))) |field| {
        @field(config, field.name) = @field(limits, field.name);
    }
    return config;
}

test "max_subject_columns is the subject limit" {
    const config = comptime with_limits(letters, .{ .max_subject_columns = 20 });
    try expect_findings_with(config, "feat: " ++ ("w" ** 14) ++ "\n", &.{});
    try expect_findings_with(config, "feat: " ++ ("w" ** 15) ++ "\n", &.{
        "violation: subject-length: the subject is 21 columns, over the 20-column limit",
    });
}

test "max_body_columns is the body line limit" {
    const config = comptime with_limits(letters, .{ .max_body_columns = 10 });
    try expect_findings_with(config, "feat: add x\n\n" ++ ("w" ** 10) ++ "\n", &.{});
    try expect_findings_with(config, "feat: add x\n\n" ++ ("w" ** 11) ++ "\n", &.{
        "violation: body-line-length: line 3 is 11 columns, over the 10-column limit",
    });
}

test "max_body_paragraphs and max_body_words are the body size limits" {
    const limits = .{ .max_body_paragraphs = 1, .max_body_words = 3 };
    const config = comptime with_limits(letters, limits);
    try expect_findings_with(config, "feat: add x\n\none two three\n", &.{});
    try expect_findings_with(config, "feat: add x\n\none two\n\nthree four\n", &.{
        "violation: body-size: the body has 2 paragraphs, over the limit of 1",
        "violation: body-size: the body has 4 words, over the limit of 3",
    });
}

test "max_trailing_blank_lines is the trailing blank line limit" {
    const config = comptime with_limits(letters, .{ .max_trailing_blank_lines = 0 });
    try expect_findings_with(config, "feat: add x\n", &.{});
    try expect_findings_with(config, "feat: add x\n\n", &.{
        "violation: whitespace: the message ends with 1 blank lines, over the limit of 0",
    });
}

test "max_findings is the finding cap of one run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "feat: Add x.\n";
    const message = try message_model.parse(arena, text, letters.trailer_keys, 8);
    var one: Findings = .{ .arena = arena, .max_findings = 1 };
    try testing.expectError(error.TooManyFindings, rules.check_all(letters, &one, "a", &message));
    var two: Findings = .{ .arena = arena, .max_findings = 2 };
    try rules.check_all(letters, &two, "a", &message);
    try testing.expectEqual(2, two.count());
}
