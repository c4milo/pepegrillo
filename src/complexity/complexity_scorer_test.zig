//! Tests of the scorer's increment rules. Each test pins one rule of the mapping at the top of
//! `complexity.zig`. Where a plausible misreading of a rule gives a different score, a comment
//! names both, so a reader can see which reading the fixture tells apart.

const std = @import("std");
const testing = std.testing;
const fixture = @import("complexity_fixture.zig");
const score_of = fixture.score_of;

test "straight-line code scores 0 and a single if scores 1" {
    try testing.expectEqual(0, try score_of(
        \\fn straight(a: u32, b: u32) u32 {
        \\    const sum = a + b;
        \\    const product = sum * 2;
        \\    return product - 1;
        \\}
    , "straight"));
    try testing.expectEqual(1, try score_of(
        \\fn single(a: bool) void {
        \\    if (a) return;
        \\}
    , "single"));
}

test "nesting adds the level to each structural increment" {
    // if 1, the for inside it 1+1, the if inside that 1+2: 6.
    try testing.expectEqual(6, try score_of(
        \\fn nested(a: bool, items: []const u8) void {
        \\    if (a) {
        \\        for (items) |item| {
        \\            if (item == 0) return;
        \\        }
        \\    }
        \\}
    , "nested"));
    // for 1, the if inside it 1+1, the if inside that 1+2: 6.
    try testing.expectEqual(6, try score_of(
        \\fn scan(items: []const u8, flag: bool) void {
        \\    for (items) |item| {
        \\        if (item == 0) {
        \\            if (flag) unreachable;
        \\        }
        \\    }
        \\}
    , "scan"));
}

test "an if condition, a loop condition and loop inputs sit at the construct's own level" {
    // if 1; while 1+1 and the if in its condition 1+1 with its else 1; for 1+1 and the if in its
    // input 1+1 with its else 1: 11. Either operand one level deeper would make it 12.
    try testing.expectEqual(11, try score_of(
        \\fn guarded(a: bool, b: bool, items: []const u8, other: []const u8) void {
        \\    if (a) {
        \\        while (if (b) a else b) {}
        \\        for (if (b) items else other) |item| _ = item;
        \\    }
        \\}
    , "guarded"));
    // for 1; if 1+1 and the if in its condition 1+1 with its else 1: 6. The condition one level
    // deeper would make it 7.
    try testing.expectEqual(6, try score_of(
        \\fn filtered(a: bool, b: bool, items: []const u8) void {
        \\    for (items) |item| {
        \\        if (if (a) item == 0 else b) {}
        \\    }
        \\}
    , "filtered"));
}

test "a while continue expression sits one level deeper" {
    // while 1, the if in the continue expression 1+1, its else 1: 4.
    try testing.expectEqual(4, try score_of(
        \\fn counted(a: bool) void {
        \\    var index: u32 = 0;
        \\    while (index < 10) : (index += if (a) 1 else 2) {}
        \\}
    , "counted"));
}

test "else adds 1 and else if adds 1 per branch" {
    // if 1, else if 1, else if 1, else 1: 4.
    try testing.expectEqual(4, try score_of(
        \\fn chain(a: bool, b: bool, c: bool) u8 {
        \\    if (a) {
        \\        return 1;
        \\    } else if (b) {
        \\        return 2;
        \\    } else if (c) {
        \\        return 3;
        \\    } else {
        \\        return 4;
        \\    }
        \\}
    , "chain"));
    // if 1, else if 1, else 1: 3.
    try testing.expectEqual(3, try score_of(
        \\fn pick(n: u32) u32 {
        \\    if (n == 0) return 1 else if (n == 1) return 2 else return 3;
        \\}
    , "pick"));
    // An `if` expression's else adds 1 the same way: 2.
    try testing.expectEqual(2, try score_of(
        \\fn choose(a: bool) u8 {
        \\    return if (a) 1 else 2;
        \\}
    , "choose"));
}

test "else if adds 1 in total at any nesting level" {
    // for 1, if 1+1, else if 1, else 1: 5. Scoring the else if as a fresh if, 1+1, makes it 6.
    try testing.expectEqual(5, try score_of(
        \\fn pick(items: []const u8, n: u32) u32 {
        \\    for (items) |_| {
        \\        if (n == 0) {
        \\            return 1;
        \\        } else if (n == 1) {
        \\            return 2;
        \\        } else {
        \\            return 3;
        \\        }
        \\    }
        \\    return 0;
        \\}
    , "pick"));
}

test "else if and else bodies sit one level deeper than the first if" {
    // if 1, else if 1, the if in its body 1+1: 4.
    try testing.expectEqual(4, try score_of(
        \\fn chain(a: bool, b: bool, c: bool) void {
        \\    if (a) {
        \\        return;
        \\    } else if (b) {
        \\        if (c) return;
        \\    }
        \\}
    , "chain"));
    // if 1, else 1, the if in its body 1+1: 4. An else body at the if's own level makes it 3.
    try testing.expectEqual(4, try score_of(
        \\fn fallback(a: bool, b: bool) void {
        \\    if (a) {
        \\        return;
        \\    } else {
        \\        if (b) return;
        \\    }
        \\}
    , "fallback"));
}

