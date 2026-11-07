//! The lint engine: the driver, what a rule receives, the readers a rule uses, and the generic
//! rules a project configures. A project's lint entry point imports this through `pepegrillo`.
//!
//! The root exports names, and five file namespaces: `report`, what a rule receives; `paths` and
//! `ast`, the readers; `harness`, the test support; and `rules`, one namespace for each rule.

pub const report = @import("report.zig");
pub const paths = @import("paths.zig");
pub const ast = @import("ast.zig");
pub const harness = @import("harness.zig");
pub const rules = @import("rules/rules.zig");

const files = struct {
    const driver = @import("driver.zig");
    const scope = @import("scope.zig");
    const text = @import("text.zig");
    const names = @import("names.zig");
};

pub const Linter = files.driver.Linter;
pub const Scope = files.scope.Scope;
pub const Line = files.text.Line;
pub const LineIterator = files.text.LineIterator;
pub const count_lines = files.text.count_lines;
pub const is_word_byte = files.text.is_word_byte;
pub const assert_all_resolve = files.names.assert_all_resolve;
pub const assert_all_match = files.names.assert_all_match;

test "the root exports these names alone" {
    try @import("../public_names.zig").expect(@This(), &.{
        "report",           "paths",       "ast",          "harness",
        "rules",            "Linter",      "Scope",        "Line",
        "LineIterator",     "count_lines", "is_word_byte", "assert_all_resolve",
        "assert_all_match",
    });
}

test {
    _ = files.driver;
    _ = files.scope;
    _ = files.text;
    _ = files.names;
    _ = @import("ast_scan.zig");
    _ = report;
    _ = paths;
    _ = ast;
    _ = harness;
    _ = rules;
}
