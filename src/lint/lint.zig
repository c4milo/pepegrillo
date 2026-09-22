//! The lint engine: the driver, what a rule receives, the readers a rule uses, and the generic
//! rules a project configures. A project's lint entry point imports this through `pepegrillo`.

pub const Linter = @import("driver.zig").Linter;
pub const driver = @import("driver.zig");
pub const report = @import("report.zig");
pub const paths = @import("paths.zig");
pub const scope = @import("scope.zig");
pub const Scope = scope.Scope;
pub const text = @import("text.zig");
pub const ast = @import("ast.zig");
pub const ast_scan = @import("ast_scan.zig");
pub const names = @import("names.zig");
pub const harness = @import("harness.zig");
pub const rules = @import("rules/rules.zig");

test {
    _ = @import("driver.zig");
    _ = @import("report.zig");
    _ = @import("paths.zig");
    _ = @import("scope.zig");
    _ = @import("text.zig");
    _ = @import("ast.zig");
    _ = @import("ast_scan.zig");
    _ = @import("names.zig");
    _ = @import("harness.zig");
    _ = rules;
}
