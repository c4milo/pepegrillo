//! Tests of the unreleased-acquire switches: `read_assignments`, `read_subscript_targets` and
//! `read_loop_reentry`, and the defers in effect that the three of them lean on. Split off
//! `unreleased_acquire_test.zig`, which holds the tests of the rule with every switch off.

const std = @import("std");
const testing = std.testing;
const base = @import("unreleased_acquire_test.zig");
const expect_findings = base.expect_findings;
const reported = base.reported;
const Rule = base.Rule;
const unreleased_acquire = @import("unreleased_acquire.zig");

// Assignments, which `read_assignments` switches on.

const Assignments = unreleased_acquire.Rule(.{
    .scope = .{ .extensions = &.{".zig"} },
    .acquire_prefixes = &.{"open_"},
    .read_assignments = true,
});

test "an assignment is an acquire only under read_assignments" {
    const source: [:0]const u8 =
        \\fn run(slots: []Socket) !void {
        \\    for (slots) |*slot| {
        \\        slot.* = try open_socket();
        \\        try connect(slot.*);
        \\    }
        \\}
    ;
    try expect_findings(Rule, source, &.{});
    try expect_findings(Assignments, source, &.{reported("slot")});
}

test "an assignment names the root of its target, through a field and a dereference" {
    try expect_findings(Assignments,
        \\fn run(client: *Client) !void {
        \\    client.socket = try open_socket();
        \\    try bind(client.socket);
        \\}
    , &.{reported("client")});
}

test "a defer naming the root passes an assignment acquire" {
    try expect_findings(Assignments,
        \\fn run(client: *Client) !void {
        \\    client.socket = try open_socket();
        \\    defer client.deinit();
        \\    try bind(client.socket);
        \\}
    , &.{});
}

test "an acquire the statement discards binds no name and is passed" {
    try expect_findings(Assignments,
        \\fn run() !void {
        \\    _ = try open_socket();
        \\    try run_the_rest();
        \\}
    , &.{});
}

const Subscripts = unreleased_acquire.Rule(.{
    .scope = .{ .extensions = &.{".zig"} },
    .acquire_prefixes = &.{"open_"},
    .read_assignments = true,
    .read_subscript_targets = true,
});

test "an acquire into a subscript is read only under read_subscript_targets" {
    const source: [:0]const u8 =
        \\fn run(slots: []Socket, index: usize) !void {
        \\    slots[index] = try open_socket();
        \\    try connect(slots[index]);
        \\}
    ;
    try expect_findings(Assignments, source, &.{});
    try expect_findings(Subscripts, source, &.{reported("slots")});
}

test "an assignment of something the acquire lists do not name is passed" {
    try expect_findings(Assignments,
        \\fn run(client: *Client) !void {
        \\    client.socket = try connect_socket();
        \\    try bind(client.socket);
        \\}
        \\fn plain(client: *Client) !void {
        \\    client.socket = open_socket();
        \\    try bind(client.socket);
        \\}
    , &.{});
}

test "an acquire inside a block that is a statement of another is read" {
    try expect_findings(Rule,
        \\fn run(path: []const u8) !void {
        \\    {
        \\        const socket = try open_socket(path);
        \\        try bind(socket);
        \\    }
        \\}
    , &.{reported("socket")});
}

// The defers already registered where the acquire stands.

test "a defer above an assignment acquire in its own block releases it" {
    try expect_findings(Assignments,
        \\fn run() !void {
        \\    var socket: Descriptor = undefined;
        \\    defer close_now(socket);
        \\    socket = try open_socket();
        \\    try bind(socket);
        \\}
    , &.{});
}

test "a defer of the block above releases what a loop under it acquires" {
    try expect_findings(Assignments,
        \\fn run(client: *Client) !void {
        \\    defer client.deinit();
        \\    while (more()) {
        \\        client.socket = try open_socket();
        \\        try bind(client.socket);
        \\    }
        \\}
    , &.{});
}

test "a defer of a block the walk has left releases nothing under it" {
    try expect_findings(Assignments,
        \\fn run(client: *Client) !void {
        \\    {
        \\        defer client.deinit();
        \\    }
        \\    client.socket = try open_socket();
        \\    try bind(client.socket);
        \\}
    , &.{reported("client")});
}

test "a defer under the acquire's own block does not reach a block beside it" {
    try expect_findings(Assignments,
        \\fn run(client: *Client) !void {
        \\    {
        \\        client.socket = try open_socket();
        \\        try bind(client.socket);
        \\    }
        \\    defer client.deinit();
        \\}
    , &.{reported("client")});
}

