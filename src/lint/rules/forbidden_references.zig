//! forbidden-references: a file names none of the declarations a project forbids. The project
//! lists what it forbids, such as the standard library's heap, clock or sockets, and the rule
//! reports every place a file in its `scope` names one.
//!
//! The rule parses each file, walks every node, and makes four checks:
//!
//! 1. A chain the chain matchers forbid. A chain is an identifier or a field-access chain over
//!    one, such as `std.heap.page_allocator`. The walk reads a chain whole, reports it once at its
//!    first token, and never descends into it. The chain matchers:
//!    - `prefixes`: the chain is the prefix, or starts with it followed by a dot, so `std.heap`
//!      matches `std.heap.page_allocator` and not `std.heapish`;
//!    - `raw_prefixes`: the chain starts with it, dot or not, so `std.posix.clock_` matches
//!      `std.posix.clock_gettime`;
//!    - `segment_names`: one segment of the chain equals it, so `Instant` matches
//!      `time.Instant.now`;
//!    - `segment_suffixes`: one segment of the chain ends with it, so `HashMap` matches
//!      `std.AutoHashMap`.
//!
//!    A chain one of `exceptions` names is not a finding, whatever the matchers say.
//! 2. A call whose callee chain ends with a segment in `callee_names`: `clock.nanoTimestamp()`.
//!    A field with the same name read without a call, `header.timestamp`, is not a finding. A
//!    callee chain check 1 already reports is not reported a second time.
//! 3. A method call `method_calls` forbids: one of `methods_on_any_receiver` called on any
//!    receiver, or one of `methods_on_named_receivers` called on a receiver whose last segment
//!    contains one of `receiver_words` in any case. The AST carries no types, so the receiver's
//!    name is how the rule tells `gpa.free(bytes)` from `free_list.free(slot)`. The finding names
//!    the method, so it is reported even when check 1 reports the callee chain as well.
//! 4. When `parameter_check` is set, a function parameter whose type expression holds a chain
//!    with the segment `type_segment`, on any function or function type. The whole type
//!    expression is searched, so `*const Allocator`, `?Allocator` and `[]const Allocator` match.
//!
//! Checks 1 to 3 report `reference to <name>`, and check 4 reports `<function> takes
//! <description>`. When `reason` is set, `: <reason>` follows either message.
//!
//! `resolve_file_aliases` makes checks 1 and 2 read a chain a second time, through the file's
//! aliases. An alias is a `const` declared at the top level of the file whose value is a chain or
//! `@import("std")`, which reads as `std`: `const linux = std.os.linux;`. A chain whose first
//! segment names an alias is read again with the alias's value in place of that segment, so
//! `linux.clock_gettime` is also read as `std.os.linux.clock_gettime`. An alias of an alias
//! resolves the same way. When check 1 forbids a chain only through an alias, the finding is
//! `reference to <resolved name> through <alias>`. The written chain is read first, so the switch
//! can add findings and never removes one.
//!
//! `parameter_types` chooses which parameter types the walk reads. `every_prototype` reads them
//! all. `simple_prototypes_only` reads the parameter of a prototype that declares at most one
//! parameter and no `align`, `addrspace`, `linksection` or `callconv`, and reads only the return
//! type of every other prototype: the reading of a walk that skipped the other parameter lists.
//!
//! What the rule cannot see: a value passed as `anytype`, which carries no type expression, and
//! a forbidden declaration re-exported under another name, `const clock = other.clock;`. The
//! rule reads the text of the source, not its types. `resolve_file_aliases` narrows the second
//! kind to these shapes, which it still cannot see: an alias declared in a function or in a
//! container below the top level, an alias whose value is not a chain (`if (a) std.c else
//! std.os.linux`, `@field(std, "c")`), a chain that starts with `@import("std")` written in place,
//! and a name another file exports. Check 3 and check 4 read the chain as written.

const std = @import("std");
const ast = @import("../ast.zig");
const report = @import("../report.zig");
const Scope = @import("../scope.zig").Scope;
const walk = @import("forbidden_references_walk.zig");

