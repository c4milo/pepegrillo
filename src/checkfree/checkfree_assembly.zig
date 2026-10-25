//! Reads the assembly LLVM writes for an object, `-femit-asm`, and counts the safety check sites
//! a function reaches.
//!
//! A ReleaseSafe build keeps Zig's safety checks. Each check that can fail calls a panic function,
//! such as `debug.FullPanic(...).outOfBounds`, so each call or branch to a panic is one check site.
//! The count covers a function and every function it reaches by a call or a tail branch, but not
//! the panic functions themselves.
//!
//! An exported symbol is a label of its own, or an alias of the function that holds it:
//! `name = function`. The reader takes both, for the symbols that start with a prefix.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// An exported symbol and the function that holds it.
pub const Symbol = struct { name: []const u8, root: []const u8 };

/// One file of assembly: its exported symbols, and each function's calls and branches to symbols.
pub const Assembly = struct {
    symbols: std.ArrayList(Symbol) = .empty,
    targets: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,
};

/// The mnemonics that call a symbol or branch to it: x86-64's and aarch64's.
const mnemonics = [_][]const u8{ "call", "jmp", "bl", "b" };

/// The prefix of an assembler's local label: a block inside a function, never a function.
const local_prefix = ".L";

/// The suffix x86-64 adds to a call through the procedure linkage table.
const plt_suffix = "@PLT";

/// The text between an alias's name and the symbol it names.
const alias_separator = " = ";

/// The name of a function that starts at this line, or null.
pub fn label_of(line: []const u8) ?[]const u8 {
    if (line.len == 0 or std.mem.indexOfScalar(u8, " \t.#", line[0]) != null) return null;
    if (line[0] == '"') {
        const close = std.mem.indexOfScalarPos(u8, line, 1, '"') orelse return null;
        if (close + 1 >= line.len or line[close + 1] != ':') return null;
        return line[1..close];
    }
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    if (std.mem.indexOfAny(u8, line[0..colon], " \t") != null) return null;
    return line[0..colon];
}

/// The exported symbol this line aliases, or null.
pub fn alias_of(line: []const u8, prefix: []const u8) ?Symbol {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const separator = std.mem.indexOf(u8, line, alias_separator) orelse return null;
    const root = std.mem.trim(u8, line[separator + alias_separator.len ..], " \t\"");
    return .{ .name = line[0..separator], .root = root };
}

/// The symbol this line calls or branches to, or null for any other line and for a local label.
pub fn target_of(line: []const u8) ?[]const u8 {
    if (line.len == 0 or line[0] != '\t') return null;
    const text = std.mem.trim(u8, line, " \t");
    const space = std.mem.indexOfAny(u8, text, " \t") orelse return null;
    if (!is_one_of(text[0..space], &mnemonics)) return null;
    var name = std.mem.trim(u8, text[space..], " \t\"");
    if (std.mem.endsWith(u8, name, plt_suffix)) name = name[0 .. name.len - plt_suffix.len];
    if (name.len == 0 or std.mem.startsWith(u8, name, local_prefix)) return null;
    return name;
}

fn is_one_of(word: []const u8, words: []const []const u8) bool {
    for (words) |each| {
        if (std.mem.eql(u8, word, each)) return true;
    }
    return false;
}

/// Reads one file of assembly, taking the exported symbols that start with `prefix`. The slices
/// point into `text`.
pub fn parse(arena: Allocator, text: []const u8, prefix: []const u8) !Assembly {
    var assembly: Assembly = .{};
    var function: ?*std.ArrayList([]const u8) = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (alias_of(line, prefix)) |symbol| {
            try assembly.symbols.append(arena, symbol);
        } else if (label_of(line)) |name| {
            if (std.mem.startsWith(u8, name, prefix)) try assembly.symbols.append(arena, .{ .name = name, .root = name });
            const entry = try assembly.targets.getOrPut(arena, name);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            function = entry.value_ptr;
        } else if (target_of(line)) |target| {
            if (function) |targets| try targets.append(arena, target);
        }
    }
    return assembly;
}

/// Whether a symbol is a panic function.
pub fn is_panic(name: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(name, "panic") != null;
}

/// The check sites of the function `root` and of every function it reaches. A panic function
/// whose name ends with one of `excluded` is not counted.
pub fn count(arena: Allocator, assembly: *const Assembly, root: []const u8, excluded: []const []const u8) !u32 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    try stack.append(arena, root);
    var found: u32 = 0;
    while (stack.pop()) |function| {
        if ((try seen.getOrPut(arena, function)).found_existing) continue;
        const targets = assembly.targets.get(function) orelse continue;
        for (targets.items) |target| {
            if (!is_panic(target)) {
                try stack.append(arena, target);
            } else if (!ends_with_one_of(target, excluded)) {
                found += 1;
            }
        }
    }
    return found;
}

fn ends_with_one_of(name: []const u8, suffixes: []const []const u8) bool {
    for (suffixes) |suffix| {
        if (std.mem.endsWith(u8, name, suffix)) return true;
    }
    return false;
}

