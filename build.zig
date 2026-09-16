//! Build graph for pepegrillo. It declares one module, `pepegrillo`, which a project imports into
//! its own tool entry points. When pepegrillo is built as a dependency, that module is all it
//! declares.
//!
//! Built as the root, it runs pepegrillo over itself: `zig build lint` scores cognitive
//! complexity and runs the lint rules of tools/lint.zig, `zig build test` runs the lint, every
//! unit test and the format check, `zig build lint-commits` checks the commit messages this branch
//! adds, and `zig build hooks` points this clone's core.hooksPath at hooks/. There are no
//! dependencies.
const std = @import("std");

/// CLAUDE.md, Conventions: the cognitive-complexity threshold. Never raised: a function over it is
/// split.
const cognitive_complexity_max = "15";

/// Every directory `zig build lint` scores and `zig build fmt` checks, beside build.zig itself.
const source_directories = [_][]const u8{ "src", "tools" };

/// Everything the lint rules read: the sources, the hook, and the documents.
const lint_paths = [_][]const u8{ "build.zig", "src", "tools", "hooks", "CLAUDE.md", "README.md" };

/// Every tool entry point whose own tests `zig build test` runs.
const tool_test_roots = [_][]const u8{
    "tools/lint.zig",
    "tools/cognitive_complexity.zig",
    "tools/commit_lint.zig",
};

/// The git revision range `zig build lint-commits` checks.
const commit_lint_range = "origin/main..HEAD";

/// The directory `zig build hooks` points this clone's core.hooksPath at.
const hooks_directory = "hooks";

pub fn build(b: *std.Build) void {
    const module = b.addModule("pepegrillo", .{
        .root_source_file = b.path("src/pepegrillo.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    // A project that depends on pepegrillo needs the module and nothing else.
    if (b.pkg_hash.len != 0) return;

    const test_step = b.step("test", "Run the lint, every unit test, and the format check");
    test_step.dependOn(add_lint_step(b, module));

    const unit_tests = b.addTest(.{ .name = "pepegrillo", .root_module = module });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    for (tool_test_roots) |root| {
        const tool_tests = b.addTest(.{
            .name = std.fs.path.stem(root),
            .root_module = tool_module(b, module, root),
        });
        test_step.dependOn(&b.addRunArtifact(tool_tests).step);
    }

    const fmt = b.addFmt(.{ .paths = &(.{"build.zig"} ++ source_directories), .check = true });
    test_step.dependOn(&fmt.step);
    b.step("fmt", "Check formatting of every Zig source").dependOn(&fmt.step);

    add_commit_lint_steps(b, module);
    add_hooks_step(b);
}

/// A module compiled for the build host in Debug that imports `pepegrillo`: every tool entry point.
fn tool_module(b: *std.Build, pepegrillo: *std.Build.Module, root: []const u8) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{.{ .name = "pepegrillo", .module = pepegrillo }},
    });
}

/// `zig build lint`: the cognitive-complexity score at the threshold of CLAUDE.md, then the lint
/// rules of tools/lint.zig.
fn add_lint_step(b: *std.Build, pepegrillo: *std.Build.Module) *std.Build.Step {
    const complexity = b.addExecutable(.{
        .name = "cognitive_complexity",
        .root_module = tool_module(b, pepegrillo, "tools/cognitive_complexity.zig"),
    });
    const complexity_run = b.addRunArtifact(complexity);
    complexity_run.addArgs(&.{ "--max", cognitive_complexity_max });
    complexity_run.addFileArg(b.path("build.zig"));
    for (source_directories) |directory| complexity_run.addDirectoryArg(b.path(directory));

    const lint = b.addExecutable(.{
        .name = "lint",
        .root_module = tool_module(b, pepegrillo, "tools/lint.zig"),
    });
    const lint_run = b.addRunArtifact(lint);
    for (lint_paths) |path| lint_run.addArg(path);
    lint_run.setCwd(b.path("."));
    lint_run.has_side_effects = true;
    lint_run.step.dependOn(&complexity_run.step);

    const lint_step = b.step("lint", "Score cognitive complexity, then run the lint rules");
    lint_step.dependOn(&lint_run.step);
    return lint_step;
}

/// `zig build lint-commits` checks `commit_lint_range`. `zig build install-commit-lint` installs
/// the linter alone to zig-out/bin, which hooks/pre-push runs when the binary is missing.
fn add_commit_lint_steps(b: *std.Build, pepegrillo: *std.Build.Module) void {
    const tool = b.addExecutable(.{
        .name = "commit_lint",
        .root_module = tool_module(b, pepegrillo, "tools/commit_lint.zig"),
    });
    const install = b.addInstallArtifact(tool, .{});
    b.getInstallStep().dependOn(&install.step);
    const install_step = b.step("install-commit-lint", "Install the commit-message linter alone");
    install_step.dependOn(&install.step);

    const run = b.addRunArtifact(tool);
    run.addArgs(&.{ "--range", commit_lint_range });
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    const step = b.step("lint-commits", "Check the commit messages of " ++ commit_lint_range);
    step.dependOn(&run.step);
}

/// `zig build hooks`: point this clone's core.hooksPath at hooks/, once after cloning.
fn add_hooks_step(b: *std.Build) void {
    const run = b.addSystemCommand(&.{ "git", "config", "core.hooksPath", hooks_directory });
    b.step("hooks", "Point this clone's core.hooksPath at " ++ hooks_directory).dependOn(&run.step);
}