/// A chain the chain matchers forbid but which reads nothing forbidden: one that starts with
/// `prefix` at a dot boundary and whose last segment starts with one of `last_segment_prefixes`.
/// `std.time` with `ns_per_` allows `std.time.ns_per_ms`, a number the compiler folds.
pub const Exception = struct {
    prefix: []const u8,
    last_segment_prefixes: []const []const u8,
};

/// The method calls check 3 forbids.
pub const MethodCalls = struct {
    /// A call of one of these methods on any receiver is a finding: `allocator` finds
    /// `arena.allocator()`.
    methods_on_any_receiver: []const []const u8 = &.{},
    /// A call of one of these methods is a finding when its receiver is named by
    /// `receiver_words`.
    methods_on_named_receivers: []const []const u8 = &.{},
    /// A receiver whose last segment contains one of these, in any case, is a named receiver.
    receiver_words: []const []const u8 = &.{},
};

/// The parameter type check 4 forbids.
pub const ParameterCheck = struct {
    /// A parameter whose type expression holds a chain with this segment is a finding.
    type_segment: []const u8,
    /// What the finding says the function takes: `an allocator parameter` reports
    /// `read takes an allocator parameter`.
    description: []const u8,
};

/// Which parameter types the walk reads; see the file header.
pub const ParameterTypes = ast.ParameterTypes;

pub const Config = struct {
    /// The rule name findings are reported under and `--rule` selects.
    name: []const u8,
    /// The files the rule reads.
    scope: Scope,
    prefixes: []const []const u8 = &.{},
    raw_prefixes: []const []const u8 = &.{},
    segment_names: []const []const u8 = &.{},
    segment_suffixes: []const []const u8 = &.{},
    exceptions: []const Exception = &.{},
    callee_names: []const []const u8 = &.{},
    method_calls: MethodCalls = .{},
    parameter_check: ?ParameterCheck = null,
    parameter_types: ParameterTypes = .every_prototype,
    /// When set, checks 1 and 2 also read a chain through the file-level aliases the header
    /// describes.
    resolve_file_aliases: bool = false,
    /// Printed after every finding, following `: `. Null prints the finding alone.
    reason: ?[]const u8 = null,
};

/// The rule for one configuration: a type with the `name` and `check` the driver dispatches to.
pub fn Rule(comptime config: Config) type {
    comptime std.debug.assert(config.name.len != 0);
    return struct {
        pub const name = config.name;
        const settings: Config = config;

        pub fn check(context: *report.Context, file: report.File) !void {
            if (!settings.scope.applies(file.path)) return;
            const tree = file.tree orelse return;
            try walk.scan(context, file.path, tree, &settings);
        }
    };
}

/// True when check 1 forbids `chain`.
pub fn is_forbidden_chain(config: *const Config, chain: []const u8) bool {
    if (is_excepted(config.exceptions, chain)) return false;
    if (ast.has_any_prefix_at_dot(chain, config.prefixes)) return true;
    if (starts_with_any(chain, config.raw_prefixes)) return true;
    for (config.segment_names) |segment_name| {
        if (ast.has_segment(chain, segment_name)) return true;
    }
    for (config.segment_suffixes) |suffix| {
        if (ast.has_segment_ending_with(chain, suffix)) return true;
    }
    return false;
}

/// True when check 2 forbids a call through the callee `chain`.
pub fn is_forbidden_callee(config: *const Config, chain: []const u8) bool {
    if (!is_any_of(ast.last_segment(chain), config.callee_names)) return false;
    return !is_forbidden_chain(config, chain);
}

/// True when check 3 forbids calling `method` on `receiver`, the chain before the method.
pub fn is_forbidden_method_call(
    method_calls: *const MethodCalls,
    method: []const u8,
    receiver: []const u8,
) bool {
    if (is_any_of(method, method_calls.methods_on_any_receiver)) return true;
    if (!is_any_of(method, method_calls.methods_on_named_receivers)) return false;
    const receiver_name = ast.last_segment(receiver);
    for (method_calls.receiver_words) |word| {
        if (std.ascii.indexOfIgnoreCase(receiver_name, word) != null) return true;
    }
    return false;
}

