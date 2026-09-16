//! pepegrillo: the tooling a Zig project runs to keep its tree to its own rules. It lints Zig and
//! Markdown sources, scores cognitive complexity, and lints commit messages. It is developer
//! tooling: a project runs it from its build and never links it into what it ships.

pub const lint = @import("lint/lint.zig");
pub const complexity = @import("complexity/complexity.zig");
pub const commit = @import("commit/commit.zig");

test {
    _ = lint;
    _ = complexity;
    _ = commit;
}
