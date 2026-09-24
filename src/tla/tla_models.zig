//! Where the TLC configurations of a project are, and which specification each one checks.
//!
//! Every directory under the models directory is one model. Each `.cfg` file in it is one TLC
//! run, and so is each `.cfg` file in its `mutants/` subdirectory. A mutant is a configuration
//! that breaks one rule on purpose, so TLC must find a violation.
//!
//! The specification a configuration checks is the `.tla` file of its model directory whose name
//! is the longest prefix of the configuration's name: `Store_crash.cfg` checks `Store.tla`, and
//! `MCStore3.cfg` checks `MCStore.tla` rather than `Store.tla`. A mutant's name need not match
//! anything, and names its module in its header (`tla_header.zig`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The subdirectory of a model that holds its mutants.
pub const mutants_directory = "mutants";
const configuration_extension = ".cfg";
const specification_extension = ".tla";

/// Configurations one run reads before it stops with an error rather than a partial list.
pub const configurations_max: usize = 4096;

/// One TLC configuration.
pub const Configuration = struct {
    /// The model's directory, relative to the working directory. TLC runs there.
    model_directory: []const u8,
    /// The configuration's path relative to the model directory: `Store.cfg` or
    /// `mutants/skip_fsync.cfg`.
    relative_path: []const u8,
    /// Whether it sits in `mutants/`, which makes a violation its default expectation.
    is_mutant: bool,
};

/// Every configuration under `root`, model by model, in name order so a run reads the same way
/// on every host.
pub fn discover(arena: Allocator, io: Io, root: []const u8) ![]Configuration {
    var found: std.ArrayList(Configuration) = .empty;
    const models = try sorted_names(arena, io, root, .directory, "");
    for (models) |model| {
        const model_directory = try std.fs.path.join(arena, &.{ root, model });
        for (try sorted_names(arena, io, model_directory, .file, configuration_extension)) |name| {
            try append(arena, &found, .{ .model_directory = model_directory, .relative_path = name, .is_mutant = false });
        }
        const mutants = try std.fs.path.join(arena, &.{ model_directory, mutants_directory });
        for (try sorted_names(arena, io, mutants, .file, configuration_extension)) |name| {
            const relative_path = try std.fs.path.join(arena, &.{ mutants_directory, name });
            try append(arena, &found, .{ .model_directory = model_directory, .relative_path = relative_path, .is_mutant = true });
        }
    }
    return found.items;
}

fn append(arena: Allocator, found: *std.ArrayList(Configuration), configuration: Configuration) !void {
    if (found.items.len == configurations_max) return error.TooManyConfigurations;
    try found.append(arena, configuration);
}

/// The names of the entries of `kind` in `directory` that end in `extension`, sorted. A missing
/// directory has none.
fn sorted_names(arena: Allocator, io: Io, directory: []const u8, kind: Io.File.Kind, extension: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var dir = Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |failure| switch (failure) {
        error.FileNotFound => return names.items,
        else => return failure,
    };
    defer dir.close(io);
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != kind or !std.mem.endsWith(u8, entry.name, extension)) continue;
        if (names.items.len == configurations_max) return error.TooManyConfigurations;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, less_than);
    return names.items;
}