test "a declaration acquire cannot be released by a defer above it" {
    // The name does not exist yet where that defer is written, so the walk changes nothing here.
    try expect_findings(Rule,
        \\fn run(path: []const u8) !void {
        \\    defer close_all();
        \\    const socket = try open_socket(path);
        \\    try bind(socket);
        \\}
    , &.{reported("socket")});
}

/// One defer more than the stack of defers in effect holds, none of them naming the acquire.
const crowding_defers = blk: {
    var text: []const u8 = "";
    for (0..unreleased_acquire.max_registered_defers + 1) |index| {
        text = text ++ std.fmt.comptimePrint("    defer t{d}();\n", .{index});
    }
    break :blk text;
};

test "a block registering more defers than the stack holds releases everything under it" {
    const source = "fn run() !void {\n" ++ crowding_defers ++
        "    var socket: Descriptor = undefined;\n" ++
        "    socket = try open_socket();\n" ++
        "    try bind(socket);\n}\n";
    try expect_findings(Assignments, source, &.{});
}

// A loop, which `read_loop_reentry` switches on.

const Loops = unreleased_acquire.Rule(.{
    .scope = .{ .extensions = &.{".zig"} },
    .acquire_prefixes = &.{"open_"},
    .read_loop_reentry = true,
});

test "an acquire a loop never releases is read only under read_loop_reentry" {
    // Nothing stands under the acquire in its own block, so only the next turn of the loop loses
    // what this one took.
    const source: [:0]const u8 =
        \\fn run(count: usize) !void {
        \\    var index: usize = 0;
        \\    while (index < count) : (index += 1) {
        \\        const socket = try open_socket();
        \\        store(index, socket);
        \\    }
        \\}
    ;
    try expect_findings(Rule, source, &.{});
    try expect_findings(Loops, source, &.{reported("socket")});
}

test "a loop that releases what it takes is passed" {
    try expect_findings(Loops,
        \\fn run(count: usize) !void {
        \\    var index: usize = 0;
        \\    while (index < count) : (index += 1) {
        \\        const socket = try open_socket();
        \\        close_now(socket);
        \\    }
        \\    for (list) |entry| {
        \\        const handle = try open_socket();
        \\        defer close_now(handle);
        \\        use(entry, handle);
        \\    }
        \\}
    , &.{});
}

test "a defer above the loop releases what every turn of it takes" {
    const Both = unreleased_acquire.Rule(.{
        .scope = .{ .extensions = &.{".zig"} },
        .acquire_prefixes = &.{"open_"},
        .read_assignments = true,
        .read_subscript_targets = true,
        .read_loop_reentry = true,
    });
    // The guard a tree writes for this: the defer stands above the loop and closes what the loop
    // reached, counted by the same variable the loop advances.
    try expect_findings(Both,
        \\fn run() !void {
        \\    var clients: [4]Socket = undefined;
        \\    var opened: usize = 0;
        \\    defer for (clients[0..opened]) |client| close_now(client);
        \\    while (opened < 4) : (opened += 1) {
        \\        clients[opened] = try open_socket();
        \\    }
        \\}
    , &.{});
}

test "a defer written under the loop guards no turn of it" {
    const Both = unreleased_acquire.Rule(.{
        .scope = .{ .extensions = &.{".zig"} },
        .acquire_prefixes = &.{"open_"},
        .read_assignments = true,
        .read_subscript_targets = true,
        .read_loop_reentry = true,
    });
    // The same guard one line too low: a turn that fails returns before it is registered.
    try expect_findings(Both,
        \\fn run() !void {
        \\    var clients: [4]Socket = undefined;
        \\    var opened: usize = 0;
        \\    while (opened < 4) : (opened += 1) {
        \\        clients[opened] = try open_socket();
        \\    }
        \\    defer for (clients[0..opened]) |client| close_now(client);
        \\}
    , &.{reported("clients")});
}

test "the body of a for stands inside it, with one input and with two" {
    try expect_findings(Loops,
        \\fn one(list: []Entry) !void {
        \\    for (list) |entry| {
        \\        const socket = try open_socket();
        \\        store(entry, socket);
        \\    }
        \\}
        \\fn two(list: []Entry, marks: []Mark) !void {
        \\    for (list, marks) |entry, mark| {
        \\        const handle = try open_socket();
        \\        store(entry, mark, handle);
        \\    }
        \\}
    , &.{ reported("socket"), reported("handle") });
}

test "an else branch and the inputs of a for do not stand inside the loop" {
    try expect_findings(Loops,
        \\fn run(list: []Entry) !void {
        \\    for (list) |entry| {
        \\        use(entry);
        \\    } else {
        \\        const socket = try open_socket();
        \\        store(socket);
        \\    }
        \\}
    , &.{});
}
