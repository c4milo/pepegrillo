//! pepegrillo's cognitive-complexity score over itself. The threshold and the paths come from
//! build.zig, so this entry point forwards to the tool and configures nothing.

const std = @import("std");
const pepegrillo = @import("pepegrillo");

pub fn main(init: std.process.Init) !void {
    return pepegrillo.complexity.main(init);
}