fn less_than(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

/// The configuration at `path`, which names it from the working directory: a model's own, such
/// as `spec/tla/store/Store.cfg`, or a mutant, such as `spec/tla/store/mutants/skip_fsync.cfg`.
pub fn from_path(arena: Allocator, path: []const u8) !Configuration {
    if (!std.mem.endsWith(u8, path, configuration_extension)) return error.NotAConfiguration;
    const parent = std.fs.path.dirname(path) orelse ".";
    const name = std.fs.path.basename(path);
    if (!std.mem.eql(u8, std.fs.path.basename(parent), mutants_directory)) {
        return .{ .model_directory = parent, .relative_path = name, .is_mutant = false };
    }
    return .{
        .model_directory = std.fs.path.dirname(parent) orelse ".",
        .relative_path = try std.fs.path.join(arena, &.{ mutants_directory, name }),
        .is_mutant = true,
    };
}

/// The module `configuration` checks when its header names none, or null when no `.tla` file of
/// its model directory has a name that prefixes the configuration's.
pub fn module_for(arena: Allocator, io: Io, configuration: Configuration) !?[]const u8 {
    const specifications = try sorted_names(arena, io, configuration.model_directory, .file, specification_extension);
    var stems: std.ArrayList([]const u8) = .empty;
    for (specifications) |name| try stems.append(arena, name[0 .. name.len - specification_extension.len]);
    const base = std.fs.path.basename(configuration.relative_path);
    return longest_prefix(stems.items, base[0 .. base.len - configuration_extension.len]);
}

/// The longest of `stems` that `name` starts with, or null.
pub fn longest_prefix(stems: []const []const u8, name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (stems) |stem| {
        if (!std.mem.startsWith(u8, name, stem)) continue;
        if (best == null or stem.len > best.?.len) best = stem;
    }
    return best;
}

// Tests.

const testing = std.testing;

test "longest_prefix picks the longest module name the configuration starts with" {
    const stems = [_][]const u8{ "Store", "MCStore", "Journal" };
    try testing.expectEqualStrings("Store", longest_prefix(&stems, "Store_crash").?);
    try testing.expectEqualStrings("MCStore", longest_prefix(&stems, "MCStore3").?);
    try testing.expectEqualStrings("MCStore", longest_prefix(&stems, "MCStore").?);
    try testing.expectEqual(null, longest_prefix(&stems, "skip_fsync"));
    try testing.expectEqual(null, longest_prefix(&stems, "Stor"));
    // Two names prefix it, and the longer is the module.
    const nested = [_][]const u8{ "StoreLog", "Store" };
    try testing.expectEqualStrings("StoreLog", longest_prefix(&nested, "StoreLog_torn").?);
    const reversed = [_][]const u8{ "Store", "StoreLog" };
    try testing.expectEqualStrings("StoreLog", longest_prefix(&reversed, "StoreLog_torn").?);
}

test "discover lists each model's configurations, then its mutants, and module_for names each module" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = [_][]const u8{
        "store/Store.tla",       "store/MCStore.tla",            "store/MCStore.cfg",
        "store/Store_crash.cfg", "store/mutants/skip_fsync.cfg", "store/README.md",
        "journal/Journal.tla",   "journal/Journal.cfg",
    };
    for (files) |path| {
        if (std.fs.path.dirname(path)) |parent| try tmp.dir.createDirPath(io, parent);
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "" });
    }
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const found = try discover(arena, io, root);
    // Models in name order, and a model's own configurations before its mutants.
    try testing.expectEqual(4, found.len);
    try testing.expectEqualStrings("Journal.cfg", found[0].relative_path);
    try testing.expectEqualStrings("MCStore.cfg", found[1].relative_path);
    try testing.expectEqualStrings("Store_crash.cfg", found[2].relative_path);
    try testing.expectEqualStrings("mutants/skip_fsync.cfg", found[3].relative_path);
    try testing.expect(found[3].is_mutant and !found[2].is_mutant);
    try testing.expect(std.mem.endsWith(u8, found[3].model_directory, "/store"));
    try testing.expectEqualStrings("MCStore", (try module_for(arena, io, found[1])).?);
    try testing.expectEqualStrings("Store", (try module_for(arena, io, found[2])).?);
    try testing.expectEqual(null, try module_for(arena, io, found[3]));
    // A models directory that does not exist holds no model.
    const missing = try std.fmt.allocPrint(arena, "{s}/none", .{root});
    try testing.expectEqual(0, (try discover(arena, io, missing)).len);
}

test "from_path splits a path into its model directory, and knows a mutant by its directory" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const own = try from_path(arena, "spec/tla/store/Store_crash.cfg");
    try testing.expectEqualStrings("spec/tla/store", own.model_directory);
    try testing.expectEqualStrings("Store_crash.cfg", own.relative_path);
    try testing.expect(!own.is_mutant);
    const mutant = try from_path(arena, "spec/tla/store/mutants/skip_fsync.cfg");
    try testing.expectEqualStrings("spec/tla/store", mutant.model_directory);
    try testing.expectEqualStrings("mutants/skip_fsync.cfg", mutant.relative_path);
    try testing.expect(mutant.is_mutant);
    try testing.expectError(error.NotAConfiguration, from_path(arena, "spec/tla/store/Store.tla"));
}
