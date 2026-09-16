//! Tests of what the scorer scores and reports: which declarations it collects, their names,
//! lines and columns, nested functions and prototypes, and the limits that make a file be
//! reported rather than scored.

const std = @import("std");
const Ast = std.zig.Ast;
const testing = std.testing;
const scorer = @import("complexity_scorer.zig");
const score_source = scorer.score_source;
const score_of = @import("complexity_fixture.zig").score_of;

test "a function inside a struct and inside a returned struct is scored" {
    try testing.expectEqual(1, try score_of(
        \\const Point = struct {
        \\    x: u32,
        \\    fn positive(self: Point) bool {
        \\        if (self.x > 0) return true;
        \\        return false;
        \\    }
        \\};
    , "positive"));
    try testing.expectEqual(1, try score_of(
        \\fn Generic(comptime T: type) type {
        \\    return struct {
        \\        fn check(value: T) bool {
        \\            if (value == 0) return true;
        \\            return false;
        \\        }
        \\    };
        \\}
    , "check"));
}

test "a nested function is scored on its own and one level deeper in the enclosing function" {
    const unused_local =
        \\fn outer(a: bool) void {
        \\    const Local = struct {
        \\        fn inner() void {
        \\            if (a) return;
        \\        }
        \\    };
        \\    _ = Local;
        \\}
    ;
    try testing.expectEqual(2, try score_of(unused_local, "outer"));
    try testing.expectEqual(1, try score_of(unused_local, "inner"));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const scores = try score_source(arena_state.allocator(), "src/store/page.zig",
        \\fn outer(flag: bool) void {
        \\    const Helper = struct {
        \\        fn inner(f: bool) void {
        \\            if (f) {}
        \\        }
        \\    };
        \\    if (flag) Helper.inner(flag);
        \\}
    );
    try testing.expectEqual(2, scores.len);
    // `outer`: its own if 1, plus the if of `inner` one level deeper 1+1: 3. Results come in
    // source order, so the enclosing function is first.
    try testing.expectEqualStrings("outer", scores[0].name);
    try testing.expectEqual(3, scores[0].score);
    try testing.expectEqualStrings("inner", scores[1].name);
    try testing.expectEqual(1, scores[1].score);
}

test "prototype types of a nested function or a function type count at the enclosing level" {
    // The if in a parameter type 1, its else 1: 2 for every prototype shape.
    try testing.expectEqual(2, try score_of(
        \\fn nested_parameters(comptime flag: bool) type {
        \\    return struct {
        \\        fn inner(a: u8, b: if (flag) u8 else u16) void {
        \\            _ = a;
        \\            _ = b;
        \\        }
        \\    };
        \\}
    , "nested_parameters"));
    try testing.expectEqual(2, try score_of(
        \\fn callback(comptime flag: bool) type {
        \\    return *const fn (u8, if (flag) u8 else u16) void;
        \\}
    , "callback"));
    try testing.expectEqual(2, try score_of(
        \\fn callback(comptime flag: bool) type {
        \\    return *const fn (if (flag) u8 else u16) callconv(.c) void;
        \\}
    , "callback"));
    try testing.expectEqual(2, try score_of(
        \\fn callback(comptime flag: bool) type {
        \\    return *const fn (u8, u8) if (flag) u8 else u16;
        \\}
    , "callback"));
    // if 1; the nested function sits inside it, and the if in its parameter type counts at that
    // level, 1+1, with its else 1: 4. Scoring the prototype one level deeper would make it 5.
    try testing.expectEqual(4, try score_of(
        \\fn guarded(comptime flag: bool) void {
        \\    if (flag) {
        \\        const Local = struct {
        \\            fn inner(a: u8, b: if (flag) u8 else u16) void {
        \\                _ = a;
        \\                _ = b;
        \\            }
        \\        };
        \\        _ = Local;
        \\    }
        \\}
    , "guarded"));
}

test "a function declared inside a parameter type is collected" {
    try testing.expectEqual(1, try score_of(
        \\fn host(a: u8, b: struct {
        \\    fn hidden(c: bool) void {
        \\        if (c) {}
        \\    }
        \\}) void {
        \\    _ = a;
        \\    _ = b;
        \\}
    , "hidden"));
}