test "else on a for or a while adds 1, and inline loops are structural" {
    // for 1, its else 1, while 1, its else 1: 4.
    try testing.expectEqual(4, try score_of(
        \\fn loops(items: []const u8, a: bool) void {
        \\    for (items) |item| {
        \\        _ = item;
        \\    } else {
        \\        return;
        \\    }
        \\    while (a) {} else {}
        \\}
    , "loops"));
    try testing.expectEqual(2, try score_of(
        \\fn unrolled(comptime items: []const u8) void {
        \\    inline for (items) |item| _ = item;
        \\    inline while (false) {}
        \\}
    , "unrolled"));
}

test "a switch scores 1 regardless of prong count" {
    try testing.expectEqual(1, try score_of(
        \\fn many(n: u8) u8 {
        \\    return switch (n) {
        \\        0 => 10,
        \\        1, 2 => 20,
        \\        3...9 => 30,
        \\        10 => 40,
        \\        11 => 50,
        \\        12 => 60,
        \\        else => 70,
        \\    };
        \\}
    , "many"));
}

test "switch prong values and bodies sit one level deeper and prongs add no level" {
    // switch 1, the if inside a prong 1+1: 3.
    try testing.expectEqual(3, try score_of(
        \\fn prong(n: u8, a: bool) void {
        \\    switch (n) {
        \\        0 => if (a) return,
        \\        else => {},
        \\    }
        \\}
    , "prong"));
    // switch 1, the if in a prong value 1+1, its else 1: 4.
    try testing.expectEqual(4, try score_of(
        \\fn prong_value(n: u8, a: bool) u8 {
        \\    return switch (n) {
        \\        if (a) 0 else 1 => 10,
        \\        else => 20,
        \\    };
        \\}
    , "prong_value"));
}

test "a switch adds its nesting level and its condition sits at its own level" {
    // for 1, the switch inside it 1+1: 3.
    try testing.expectEqual(3, try score_of(
        \\fn nested_switch(items: []const u8) void {
        \\    for (items) |item| {
        \\        switch (item) {
        \\            0 => {},
        \\            else => {},
        \\        }
        \\    }
        \\}
    , "nested_switch"));
    // switch 1, the if in its condition 1, its else 1: 3.
    try testing.expectEqual(3, try score_of(
        \\fn switch_condition(a: bool, n: u8, m: u8) void {
        \\    switch (if (a) n else m) {
        \\        else => {},
        \\    }
        \\}
    , "switch_condition"));
}

/// Scores `expression` as the whole body of a function taking four booleans.
fn score_boolean(comptime expression: []const u8) !u32 {
    return score_of(
        "fn all(a: bool, b: bool, c: bool, d: bool) bool { return " ++ expression ++ "; }",
        "all",
    );
}

test "a run of like boolean operators adds 1 and each change of operator adds 1" {
    try testing.expectEqual(1, try score_boolean("a and b and c"));
    try testing.expectEqual(2, try score_boolean("a and b or c"));
    try testing.expectEqual(3, try score_boolean("a and b or c and d"));
}

test "parentheses and ! start a new sequence, and precedence decides the run" {
    try testing.expectEqual(2, try score_boolean("a and (b and c)"));
    try testing.expectEqual(2, try score_boolean("a and !(b and c)"));
    // `and` binds tighter than `or`, so this is `(a or (b and c)) or d`: one `or` run holding one
    // `and` run, 2. Read token by token the operator changes twice and it would be 3.
    try testing.expectEqual(2, try score_boolean("a or b and c or d"));
}

test "orelse with a non-block operand adds 1 at any nesting level" {
    try testing.expectEqual(1, try score_of(
        \\fn unwrap(value: ?u8) u8 {
        \\    return value orelse return 0;
        \\}
    , "unwrap"));
    // `orelse return` 1, `catch` 1: 2.
    try testing.expectEqual(2, try score_of(
        \\fn read(value: ?u32, fallible: anytype) !u32 {
        \\    const unwrapped = value orelse return error.Missing;
        \\    const caught = fallible.call() catch 0;
        \\    return unwrapped + caught;
        \\}
    , "read"));
    // for 1, `orelse continue` 1: 2. Adding the nesting level to the orelse makes it 3.
    try testing.expectEqual(2, try score_of(
        \\fn first(items: []const ?u8) u8 {
        \\    for (items) |item| {
        \\        const value = item orelse continue;
        \\        return value;
        \\    }
        \\    return 0;
        \\}
    , "first"));
}

