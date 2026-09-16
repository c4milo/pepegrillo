//! The command line of the commit-message linter:
//!
//!     commit_lint --range REV [REV...]
//!     commit_lint --message PATH
//!
//! `--range` takes every following argument up to the next flag of this tool or the end of the
//! command line, and hands them all to git as revision arguments, so `SHA --not --remotes` is one
//! range. `--message` takes exactly one path, the file a git hook is handed. Exactly one of the two
//! is wanted: none and two are both usage errors.

const std = @import("std");

pub const message_flag = "--message";
pub const range_flag = "--range";

pub const usage =
    \\usage: commit_lint --range REV [REV...]
    \\       commit_lint --message PATH
    \\
;

/// What the linter reads: one message file, or every commit git lists for a set of revision
/// arguments.
pub const Input = union(enum) {
    message: []const u8,
    range: []const []const u8,
};

pub const Options = struct { input: Input };

pub const ArgumentError = error{
    MissingValue,
    TooManyValues,
    UnknownArgument,
    TwoInputs,
    NoInput,
};

const Flag = enum {
    message,
    range,

    /// The input the flag makes of the values that followed it. `--message` takes exactly one
    /// path; `--range` takes every value it was given.
    fn with(self: Flag, values: []const []const u8) ArgumentError!Input {
        if (values.len == 0) return error.MissingValue;
        return switch (self) {
            .message => if (values.len == 1) .{ .message = values[0] } else error.TooManyValues,
            .range => .{ .range = values },
        };
    }
};

fn flag_of(argument: []const u8) ?Flag {
    if (std.mem.eql(u8, argument, message_flag)) return .message;
    if (std.mem.eql(u8, argument, range_flag)) return .range;
    return null;
}

/// The arguments from `start` up to the next flag or the end. A revision git spells with leading
/// hyphens, `--not` or `--remotes`, is no flag of this tool, so it lands here.
fn values_after(arguments: []const []const u8, start: usize) []const []const u8 {
    var end = start;
    while (end < arguments.len and flag_of(arguments[end]) == null) end += 1;
    return arguments[start..end];
}

/// Reads `arguments` (without the program name) into `Options`.
pub fn parse_arguments(arguments: []const []const u8) ArgumentError!Options {
    var input: ?Input = null;
    var index: usize = 0;
    while (index < arguments.len) {
        const flag = flag_of(arguments[index]) orelse return error.UnknownArgument;
        if (input != null) return error.TwoInputs;
        const values = values_after(arguments, index + 1);
        input = try flag.with(values);
        index += 1 + values.len;
    }
    return .{ .input = input orelse return error.NoInput };
}

// Tests.

const testing = std.testing;

test "parse_arguments takes exactly one input flag" {
    const message = (try parse_arguments(&.{ "--message", "m.txt" })).input.message;
    try testing.expectEqualStrings("m.txt", message);
    const one = (try parse_arguments(&.{ "--range", "a..b" })).input.range;
    try testing.expectEqual(1, one.len);
    try testing.expectEqualStrings("a..b", one[0]);
    try testing.expectError(error.NoInput, parse_arguments(&.{}));
    try testing.expectError(error.MissingValue, parse_arguments(&.{"--range"}));
    try testing.expectError(error.MissingValue, parse_arguments(&.{"--message"}));
    try testing.expectError(error.UnknownArgument, parse_arguments(&.{"--rule"}));
    try testing.expectError(error.UnknownArgument, parse_arguments(&.{"a..b"}));
}

test "parse_arguments refuses two inputs and a second message path" {
    const range_then_message = [_][]const u8{ "--range", "a..b", "--message", "m.txt" };
    try testing.expectError(error.TwoInputs, parse_arguments(&range_then_message));
    const two_ranges = [_][]const u8{ "--range", "a..b", "--range", "c..d" };
    try testing.expectError(error.TwoInputs, parse_arguments(&two_ranges));
    const two_paths = [_][]const u8{ "--message", "a.txt", "b.txt" };
    try testing.expectError(error.TooManyValues, parse_arguments(&two_paths));
}

test "parse_arguments hands --range every revision argument that follows it" {
    // The shape a pre-push hook passes for a branch the remote has never seen: a sha and the two
    // arguments that exclude every remote-tracking ref.
    const arguments = [_][]const u8{ "--range", "abc123", "--not", "--remotes" };
    const revisions = (try parse_arguments(&arguments)).input.range;
    try testing.expectEqual(3, revisions.len);
    try testing.expectEqualStrings("abc123", revisions[0]);
    try testing.expectEqualStrings("--not", revisions[1]);
    try testing.expectEqualStrings("--remotes", revisions[2]);
}