test "an extern prototype is not scored and a test block is, under its quoted name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const scores = try score_source(arena_state.allocator(), "src/store/page.zig",
        \\extern fn external(a: u32) u32;
        \\test "block" {
        \\    if (true) {}
        \\}
        \\fn scored() void {}
    );
    // The prototype has no body to score. The test block's name keeps its quotes: that is the
    // name a reader searches the source for.
    try testing.expectEqual(2, scores.len);
    try testing.expectEqualStrings("\"block\"", scores[0].name);
    try testing.expectEqual(1, scores[0].score);
    try testing.expectEqualStrings("scored", scores[1].name);
}

test "a test block is scored under the function rules, and a test with no name under test" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const named = try score_source(arena, "src/store/page.zig",
        \\test "counts its branches" {
        \\    if (true) { if (true) {} }
        \\}
    );
    try testing.expectEqual(1, named.len);
    try testing.expectEqualStrings("\"counts its branches\"", named[0].name);
    // if 1, the if inside it 1+1: 3.
    try testing.expectEqual(3, named[0].score);
    try testing.expectEqual(1, named[0].line);

    const unnamed = try score_source(arena, "src/store/page.zig",
        \\test {
        \\    if (true) {}
        \\}
    );
    try testing.expectEqual(1, unnamed.len);
    try testing.expectEqualStrings("test", unnamed[0].name);
}

test "line and column point at the name token, and the path is copied" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const scores = try score_source(arena_state.allocator(), "src/store/page.zig",
        \\const x = 1;
        \\pub fn named() void {}
    );
    try testing.expectEqual(2, scores[0].line);
    try testing.expectEqual(8, scores[0].column);
    try testing.expectEqualStrings("src/store/page.zig", scores[0].path);
}

test "a source the parser rejects is reported rather than scored" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(
        error.ParseFailed,
        score_source(arena_state.allocator(), "src/store/page.zig", "fn broken( {"),
    );
}

/// Nesting levels in `deep_source`: one more than the old ceiling of 64, which the scorer no
/// longer has.
const deep_levels = 65;

/// A function whose body is `deep_levels` nested `if` blocks.
const deep_source = "fn deep(a: bool) void { " ++ ("if (a) { " ** deep_levels) ++
    ("} " ** deep_levels) ++ "}";

test "a body nested 65 levels deep is scored" {
    // The if at level k adds 1+k, for k from 0 to 64: 65 * 66 / 2 = 2145.
    try testing.expectEqual(2145, try score_of(deep_source, "deep"));
}

/// Nesting in the two sources past the tree depth. Each level is at least one AST node, so the
/// tree is deeper than `max_tree_depth` whatever else it holds.
const too_deep_levels = scorer.max_tree_depth + 88;

test "a file nested past the tree depth outside any function is reported, not scored" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = "const value = " ++ ("(" ** too_deep_levels) ++ "1" ++
        (")" ** too_deep_levels) ++ ";";
    try testing.expectError(
        error.NestingTooDeep,
        score_source(arena_state.allocator(), "src/store/page.zig", source),
    );
}

test "the scorer stops at the tree depth when it walks a body on its own" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = "fn deep(a: bool) void { " ++ ("if (a) { " ** too_deep_levels) ++
        ("} " ** too_deep_levels) ++ "}";
    var tree = try Ast.parse(arena, source, .zig);
    defer tree.deinit(arena);
    try testing.expectEqual(0, tree.errors.len);
    var too_deep = false;
    const scored = scorer.score_declaration(&tree, tree.rootDecls()[0], &too_deep);
    try testing.expect(scored != null);
    try testing.expect(too_deep);
}

/// One function declaration, repeated to build a file at and past `max_functions_per_file`.
const one_function = "fn f() void {}\n";

test "a file past max_functions_per_file is reported, and a file at it is scored" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const at_limit = one_function ** scorer.max_functions_per_file;
    const scores = try score_source(arena, "src/store/page.zig", at_limit);
    try testing.expectEqual(scorer.max_functions_per_file, scores.len);
    try testing.expectError(
        error.TooManyFunctions,
        score_source(arena, "src/store/page.zig", at_limit ++ one_function),
    );
}