test "orelse with a block operand adds 1 plus nesting and nests the block" {
    // orelse 1, the if inside the block 1+1: 3.
    try testing.expectEqual(3, try score_of(
        \\fn unwrap(value: ?u8, a: bool) u8 {
        \\    return value orelse {
        \\        if (a) return 1;
        \\        return 0;
        \\    };
        \\}
    , "unwrap"));
    // for 1, orelse 1+1, the if inside the block 1+2: 6.
    try testing.expectEqual(6, try score_of(
        \\fn first_or_default(items: []const ?u8, a: bool) u8 {
        \\    for (items) |item| {
        \\        return item orelse {
        \\            if (a) return 1;
        \\            return 0;
        \\        };
        \\    }
        \\    return 0;
        \\}
    , "first_or_default"));
}

test "every catch adds 1 plus nesting and nests its operand" {
    // catch 1, the if inside the block 1+1: 3, with or without a payload.
    try testing.expectEqual(3, try score_of(
        \\fn handle(value: anyerror!u8, a: bool) u8 {
        \\    return value catch |failure| {
        \\        if (a) return 1;
        \\        _ = failure;
        \\        return 0;
        \\    };
        \\}
    , "handle"));
    try testing.expectEqual(3, try score_of(
        \\fn recover(fallible: anytype, flag: bool) u32 {
        \\    return fallible.call() catch {
        \\        if (flag) return 1;
        \\        return 0;
        \\    };
        \\}
    , "recover"));
    try testing.expectEqual(1, try score_of(
        \\fn fallback(value: anyerror!u8) u8 {
        \\    return value catch 0;
        \\}
    , "fallback"));
    // for 1, catch 1+1: 3.
    try testing.expectEqual(3, try score_of(
        \\fn drain(items: []const anyerror!u8) void {
        \\    for (items) |item| _ = item catch 0;
        \\}
    , "drain"));
}

test "a labelled break or continue adds 1 and an unlabelled one adds nothing" {
    // outer while 1, inner while 1+1, labelled break 1: 4.
    try testing.expectEqual(4, try score_of(
        \\fn escape(a: bool) void {
        \\    outer: while (a) {
        \\        while (a) {
        \\            break :outer;
        \\        }
        \\    }
        \\}
    , "escape"));
    // outer while 1, inner while 1+1, labelled continue 1, unlabelled continue 0: 4.
    try testing.expectEqual(4, try score_of(
        \\fn again(a: bool) void {
        \\    outer: while (a) {
        \\        while (a) {
        \\            continue :outer;
        \\        }
        \\        continue;
        \\    }
        \\}
    , "again"));
    // while 1, if 1+1, labelled break 1, unlabelled break 0: 4.
    try testing.expectEqual(4, try score_of(
        \\fn search(items: []const u8) void {
        \\    outer: while (true) {
        \\        if (items.len == 0) break :outer;
        \\        break;
        \\    }
        \\}
    , "search"));
}

test "a labelled block adds nothing and raises no level, and each break to it adds 1" {
    try testing.expectEqual(0, try score_of(
        \\fn labelled() void {
        \\    block: {
        \\        _ = 1;
        \\    }
        \\}
    , "labelled"));
    // Only the if counts, at nesting 0.
    try testing.expectEqual(1, try score_of(
        \\fn labelled(a: bool) void {
        \\    block: {
        \\        if (a) return;
        \\    }
        \\}
    , "labelled"));
    // if 1, two labelled breaks 2: 3.
    try testing.expectEqual(3, try score_of(
        \\fn labelled(a: bool) u8 {
        \\    return block: {
        \\        if (a) break :block 1;
        \\        break :block 2;
        \\    };
        \\}
    , "labelled"));
}

test "defer, errdefer, try, comptime and unreachable add nothing" {
    try testing.expectEqual(0, try score_of(
        \\fn cleanup(file: anytype) void {
        \\    defer file.close();
        \\    errdefer file.remove();
        \\}
    , "cleanup"));
    try testing.expectEqual(0, try score_of(
        \\fn forward(value: anyerror!u8) !u8 {
        \\    return try value;
        \\}
    , "forward"));
    try testing.expectEqual(0, try score_of(
        \\fn constant() u32 {
        \\    comptime {
        \\        _ = 1;
        \\    }
        \\    return comptime 2;
        \\}
    , "constant"));
    try testing.expectEqual(0, try score_of(
        \\fn never() void {
        \\    unreachable;
        \\}
    , "never"));
}

test "a call to the enclosing function adds 1 and a call through a field access does not" {
    try testing.expectEqual(1, try score_of(
        \\fn again(n: u32) u32 {
        \\    return again(n);
        \\}
    , "again"));
    // if 1, the recursive call 1: 2.
    try testing.expectEqual(2, try score_of(
        \\fn factorial(n: u32) u32 {
        \\    if (n == 0) return 1;
        \\    return n * factorial(n - 1);
        \\}
    , "factorial"));
    try testing.expectEqual(0, try score_of(
        \\const Self = struct {
        \\    fn again(self: Self) void {
        \\        self.again();
        \\        Self.again(self);
        \\    }
        \\};
    , "again"));
}

test "the boundary fixture scores exactly 15 and exactly 16" {
    try testing.expectEqual(15, try score_of(fixture.boundary_source, "fifteen"));
    try testing.expectEqual(16, try score_of(fixture.boundary_source, "sixteen"));
}
