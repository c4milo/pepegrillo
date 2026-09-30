//! pepegrillo: the tooling a Zig project runs to keep its tree to its own rules. It lints Zig and
//! Markdown sources, scores cognitive complexity, lints commit messages, model-checks TLA+
//! specifications with TLC, builds Lean proofs with lake, and holds benchmark cases to the
//! instructions each operation takes. It is developer tooling: a project runs it from its build and
//! never links it into what it ships.

pub const lint = @import("lint/lint.zig");
pub const complexity = @import("complexity/complexity.zig");
pub const commit = @import("commit/commit.zig");
pub const tla = @import("tla/tla.zig");
pub const lean = @import("lean/lean.zig");
pub const instructions = @import("instructions/instructions.zig");
pub const report_line = @import("report_line.zig");

test {
    _ = lint;
    _ = complexity;
    _ = commit;
    _ = tla;
    _ = tla.header;
    _ = tla.models;
    _ = tla.tlc;
    _ = lean;
    _ = instructions;
    _ = report_line;
}
