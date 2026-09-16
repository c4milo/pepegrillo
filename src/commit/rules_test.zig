//! Tests of the eight rules of `rules.zig` under one configuration. `expect_findings` runs every
//! rule over one message and compares the `severity: rule: message` lines it recorded, in order, so
//! a fixture pins which rule fired as well as how many did. `rules_config_test.zig` tests each
//! configuration switch.
//!
//! `rule_cases` is the table the header of `rules.zig` is answerable to: one passing message and
//! one failing message per rule. A rule whose check is deleted stops firing on its own failing
//! message and fails its own case.
//!
//! The boundary fixtures write their column and word counts out as literals rather than deriving
//! them from the limits of `test_config`. A fixture derived from the limit moves when the limit
//! moves and reports nothing; a literal one fails, which is the point.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Config = @import("config.zig").Config;
const Findings = @import("findings.zig").Findings;
const Severity = @import("findings.zig").Severity;
const message_model = @import("message.zig");
const rules = @import("rules.zig");

const fixture_source = "abc1234";

/// The configuration every test of this file lints with. Every limit keeps its default.
pub const test_config: Config = .{
    .scope_admits_digits = true,
    .known_scopes = &.{ "store", "net", "h2" },
    .third_person_forms = &.{
        "adds",    "fixes", "updates", "removes", "implements", "splits",
        "renames", "moves", "makes",   "drops",   "lands",      "keeps",
    },
    .imperative_exceptions = &.{
        "bring",   "embed",   "seed", "speed", "feed",   "exceed",
        "proceed", "succeed", "shed", "ring",  "string",
    },
};

/// The known scopes as the `scope-known` finding prints them, written out rather than built from
/// `test_config`, so a scope added to or dropped from that list fails this file.
const known_scope_list = "store, net, h2";

/// Runs every rule over `text` under `config` and checks the findings it recorded, in order.
pub fn expect_findings_with(
    comptime config: Config,
    text: []const u8,
    expected: []const []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const message = try message_model.parse(
        arena,
        text,
        config.trailer_keys,
        config.max_message_lines,
    );
    var findings: Findings = .{ .arena = arena, .max_findings = config.max_findings };
    try rules.check_all(config, &findings, fixture_source, &message);
    try testing.expectEqual(expected.len, findings.count());
    for (findings.items.items, expected) |finding, want| {
        const line = try std.fmt.allocPrint(arena, "{s}: {s}: {s}", .{
            finding.severity.text(),
            finding.rule,
            finding.message,
        });
        try testing.expectEqualStrings(want, line);
        try testing.expectEqualStrings(fixture_source, finding.source);
    }
}

fn expect_findings(text: []const u8, expected: []const []const u8) !void {
    try expect_findings_with(test_config, text, expected);
}

// One passing message and one failing message per rule. Every failing message breaks exactly the
// rule it is filed under, so the case names which rule fired.

const RuleCase = struct {
    rule: []const u8,
    passing: []const u8,
    failing: []const u8,
    /// True when the failing message draws a warning rather than a violation.
    warns: bool = false,
};

const rule_cases = [_]RuleCase{
    .{
        .rule = rules.subject_format_rule,
        .passing = "feat(store): add the page cache\n",
        .failing = "feature(store): add the page cache\n",
    },
    .{
        .rule = rules.subject_description_rule,
        .passing = "feat(store): add the page cache\n",
        .failing = "feat(store): Add the page cache\n",
    },
    .{
        .rule = rules.subject_length_rule,
        .passing = "feat(store): add the page cache\n",
        .failing = "feat(store): add the page cache that turns bytes into one page and no more\n",
    },
    .{
        .rule = rules.scope_known_rule,
        .passing = "feat(net): add the frame reader\n",
        .failing = "feat(frobnicator): add the frame reader\n",
        .warns = true,
    },
    .{
        .rule = rules.body_separation_rule,
        .passing = "feat(h2): add the frame reader\n\nwhy it exists.\n",
        .failing = "feat(h2): add the frame reader\nwhy it exists.\n",
    },
    .{
        .rule = rules.body_line_length_rule,
        .passing = "feat(h2): add the frame reader\n\n" ++ ("w" ** 100) ++ "\n",
        .failing = "feat(h2): add the frame reader\n\n" ++ ("w" ** 101) ++ "\n",
    },
    .{
        .rule = rules.body_size_rule,
        .passing = "feat(h2): add x\n\nwhy one.\n\nwhy two.\n\nwhy three.\n",
        .failing = "feat(h2): add x\n\nwhy one.\n\nwhy two.\n\nwhy three.\n\nwhy four.\n",
    },
    .{
        .rule = rules.whitespace_rule,
        .passing = "feat(h2): add x\n\nwhy it exists.\n",
        .failing = "feat(h2): add x\n\nwhy it exists. \n",
    },
};

