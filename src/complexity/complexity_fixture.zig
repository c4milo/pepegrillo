//! Fixtures the complexity test files share: the helper that scores one named declaration of a
//! source, and the source whose two functions score exactly 15 and exactly 16.

const std = @import("std");
const testing = std.testing;
const score_source = @import("complexity_scorer.zig").score_source;

/// Parses `source`, scores every declaration, and returns the score of the one named `name`.
pub fn score_of(source: [:0]const u8, name: []const u8) !u32 {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const scores = try score_source(arena_state.allocator(), "src/store/page.zig", source);
    for (scores) |scored| {
        if (std.mem.eql(u8, scored.name, name)) return scored.score;
    }
    return error.FunctionNotFound;
}

/// Two functions that differ by one `if`: `fifteen` scores exactly 15 and `sixteen` exactly 16.
pub const boundary_source =
    \\fn fifteen(a: bool, b: bool, items: []const u8, n: u8, value: ?u8) u8 {
    \\    if (a) {
    \\        if (b) {
    \\            if (a) return 1;
    \\        }
    \\    }
    \\    while (a) {}
    \\    for (items) |item| _ = item;
    \\    switch (n) {
    \\        0 => {},
    \\        else => {},
    \\    }
    \\    if (a and b or a) {}
    \\    if (a) {} else {}
    \\    return value orelse 0;
    \\}
    \\fn sixteen(a: bool, b: bool, items: []const u8, n: u8, value: ?u8) u8 {
    \\    if (a) {
    \\        if (b) {
    \\            if (a) return 1;
    \\        }
    \\    }
    \\    while (a) {}
    \\    for (items) |item| _ = item;
    \\    switch (n) {
    \\        0 => {},
    \\        else => {},
    \\    }
    \\    if (a and b or a) {}
    \\    if (a) {} else {}
    \\    if (b) {}
    \\    return value orelse 0;
    \\}
;
