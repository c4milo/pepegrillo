//! Tests for the denied-words rule: one fixture per shape the rule's header names, and one per
//! configuration setting.

const std = @import("std");
const testing = std.testing;
const harness = @import("../harness.zig");
const report = @import("../report.zig");
const denied_words = @import("denied_words.zig");
const Config = denied_words.Config;

/// Denies four vendor names and one domain suffix across every text file but its own list.
const vendors: Config = .{
    .name = "vendor-names",
    .scope = .{
        .extensions = &.{ ".zig", ".md", ".html", ".sh", ".cfg", ".tla", ".txt", ".zon" },
        .basenames = &.{"NOTICE"},
        .exclude_paths = &.{"tools/lint/vendors.zig"},
    },
    .words = &.{ "acmecorp", "globex", "lumo", "abc" },
    .domain_suffixes = &.{".ac"},
    .word_label = "vendor name",
    .domain_label = "vendor domain",
};

/// The default name and labels, with two domain suffixes.
const defaults: Config = .{
    .scope = .{ .extensions = &.{".md"} },
    .words = &.{"globex"},
    .domain_suffixes = &.{ ".ac", ".internal" },
};

fn findings_of(
    arena: std.mem.Allocator,
    comptime config: Config,
    path: []const u8,
    source: [:0]const u8,
) ![]const report.Finding {
    return harness.run(arena, denied_words.Rule(config), path, source);
}

fn expect_findings(
    comptime config: Config,
    path: []const u8,
    source: [:0]const u8,
    expected: []const []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), config, path, source);
    try harness.expect_messages(findings, expected);
}

test "denied-words flags each word in any case, as written" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), vendors, "docs/a.md",
        \\Runs on AcmeCorp today.
        \\GLOBEX is the object store; lumo and ABC are its parts.
    );
    try harness.expect_messages(findings, &.{
        "vendor name \"AcmeCorp\"",
        "vendor name \"GLOBEX\"",
        "vendor name \"lumo\"",
        "vendor name \"ABC\"",
    });
    try testing.expectEqual(1, findings[0].line);
    try testing.expectEqual(9, findings[0].column);
    try testing.expectEqual(2, findings[1].line);
    try testing.expectEqual(1, findings[1].column);
    try testing.expectEqualStrings("vendor-names", findings[0].rule);
}

test "denied-words flags every occurrence of a word on one line" {
    try expect_findings(vendors, "docs/a.md", "abc, abc and abc.", &.{
        "vendor name \"abc\"",
        "vendor name \"abc\"",
        "vendor name \"abc\"",
    });
}

test "denied-words does not flag a word inside a longer word" {
    try expect_findings(vendors, "docs/a.md",
        \\The abcs pass; the pilumo flies; foo_abc and abc_bar stay; lumos and 2abc too.
    , &.{});
}

test "denied-words flags the domain suffix after a hostname" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), vendors, "src/a.zig",
        \\const endpoint = "https://api.AC/v1";
        \\const host = "object-store.eu.ac";
        \\const port = "host.ac:443";
    );
    try harness.expect_messages(findings, &.{
        "vendor domain \"api.AC\"",
        "vendor domain \"object-store.eu.ac\"",
        "vendor domain \"host.ac\"",
    });
    try testing.expectEqual(27, findings[0].column);
}

test "denied-words flags the domain suffix before the period of a sentence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), vendors, "docs/a.md",
        \\See api.ac.
        \\See api.ac. Then more.
    );
    try harness.expect_messages(findings, &.{
        "vendor domain \"api.ac\"",
        "vendor domain \"api.ac\"",
    });
    try testing.expectEqual(1, findings[0].line);
    try testing.expectEqual(5, findings[0].column);
    try testing.expectEqual(2, findings[1].line);
    try testing.expectEqual(5, findings[1].column);
}

test "denied-words does not flag the suffix inside a longer label or a subdomain" {
    try expect_findings(vendors, "src/a.zig",
        \\const total = self.account();
        \\const host = "x.ac.example.com";
        \\const stray = ".ac";
        \\const label = "a.ac-b";
    , &.{});
}

test "denied-words reports a word and a domain in order on one line" {
    try expect_findings(vendors, "docs/a.md", "globex.ac and lumo", &.{
        "vendor name \"globex\"",
        "vendor domain \"globex.ac\"",
        "vendor name \"lumo\"",
    });
}

test "denied-words uses its default name and labels and reads every suffix" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try findings_of(arena_state.allocator(), defaults, "docs/a.md",
        \\Globex runs api.ac and build.internal.
    );
    try harness.expect_messages(findings, &.{
        "denied word \"Globex\"",
        "denied domain \"api.ac\"",
        "denied domain \"build.internal\"",
    });
    try testing.expectEqualStrings("denied-words", findings[0].rule);
}

test "denied-words reads the files its scope names and no others" {
    const source = "// acmecorp";
    const finding = "vendor name \"acmecorp\"";
    const read = [_][]const u8{
        "a.zig",  "a.md",          "a.html", "a.sh", "a.cfg", "a.tla", "a.txt", "a.zon",
        "NOTICE", "./docs/NOTICE",
    };
    for (read) |path| try expect_findings(vendors, path, source, &.{finding});
    try expect_findings(vendors, "src/corpus/a.bin", source, &.{});
    try expect_findings(vendors, "src/corpus/a.frame", source, &.{});
    try expect_findings(vendors, "./tools/lint/vendors.zig", source, &.{});
}