test "every rule passes its own passing message" {
    for (rule_cases) |case| {
        errdefer std.debug.print("the passing message of {s} was refused\n", .{case.rule});
        try expect_findings(case.passing, &.{});
    }
}

test "every rule fires on its own failing message, and only that rule fires" {
    for (rule_cases) |case| {
        errdefer std.debug.print("the failing message of {s} was accepted\n", .{case.rule});
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const keys = test_config.trailer_keys;
        const message = try message_model.parse(arena, case.failing, keys, 64);
        var findings: Findings = .{ .arena = arena, .max_findings = 16 };
        try rules.check_all(test_config, &findings, fixture_source, &message);
        try testing.expectEqual(1, findings.count());
        try testing.expectEqualStrings(case.rule, findings.items.items[0].rule);
        const severity: Severity = if (case.warns) .warning else .violation;
        try testing.expectEqual(severity, findings.items.items[0].severity);
        try testing.expectEqual(@as(usize, if (case.warns) 0 else 1), findings.count_violations());
    }
}

test "the table covers every rule check_all runs, in order" {
    const expected = [_][]const u8{
        rules.subject_format_rule,
        rules.subject_description_rule,
        rules.subject_length_rule,
        rules.scope_known_rule,
        rules.body_separation_rule,
        rules.body_line_length_rule,
        rules.body_size_rule,
        rules.whitespace_rule,
    };
    try testing.expectEqual(expected.len, rule_cases.len);
    for (expected, rule_cases) |want, case| {
        try testing.expectEqualStrings(want, case.rule);
    }
}

// Rule 1: the subject grammar.

test "rule 1 accepts a type, an optional scope, and an optional !" {
    try expect_findings("feat: add the page cache\n", &.{});
    try expect_findings("feat(store): add the page cache\n", &.{});
    try expect_findings("feat(store)!: add the page cache\n", &.{});
    try expect_findings("feat!: add the page cache\n", &.{});
    // A hyphen is part of a well-formed scope. Rule 4 warns about this one because the known
    // scopes do not name it, which rule 1 has no opinion about.
    try expect_findings("refactor(page-cache): add the page cache\n", &.{
        "warning: scope-known: the scope \"page-cache\" is not one of the known scopes (" ++
            known_scope_list ++ ")",
    });
}

test "rule 1 takes every type of the closed set and no other" {
    for (test_config.commit_types) |commit_type| {
        var buffer: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "{s}: add the page cache\n", .{commit_type});
        try expect_findings(text, &.{});
    }
    try expect_findings("feature: add the page cache\n", &.{
        "violation: subject-format: the type is not one of " ++
            "feat, fix, docs, test, refactor, perf, build, ci, chore: " ++
            "\"feature: add the page cache\"",
    });
}

test "rule 1 rejects a missing colon, a bad scope, and a missing space" {
    try expect_findings("add the page cache\n", &.{
        "violation: subject-format: no `type(scope)!: description` colon: \"add the page cache\"",
    });
    try expect_findings("feat(Store): add x\n", &.{
        "violation: subject-format: the scope holds a byte that is not a lowercase letter, " ++
            "a digit, or a hyphen: \"feat(Store): add x\"",
    });
    try expect_findings("feat(): add x\n", &.{
        "violation: subject-format: the scope is empty: \"feat(): add x\"",
    });
    try expect_findings("feat(store: add x\n", &.{
        "violation: subject-format: the scope is not closed with `)`: \"feat(store: add x\"",
    });
    try expect_findings("feat:add x\n", &.{
        "violation: subject-format: the colon is not followed by one space: \"feat:add x\"",
    });
}

// Rule 2: the description.

