//! slow-std: a file names no standard-library declaration that a measurement found slow, where a
//! faster replacement exists. Each entry names the declaration, its replacement and the evidence,
//! and the finding cites all three:
//!
//!     reference to std.mem.copyForwards: a loop that copies one byte at a time in Zig 0.16; use @memmove
//!
//! The rule runs `forbidden_references` once for each entry, with the entry's name as its prefix
//! and `resolve_file_aliases` set. So it also reports `mem.copyForwards` after
//! `const mem = std.mem;`, as `reference to std.mem.copyForwards through mem`. It sees what that
//! rule sees, and misses what that rule misses: a chain that starts with `@import("std")` written
//! in place, and a name that another file exports.
//!
//! An entry joins `entries_default` only with a measurement, as `docs/performance/` asks. A name
//! that is slow on one hot path, or that Zig deprecates only as a rename, is not an entry. An entry
//! added to `entries_default` changes the verdicts of each project that takes the default, so it
//! is a breaking change.

const std = @import("std");
const report = @import("../report.zig");
const Scope = @import("../scope.zig").Scope;
const forbidden_references = @import("forbidden_references.zig");

/// A declaration the rule reports, and why.
pub const Entry = struct {
    /// The chain the rule reports, as a file writes it from `std`: `std.mem.copyForwards`.
    name: []const u8,
    /// What a file writes in its place: `@memmove`.
    replacement: []const u8,
    /// What the measurement found, which the finding cites.
    evidence: []const u8,
};

/// The entries of Zig 0.16, each measured. `docs/performance/performance_zig.md`, "Copies and
/// fills", gives the numbers.
pub const entries_default: []const Entry = &.{
    .{
        .name = "std.mem.copyForwards",
        .replacement = "@memmove",
        .evidence = "a loop that copies one byte at a time in Zig 0.16",
    },
    .{
        .name = "std.mem.copyBackwards",
        .replacement = "@memmove",
        .evidence = "a loop that copies one byte at a time in Zig 0.16",
    },
};

pub const Config = struct {
    /// The rule name findings are reported under and `--rule` selects.
    name: []const u8 = "slow-std",
    /// The files the rule reads.
    scope: Scope,
    /// The declarations the rule reports.
    entries: []const Entry = entries_default,
};

/// The rule for one configuration: a type with the `name` and `check` the driver dispatches to.
pub fn Rule(comptime config: Config) type {
    comptime std.debug.assert(config.name.len != 0);
    comptime std.debug.assert(config.entries.len != 0);
    const walks = comptime walks_of(config);
    return struct {
        pub const name = config.name;

        pub fn check(context: *report.Context, file: *const report.File) !void {
            inline for (walks) |walk| try walk.check(context, file);
        }
    };
}

/// One `forbidden_references` rule for each entry, under the name of this rule.
fn walks_of(comptime config: Config) [config.entries.len]type {
    var walks: [config.entries.len]type = undefined;
    for (config.entries, &walks) |entry, *walk| {
        std.debug.assert(entry.name.len != 0 and entry.replacement.len != 0);
        walk.* = forbidden_references.Rule(.{
            .name = config.name,
            .scope = config.scope,
            .prefixes = &.{entry.name},
            .resolve_file_aliases = true,
            .reason = entry.evidence ++ "; use " ++ entry.replacement,
        });
    }
    return walks;
}

// Tests.

const testing = std.testing;
const harness = @import("../harness.zig");
const names = @import("../names.zig");

const sources: Config = .{
    .scope = .{ .extensions = &.{".zig"}, .exclude_directories = &.{"tools"} },
};

const byte_loop = ": a loop that copies one byte at a time in Zig 0.16; use @memmove";

test "the rule reports each default entry, with its evidence and its replacement" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule(sources), "src/store/page.zig",
        \\const std = @import("std");
        \\pub fn shift(page: []u8, start: usize) void {
        \\    std.mem.copyForwards(u8, page, page[start..]);
        \\    std.mem.copyBackwards(u8, page[start..], page);
        \\}
    );
    try harness.expect_messages(findings, &.{
        "reference to std.mem.copyForwards" ++ byte_loop,
        "reference to std.mem.copyBackwards" ++ byte_loop,
    });
    try testing.expectEqualStrings("slow-std", findings[0].rule);
    try testing.expectEqual(3, findings[0].line);
    try testing.expectEqual(5, findings[0].column);
    try testing.expectEqual(4, findings[1].line);
}

test "the rule reports a name read through an alias of its namespace" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule(sources), "src/store/page.zig",
        \\const std = @import("std");
        \\const mem = std.mem;
        \\pub fn shift(page: []u8, start: usize) void {
        \\    mem.copyForwards(u8, page, page[start..]);
        \\}
    );
    try harness.expect_messages(findings, &.{
        "reference to std.mem.copyForwards through mem" ++ byte_loop,
    });
}

test "the rule passes the replacement, a longer name, and a file outside its scope" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\const std = @import("std");
        \\pub fn shift(page: []u8, start: usize) void {
        \\    @memmove(page[0 .. page.len - start], page[start..]);
        \\    std.mem.copyForwardsChecked(u8, page, page[start..]);
        \\    @memcpy(page[0..1], std.mem.asBytes(&start)[0..1]);
        \\}
    ;
    try harness.expect_messages(try harness.run(arena, Rule(sources), "src/store/page.zig", source), &.{});
    const outside = "const std = @import(\"std\");\nconst copy = std.mem.copyForwards;\n";
    try harness.expect_messages(try harness.run(arena, Rule(sources), "tools/lint.zig", outside), &.{});
}

test "a project's entries replace the default entries, and its name replaces the rule's" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const own: Config = .{
        .name = "hot-path",
        .scope = sources.scope,
        .entries = &.{.{
            .name = "std.fmt.bufPrint",
            .replacement = "the encoder in src/wire",
            .evidence = "18% of the frame path",
        }},
    };
    const findings = try harness.run(arena_state.allocator(), Rule(own), "src/wire/frame.zig",
        \\const std = @import("std");
        \\pub fn write(buffer: []u8, page: []u8) !void {
        \\    std.mem.copyForwards(u8, page, buffer);
        \\    _ = try std.fmt.bufPrint(buffer, "{d}", .{page.len});
        \\}
    );
    try harness.expect_messages(findings, &.{
        "reference to std.fmt.bufPrint: 18% of the frame path; use the encoder in src/wire",
    });
    try testing.expectEqualStrings("hot-path", findings[0].rule);
}

test "each default entry names a declaration of Zig's standard library" {
    comptime var chains: [entries_default.len][]const u8 = undefined;
    inline for (entries_default, &chains) |entry, *chain| chain.* = entry.name;
    comptime names.assert_all_resolve(std, "std", &chains);
}