// Tests.

const testing = std.testing;

test "label_of takes a function's name, quoted or not, and refuses other lines" {
    try testing.expectEqualStrings("scan.plain_len", label_of("scan.plain_len:                # @scan.plain_len").?);
    try testing.expectEqualStrings("a.Folding(b,8).update", label_of("\"a.Folding(b,8).update\":").?);
    try testing.expectEqual(null, label_of(".LBB0_4:"));
    try testing.expectEqual(null, label_of("\tmovq\t%rax, %rbx"));
    try testing.expectEqual(null, label_of("lib_a = b"));
    try testing.expectEqual(null, label_of(""));
}

test "alias_of takes an exported alias and the function it names" {
    const symbol = alias_of("lib_hex_len_avx2 = variants.scan.hex_len", "lib_").?;
    try testing.expectEqualStrings("lib_hex_len_avx2", symbol.name);
    try testing.expectEqualStrings("variants.scan.hex_len", symbol.root);
    try testing.expectEqual(null, alias_of("variants.scan.hex_len:", "lib_"));
    try testing.expectEqual(null, alias_of("\t.globl\tlib_hex_len_avx2", "lib_"));
    try testing.expectEqual(null, alias_of("other_hex_len = variants.scan.hex_len", "lib_"));
}

test "target_of takes a call or a branch to a symbol, on both architectures" {
    const panic = "debug.FullPanic((function 'defaultPanic')).outOfBounds";
    try testing.expectEqualStrings(panic, target_of("\tcall\t\"" ++ panic ++ "\"").?);
    try testing.expectEqualStrings("variants.crc.combined", target_of("\tb\tvariants.crc.combined").?);
    try testing.expectEqualStrings("memcpy", target_of("\tcall\tmemcpy@PLT").?);
    try testing.expectEqualStrings("scan.copy", target_of("\tbl\tscan.copy").?);
    try testing.expectEqual(null, target_of("\tjmp\t.LBB3_7"));
    try testing.expectEqual(null, target_of("\tb.ne\t.LBB3_7"));
    try testing.expectEqual(null, target_of("\tjne\tscan.copy"));
    try testing.expectEqual(null, target_of("\tmovq\t%rax, %rbx"));
}

/// Assembly in the shape LLVM writes it, for the tests of this file and of `checkfree.zig`.
pub const sample =
    "kernel.root:                            # @kernel.root\n" ++
    "\tcmpq\t%rsi, %rdi\n" ++
    "\tjb\t.LBB0_2\n" ++
    "\tcall\t\"debug.FullPanic((function 'defaultPanic')).outOfBounds\"\n" ++
    ".LBB0_2:\n" ++
    "\tcall\t\"debug.FullPanic((function 'defaultPanic')).reachedUnreachable\"\n" ++
    "\tcall\tkernel.helper\n" ++
    "\tcall\tmemcpy@PLT\n" ++
    "\tjmp\t\"kernel.tail(8)\"\n" ++
    "kernel.helper:\n" ++
    "\tbl\t\"debug.FullPanic((function 'defaultPanic')).integerOverflow\"\n" ++
    "\tb\tkernel.root\n" ++
    "\"kernel.tail(8)\":\n" ++
    "\tbl\t\"debug.FullPanic((function 'defaultPanic')).startGreaterThanEnd\"\n" ++
    "\tb\t\"debug.FullPanic((function 'defaultPanic')).outOfBounds\"\n" ++
    "kernel.other:\n" ++
    "\tcall\t\"debug.FullPanic((function 'defaultPanic')).outOfBounds\"\n" ++
    "lib_direct:\n" ++
    "\tcall\tkernel.other\n" ++
    "lib_kernel_avx2 = kernel.root\n";

/// The panic function a failed assertion calls, which the tests leave out.
const assertion = [_][]const u8{".reachedUnreachable"};

test "parse takes an alias and a label with the prefix as exported symbols" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const assembly = try parse(arena_state.allocator(), sample, "lib_");
    try testing.expectEqual(2, assembly.symbols.items.len);
    try testing.expectEqualStrings("lib_direct", assembly.symbols.items[0].root);
    try testing.expectEqualStrings("lib_kernel_avx2", assembly.symbols.items[1].name);
    try testing.expectEqualStrings("kernel.root", assembly.symbols.items[1].root);
}

test "count takes each reached call or branch to a panic, and no excluded one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const assembly = try parse(arena, sample, "lib_");
    // The root's bounds check, the helper's overflow and the tail's two; the helper's branch back
    // to the root ends the walk there.
    try testing.expectEqual(4, try count(arena, &assembly, "kernel.root", &assertion));
    try testing.expectEqual(5, try count(arena, &assembly, "kernel.root", &.{}));
    try testing.expectEqual(2, try count(arena, &assembly, "kernel.tail(8)", &assertion));
    try testing.expectEqual(1, try count(arena, &assembly, "lib_direct", &assertion));
    try testing.expectEqual(0, try count(arena, &assembly, "absent", &assertion));
}