fn is_excepted(exceptions: []const Exception, chain: []const u8) bool {
    for (exceptions) |exception| {
        if (!ast.has_prefix_at_dot(chain, exception.prefix)) continue;
        if (starts_with_any(ast.last_segment(chain), exception.last_segment_prefixes)) return true;
    }
    return false;
}

fn starts_with_any(text: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) return true;
    }
    return false;
}

fn is_any_of(text: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, text, candidate)) return true;
    }
    return false;
}

// Tests. These pin the matchers one at a time; `forbidden_references_test.zig` pins the rule.

const testing = std.testing;

const matchers: Config = .{
    .name = "matchers",
    .scope = .{ .extensions = &.{".zig"} },
    .prefixes = &.{"std.heap"},
    .raw_prefixes = &.{"std.posix.clock_"},
    .segment_names = &.{"Instant"},
    .segment_suffixes = &.{"HashMap"},
    .exceptions = &.{.{ .prefix = "std.time", .last_segment_prefixes = &.{ "ns_per_", "s_per_" } }},
    .callee_names = &.{ "nanoTimestamp", "timestamp" },
};

test "each chain matcher forbids the chains it names and no others" {
    try testing.expect(is_forbidden_chain(&matchers, "std.heap"));
    try testing.expect(is_forbidden_chain(&matchers, "std.heap.page_allocator"));
    try testing.expect(!is_forbidden_chain(&matchers, "std.heapish.page_allocator"));
    try testing.expect(!is_forbidden_chain(&matchers, "self.std.heap"));
    try testing.expect(is_forbidden_chain(&matchers, "std.posix.clock_gettime"));
    try testing.expect(!is_forbidden_chain(&matchers, "std.posix.clockwork"));
    try testing.expect(!is_forbidden_chain(&matchers, "posix.clock_gettime"));
    try testing.expect(is_forbidden_chain(&matchers, "time.Instant.now"));
    try testing.expect(!is_forbidden_chain(&matchers, "self.Instants"));
    try testing.expect(is_forbidden_chain(&matchers, "std.AutoHashMap"));
    try testing.expect(!is_forbidden_chain(&matchers, "std.HashMapish"));
}

test "an exception clears a chain only under its prefix and only for its last segments" {
    var excepting = matchers;
    excepting.prefixes = &.{"std.time"};
    try testing.expect(!is_forbidden_chain(&excepting, "std.time.ns_per_ms"));
    try testing.expect(!is_forbidden_chain(&excepting, "std.time.s_per_day"));
    try testing.expect(is_forbidden_chain(&excepting, "std.time.nanoTimestamp"));
    try testing.expect(is_forbidden_chain(&excepting, "std.time.ms_per_s"));
    excepting.segment_names = &.{"ns_per_ms"};
    try testing.expect(is_forbidden_chain(&excepting, "units.ns_per_ms"));
}

test "a callee name forbids a call only when the chain is not already forbidden" {
    try testing.expect(is_forbidden_callee(&matchers, "clock.nanoTimestamp"));
    try testing.expect(is_forbidden_callee(&matchers, "timestamp"));
    try testing.expect(!is_forbidden_callee(&matchers, "clock.nanoTimestamps"));
    try testing.expect(!is_forbidden_callee(&matchers, "time.Instant.timestamp"));
}

test "a method is forbidden on any receiver, or on a receiver its words name" {
    const method_calls: MethodCalls = .{
        .methods_on_any_receiver = &.{"allocator"},
        .methods_on_named_receivers = &.{ "alloc", "free" },
        .receiver_words = &.{ "alloc", "gpa" },
    };
    try testing.expect(is_forbidden_method_call(&method_calls, "allocator", "anything"));
    try testing.expect(is_forbidden_method_call(&method_calls, "free", "self.GPA"));
    try testing.expect(is_forbidden_method_call(&method_calls, "alloc", "page_allocator"));
    try testing.expect(!is_forbidden_method_call(&method_calls, "free", "gpa.free_list"));
    try testing.expect(!is_forbidden_method_call(&method_calls, "create", "gpa"));
    const none: MethodCalls = .{};
    try testing.expect(!is_forbidden_method_call(&none, "allocator", "arena"));
}

test {
    _ = walk;
    _ = @import("forbidden_references_test.zig");
}