test "rule 2 wants a non-empty lowercase description with no period" {
    // The only subject with an empty description ends in the space the grammar wants after the
    // colon, so rule 8 fires beside rule 2.
    try expect_findings("feat: \n", &.{
        "violation: subject-description: the description is empty",
        "violation: whitespace: line 1 ends with whitespace",
    });
    try expect_findings("feat: Add the page cache\n", &.{
        "violation: subject-description: the description does not start with a lowercase " ++
            "letter: \"Add the page cache\"",
    });
    try expect_findings("feat: add the page cache.\n", &.{
        "violation: subject-description: the description ends with a period: " ++
            "\"add the page cache.\"",
    });
}

test "rule 2 rejects a past tense, a gerund, and every third-person form" {
    try expect_findings("feat: added the page cache\n", &.{
        "violation: subject-description: \"added\" is a past tense, not imperative",
    });
    try expect_findings("feat: adding the page cache\n", &.{
        "violation: subject-description: \"adding\" is a gerund, not imperative",
    });
    for (test_config.third_person_forms) |form| {
        var buffer: [128]u8 = undefined;
        var want_buffer: [160]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "feat: {s} the page cache\n", .{form});
        const format = "violation: subject-description: \"{s}\" is a third-person form, " ++
            "not imperative";
        const want = try std.fmt.bufPrint(&want_buffer, format, .{form});
        try expect_findings(text, &.{want});
    }
}

test "rule 2 takes every command whose spelling ends in ed or ing" {
    for (test_config.imperative_exceptions) |exception| {
        var buffer: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "feat: {s} the corpus\n", .{exception});
        try expect_findings(text, &.{});
    }
}

test "rules 2 and 4 say nothing when rule 1 could not parse the subject" {
    try expect_findings("Added the page cache\n", &.{
        "violation: subject-format: no `type(scope)!: description` colon: " ++
            "\"Added the page cache\"",
    });
    try expect_findings("feat(Frob): Added x.\n", &.{
        "violation: subject-format: the scope holds a byte that is not a lowercase letter, " ++
            "a digit, or a hyphen: \"feat(Frob): Added x.\"",
    });
}

// Rule 3: the subject length. 72 and 73 columns, written out.

test "rule 3 takes a 72-column subject and refuses a 73-column one" {
    try expect_findings("feat: " ++ ("w" ** 66) ++ "\n", &.{});
    try expect_findings("feat: " ++ ("w" ** 67) ++ "\n", &.{
        "violation: subject-length: the subject is 73 columns, over the 72-column limit",
    });
}

// Rule 4: the scope against the known scopes.

test "rule 4 takes every known scope" {
    for (test_config.known_scopes.?) |scope| {
        var buffer: [96]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "feat({s}): add the page cache\n", .{scope});
        try expect_findings(text, &.{});
    }
}

test "rule 4 warns on a well-formed scope the known scopes do not name" {
    try expect_findings("feat(frobnicator): add x\n", &.{
        "warning: scope-known: the scope \"frobnicator\" is not one of the known scopes (" ++
            known_scope_list ++ ")",
    });
}

// Rule 5: the blank line under the subject.

test "rule 5 wants exactly one blank line, not none and not two" {
    try expect_findings("feat: add x\n\nwhy it exists.\n", &.{});
    try expect_findings("feat: add x\nwhy it exists.\n", &.{
        "violation: body-separation: no blank line between the subject and the body",
    });
    try expect_findings("feat: add x\n\n\nwhy it exists.\n", &.{
        "violation: body-separation: 2 blank lines between the subject and the body, " ++
            "want exactly one",
    });
    try expect_findings("feat: add x\n", &.{});
}

// Rules 6 and 7: the body limits, and the trailer block they leave out.

test "rule 6 takes a 100-column body line and refuses a 101-column one" {
    try expect_findings("feat: add x\n\n" ++ ("w" ** 100) ++ "\n", &.{});
    try expect_findings("feat: add x\n\n" ++ ("w" ** 101) ++ "\n", &.{
        "violation: body-line-length: line 3 is 101 columns, over the 100-column limit",
    });
}

/// Words the word-count fixture puts on one body line, so that no line of it trips rule 6 or 8.
const words_per_line: usize = 10;

