//! What a TLC configuration file says about itself, in the comment lines at its top.
//!
//!     \* expect: holds
//!     \* module: MCStore
//!
//! `expect` is the verdict TLC must reach: `holds` when every invariant and property holds, and
//! `violated` when one fails. A configuration that expects a violation shows the property can
//! fail, so the configurations that expect it to hold are not holding vacuously. `module` names
//! the specification the configuration checks. Both are optional: a mutant expects a violation
//! unless it says otherwise, and the module falls back to the one `tla_models.module_for` finds.
//!
//! The header is the run of lines at the top that start with `\*`, TLA+'s line comment. The first
//! line that does not start with it ends the header.

const std = @import("std");

/// The verdict a configuration expects of TLC.
pub const Expectation = enum {
    holds,
    violated,
};

pub const Header = struct {
    expect: ?Expectation = null,
    module: ?[]const u8 = null,
};

pub const Error = error{
    /// An `expect:` line names neither `holds` nor `violated`.
    UnknownExpectation,
    /// A `module:` line names nothing.
    EmptyModule,
};

/// TLA+'s line comment, which every header line starts with.
const comment_marker = "\\*";
const expect_key = "expect:";
const module_key = "module:";

/// Header lines read before the header is taken to have ended. A header is two lines; the rest is
/// room for the prose a configuration opens with.
const header_lines_max: usize = 32;

/// Reads the header at the top of a configuration's text.
pub fn read(text: []const u8) Error!Header {
    var header: Header = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    for (0..header_lines_max) |_| {
        const line = std.mem.trim(u8, lines.next() orelse break, " \t\r");
        if (!std.mem.startsWith(u8, line, comment_marker)) break;
        const content = std.mem.trim(u8, line[comment_marker.len..], " \t");
        if (value_after(content, expect_key)) |value| {
            header.expect = std.meta.stringToEnum(Expectation, value) orelse return error.UnknownExpectation;
        } else if (value_after(content, module_key)) |value| {
            if (value.len == 0) return error.EmptyModule;
            header.module = value;
        }
    }
    return header;
}

/// The trimmed text after `key` when `content` starts with it, or null.
fn value_after(content: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, content, key)) return null;
    return std.mem.trim(u8, content[key.len..], " \t");
}

// Tests.

const testing = std.testing;

test "read takes the expectation and the module from the comment lines at the top" {
    const header = try read("\\* expect: violated\n\\* module: MCStore\nSPECIFICATION Spec\n");
    try testing.expectEqual(Expectation.violated, header.expect.?);
    try testing.expectEqualStrings("MCStore", header.module.?);
    const holds = try read("\\*   expect:   holds  \r\nSPECIFICATION Spec\n");
    try testing.expectEqual(Expectation.holds, holds.expect.?);
    try testing.expectEqual(null, holds.module);
}

test "read skips prose in the header and stops at the first line that is not a comment" {
    const header = try read("\\* The clean model.\n\\* expect: holds\nSPECIFICATION Spec\n\\* expect: violated\n");
    try testing.expectEqual(Expectation.holds, header.expect.?);
    const none = try read("SPECIFICATION Spec\n\\* expect: violated\n");
    try testing.expectEqual(null, none.expect);
}

test "read refuses an expectation it does not know, and a module with no name" {
    try testing.expectError(error.UnknownExpectation, read("\\* expect: passes\n"));
    try testing.expectError(error.EmptyModule, read("\\* module:\n"));
}