/// A message whose body holds `count` words.
fn body_of_words(arena: Allocator, count: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "feat: add x\n\n");
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const line_start = index % words_per_line == 0;
        const separator: []const u8 = if (index == 0) "" else if (line_start) "\n" else " ";
        try out.appendSlice(arena, separator);
        try out.appendSlice(arena, "why");
    }
    try out.append(arena, '\n');
    return out.items;
}

test "rule 7 takes a 100-word body and refuses a 101-word one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expect_findings(try body_of_words(arena, 100), &.{});
    try expect_findings(try body_of_words(arena, 101), &.{
        "violation: body-size: the body has 101 words, over the limit of 100",
    });
}

test "rule 7 takes three paragraphs and refuses four" {
    try expect_findings("feat: add x\n\none\n\ntwo\n\nthree\n", &.{});
    try expect_findings("feat: add x\n\none\n\ntwo\n\nthree\n\nfour\n", &.{
        "violation: body-size: the body has 4 paragraphs, over the limit of 3",
    });
}

test "the trailer block counts against neither body limit" {
    // A trailer line over the column limit and a fourth Key: value paragraph, both silent.
    try expect_findings("feat: add x\n\nwhy one.\n\nwhy two.\n\nwhy three.\n\n" ++
        "Co-Authored-By: " ++ ("w" ** 101) ++ "\nRefs: https://example.com/issues/1\n", &.{});
    // The same shape with a key outside the closed set is body, and is counted.
    const note = "feat: add x\n\nwhy one.\n\nwhy two.\n\nwhy three.\n\n" ++
        "Note: " ++ ("w" ** 101) ++ "\n";
    try expect_findings(note, &.{
        "violation: body-line-length: line 9 is 107 columns, over the 100-column limit",
        "violation: body-size: the body has 4 paragraphs, over the limit of 3",
    });
}

test "rule 7 counts the words of a final Note: paragraph" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const at_limit = try body_of_words(arena, 100);
    const text = try std.fmt.allocPrint(arena, "{s}\nNote: why\n", .{at_limit});
    try expect_findings(text, &.{
        "violation: body-size: the body has 102 words, over the limit of 100",
    });
}

// Rule 8: the whitespace.

test "rule 8 refuses a trailing space and a second trailing blank line" {
    try expect_findings("feat: add x\n\nwhy it exists. \n", &.{
        "violation: whitespace: line 3 ends with whitespace",
    });
    try expect_findings("feat: add x\t\n", &.{
        "violation: whitespace: line 1 ends with whitespace",
    });
    try expect_findings("feat: add x\n\nwhy\n\n", &.{});
    try expect_findings("feat: add x\n\n\n", &.{
        "violation: whitespace: the message ends with 2 blank lines, over the limit of 1",
    });
}

test "rule 8 reads a carriage return as whitespace" {
    try expect_findings("feat: add x\r\n\r\nwhy\r\n", &.{
        "violation: whitespace: line 1 ends with whitespace",
        "violation: whitespace: line 2 ends with whitespace",
        "violation: whitespace: line 3 ends with whitespace",
    });
}

test "rule 8 reports every line that ends in whitespace, trailers included" {
    try expect_findings("feat: add x \n\nwhy\t\n", &.{
        "violation: whitespace: line 1 ends with whitespace",
        "violation: whitespace: line 3 ends with whitespace",
    });
    try expect_findings("feat: add x\n\nwhy\n\nCo-Authored-By: A <a@example.com> \n", &.{
        "violation: whitespace: line 5 ends with whitespace",
    });
}

// The whole message.

test "a conforming message with trailers reports nothing" {
    try expect_findings(
        \\refactor(store): split every file over 500 lines, and gate on it
        \\
        \\Eight files were over the limit; none is now. Each piece is named
        \\after the file it came from, so a listing groups them under their
        \\origin, and the rule is wired into the build.
        \\
        \\Co-Authored-By: A <a@example.com>
        \\
    , &.{});
}

test "one message can break several rules at once" {
    try expect_findings("Feat: Adds x.\nbody\n", &.{
        "violation: subject-format: the type is not one of " ++
            "feat, fix, docs, test, refactor, perf, build, ci, chore: \"Feat: Adds x.\"",
        "violation: body-separation: no blank line between the subject and the body",
    });
}

test "an empty message reports the subject rules and nothing else" {
    try expect_findings("", &.{
        "violation: subject-format: no `type(scope)!: description` colon: \"\"",
    });
}
