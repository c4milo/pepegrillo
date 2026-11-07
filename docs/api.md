# Public API

This guide holds the rules for the public API of a Zig 0.16 project that uses pepegrillo. It is
for anyone, person or agent, who adds a name that a dependent can call. Each project can keep its
own decisions beside it, and each decision names its reason.

## 1. What a public API is

A public API is each name that a dependent calls or names: a type, a function, a constant, a
field, an error, and the parameters of each function. A dependent is a program or a library
that imports the project as a package.

- A name that a dependent can reach is public, whether you meant it or not.
- A dependent builds against each public name. When you remove or rename one, you break the
  dependent.
- Decide each public name before you write the code that serves it.

## 2. The order of authority

Three sources decide the shape of a public API. Apply them in this order:

1. TigerStyle, which is TigerBeetle's
   [`docs/TIGER_STYLE.md`](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).
   It decides first, because the projects that use pepegrillo follow it in all their code.
2. The idioms of the Zig 0.16 standard library, where TigerStyle says nothing. A Zig programmer
   knows these idioms, so an API that follows them does not surprise that programmer.
3. A project decision, where the first two say nothing or where the project must depart from them.
   The decision names its reason. Section 5 tells how to record it.

When TigerStyle and std disagree, TigerStyle wins. For example, std names a function in
camelCase, as `std.mem.readInt`. TigerStyle names it in snake_case, so the project writes
`read_int`.

The sections below cite TigerStyle by its section names, and std by its file and line under
`lib/zig/std` of Zig 0.16.0. `zig env` prints the `std_dir` of a local install.

## 3. TigerStyle rules that shape an API

### 3.1 Names

TigerStyle, "Naming Things": use `snake_case` for functions, variables and files. For other
names, TigerStyle follows the Zig style guide: a type is `TitleCase`, and a function that returns
a type is `TitleCase` too.

```zig
pub const Page = struct { size_bytes: u32 };

pub fn Ring(comptime capacity: u32) type {
    return struct { items: [capacity]u32 };
}

pub fn page_count(size_bytes: u64, page_size_bytes: u64) u64 {
    return @divExact(size_bytes, page_size_bytes);
}
```

### 3.2 Units and qualifiers last in a name

TigerStyle, "Naming Things": put the unit or the qualifier last, in descending significance. Write
`latency_ms_max`, not `max_latency_ms`. The related names then line up, and `latency_ms_min` goes
next to `latency_ms_max`.

TigerStyle gives no list of suffixes. This guide uses these:

- Write `_ns`, `_ms` or `_s` for a time.
- Write `_bytes` or `_len` for a size in bytes, as the project defines it.
- Write `_count` for a count, and `_max` or `_min` for a limit.

### 3.3 Static allocation and storage the caller owns

TigerStyle, "Safety": allocate all memory at startup, and allocate nothing after
initialization. For an API, no function of a type allocates after `init`. TigerStyle's own `init`
in "Naming Things" takes an allocator, so `init` can allocate.

This guide adds a second rule, which TigerStyle does not state: where it can, the caller owns the
storage. The type states the bytes it needs as a constant, or as a pure function of its options.
The caller passes that storage in, and so decides where each byte lives. A type that allocates in
`init` instead frees that memory in `deinit` (section 4.3).

```zig
pub fn Queue(comptime capacity: u32) type {
    return struct {
        items: [capacity]u64 = undefined,
        count: u32 = 0,

        pub const size_bytes = @sizeOf(@This());
    };
}
```

### 3.4 Initialization in place

TigerStyle, "Cache Invalidation": construct a larger struct in place, through an out pointer. The
value then does not move, and the stack holds no second copy.

```zig
pub const Table = struct {
    rows: [4096]u64,
    count: u32,

    pub fn init(table: *Table) void {
        table.* = .{ .rows = @splat(0), .count = 0 };
    }
};
```

### 3.5 `*const` for an argument over 16 bytes

TigerStyle, "Cache Invalidation": pass an argument over 16 bytes as `*const`, unless you mean the
callee to receive a copy. The caller then makes no copy on the stack by accident. Section 4.2 tells
what a function does with such a pointer after it returns.

### 3.6 Options in a struct

TigerStyle, "Naming Things": use an options struct where two arguments can change places. A
function that takes two `u64` values must take an options struct.

TigerStyle, "Safety": a caller passes each option at the call site, and does not rely on a default.
A default can change, and the caller does not see the change.

### 3.7 Limits as named constants

TigerStyle, "Safety": put a limit on everything.

This guide adds the form of a public limit, which TigerStyle does not state. A public limit is a
named constant with a doc comment, such as `entries_max`. A dependent then sizes its own storage
from the same constant.

### 3.8 Assertions

TigerStyle, "Safety": assert the arguments, the return value, the preconditions, the
postconditions and the invariants of each function. Assert the positive space and the negative
space. An assertion is for a programmer error. An error that a dependent must handle is a return
value (section 4.5).

### 3.9 Simple types

- TigerStyle, "Safety": use a type of an explicit size, such as `u32`, in place of `usize`.
- TigerStyle, "Cache Invalidation": prefer the simplest return type. `void` is simpler than
  `bool`, `bool` is simpler than `u64`, `u64` is simpler than `?u64`, and `?u64` is simpler than
  `!u64`.
- TigerStyle, "Naming Things": put a callback last in the parameters.

## 4. Standard library idioms where TigerStyle states no rule

TigerStyle states no rule for the idioms below. Section 4.3 tells where TigerStyle uses an idiom
in an example. Each idiom gives a std example, then a wrong form and a right form.

### 4.1 A generic type is named for the thing

std names a function that returns a type for the type it returns:

- `std.ArrayList(T)`, at `std.zig:49`.
- `std.HashMap(K, V, ...)`, at `hash_map.zig:135`.
- `std.StaticBitSet(size)`, at `bit_set.zig:43`, which takes a capacity and not a type.

Do not add a suffix such as `Of` that tells the reader the name takes a parameter. The call already
shows it.

Wrong:

```zig
pub fn RingOf(comptime capacity: u32) type {
    return struct { items: [capacity]u32 };
}
```

Right:

```zig
pub fn Ring(comptime capacity: u32) type {
    return struct { items: [capacity]u32 };
}
```

The lint rule `type_function_suffix` finds the wrong form.

### 4.2 Options are copied, and no pointer to them is kept

std takes options by value, and keeps no pointer to them after the call:

- `std.Thread.SpawnConfig`, at `Thread.zig:298`, which `std.Thread.spawn` takes at
  `Thread.zig:344`.
- `std.json.ParseOptions`, at `json/static.zig:19`, which `std.json.parseFromSlice` takes at
  `json/static.zig:73`.

TigerStyle asks for `*const` when the options are over 16 bytes (section 3.5). Use both rules:
take `*const`, and copy what the value keeps.

When `init` keeps the pointer, the caller must keep the options alive for the life of the value.
No type states that rule, so the compiler cannot check it.

The options in the examples below hold 24 bytes, so TigerStyle asks for `*const`.

Wrong:

```zig
pub const Options = struct {
    entries_max: u32,
    retries_max: u32,
    timeout_ms: u64,
    interval_ms: u64,
};

pub const Cache = struct {
    options: *const Options,

    pub fn init(cache: *Cache, options: *const Options) void {
        cache.* = .{ .options = options };
    }
};
```

Right:

```zig
pub const Options = struct {
    entries_max: u32,
    retries_max: u32,
    timeout_ms: u64,
    interval_ms: u64,
};

pub const Cache = struct {
    options: Options,

    pub fn init(cache: *Cache, options: *const Options) void {
        cache.* = .{ .options = options.* };
    }
};
```

std gives most fields of an options struct a default. Here TigerStyle wins: the caller passes
each field at the call site (section 3.6).

Some pointers are meant to be kept, such as a pointer to a vtable or to a function. The lint
rule `kept_options_pointer` finds the wrong form, and its `kept_types` setting names the types a
value may keep.

### 4.3 `init` and `deinit` are a pair

TigerStyle uses `init` in its examples in "Naming Things" and "Cache Invalidation". It names
`deinit` in "Naming Things", but it states no rule for the pair.

std names the function that makes a value `init`, and the function that releases what it holds
`deinit`. `std.heap.ArenaAllocator` has both, at `heap/ArenaAllocator.zig:46` and `:51`.

A type that holds nothing to release has no `deinit`. `std.heap.FixedBufferAllocator`, at
`heap/FixedBufferAllocator.zig:11`, has none.

The example below allocates in `init`, as TigerStyle's own `init` does (section 3.3).

Wrong:

```zig
pub const Log = struct {
    entries: []u64,

    pub fn create(gpa: std.mem.Allocator, entries_max: u32) error{OutOfMemory}!Log {
        return .{ .entries = try gpa.alloc(u64, entries_max) };
    }

    pub fn destroy(log: *Log, gpa: std.mem.Allocator) void {
        gpa.free(log.entries);
        log.* = undefined;
    }
};

const std = @import("std");
```

Right:

```zig
pub const Log = struct {
    entries: []u64,

    pub fn init(gpa: std.mem.Allocator, entries_max: u32) error{OutOfMemory}!Log {
        return .{ .entries = try gpa.alloc(u64, entries_max) };
    }

    pub fn deinit(log: *Log, gpa: std.mem.Allocator) void {
        gpa.free(log.entries);
        log.* = undefined;
    }
};

const std = @import("std");
```

### 4.4 An iterator's `next` returns `?T`

std gives an iterator a `next` function that returns `null` after the last item:
`std.mem.SplitIterator.next`, at `mem.zig:3387`. A caller then writes `while (it.next()) |item|`.

Wrong:

```zig
pub const Entries = struct {
    items: []const u32,
    index: u32 = 0,

    pub fn has_next(entries: *const Entries) bool {
        return entries.index < entries.items.len;
    }

    pub fn get_next(entries: *Entries) u32 {
        defer entries.index += 1;
        return entries.items[entries.index];
    }
};
```

Right:

```zig
pub const Entries = struct {
    items: []const u32,
    index: u32 = 0,

    pub fn next(entries: *Entries) ?u32 {
        if (entries.index < entries.items.len) {
            defer entries.index += 1;
            return entries.items[entries.index];
        }
        return null;
    }
};
```

### 4.5 An error set is named and small

std names each error set and lists only the errors a function can return:
`std.fmt.ParseIntError` at `fmt.zig:299`, which `std.fmt.parseInt` returns at `fmt.zig:317`.
A dependent can then handle each error with a `switch` that the compiler checks. `anyerror` in a
public signature hides the errors, so the dependent cannot handle each one.

Wrong:

```zig
pub fn parse_port(text: []const u8) anyerror!u16 {
    return std.fmt.parseInt(u16, text, 10);
}

const std = @import("std");
```

Right:

```zig
pub const ParsePortError = error{ Overflow, InvalidCharacter };

pub fn parse_port(text: []const u8) ParsePortError!u16 {
    return std.fmt.parseInt(u16, text, 10);
}

const std = @import("std");
```

### 4.6 An enum in place of a `bool` parameter

std passes a choice as an enum: `std.mem.readInt` takes a `std.builtin.Endian` at `mem.zig:1894`,
and `std.builtin.Endian` is at `builtin.zig:845`. The call site then names the choice. A `true` at
the call site does not tell the reader what it means.

Wrong:

```zig
pub fn read_length(bytes: *const [4]u8, big_endian: bool) u32 {
    const endian: std.builtin.Endian = if (big_endian) .big else .little;
    return std.mem.readInt(u32, bytes, endian);
}

const std = @import("std");
```

Right:

```zig
pub fn read_length(bytes: *const [4]u8, endian: std.builtin.Endian) u32 {
    return std.mem.readInt(u32, bytes, endian);
}

const std = @import("std");
```

### 4.7 A slice in place of a pointer and a length

std takes a slice, which holds its length: `std.mem.eql`, at `mem.zig:732`. With a slice, the
length cannot disagree with the pointer, and a safe build checks each index.

Wrong:

```zig
pub fn checksum(bytes: [*]const u8, bytes_len: u32) u32 {
    var sum: u32 = 0;
    for (bytes[0..bytes_len]) |byte| sum +%= byte;
    return sum;
}
```

Right:

```zig
pub fn checksum(bytes: []const u8) u32 {
    var sum: u32 = 0;
    for (bytes) |byte| sum +%= byte;
    return sum;
}
```

### 4.8 An optional for "nothing", not a sentinel

std returns `null` when there is no result: `std.mem.findScalar` returns `?usize`, at
`mem.zig:1219`. A sentinel such as `maxInt(u32)` is a value that the type permits, so the compiler
does not make the caller check for it.

TigerStyle prefers `u64` to `?u64` (section 3.9). Return a plain value when each call has a
result. Return an optional when a call can have no result.

Wrong:

```zig
pub const not_found: u32 = std.math.maxInt(u32);

pub fn find_slot(keys: []const u64, key: u64) u32 {
    for (keys, 0..) |candidate, index| {
        if (candidate == key) return @intCast(index);
    }
    return not_found;
}

const std = @import("std");
```

Right:

```zig
pub fn find_slot(keys: []const u64, key: u64) ?u32 {
    for (keys, 0..) |candidate, index| {
        if (candidate == key) return @intCast(index);
    }
    return null;
}
```

### 4.9 `std.Io.Reader` and `std.Io.Writer` for a stream

std writes to a stream through `*std.Io.Writer` and reads from one through `*std.Io.Reader`:

- `std.Io.Writer.writeAll`, at `Io/Writer.zig:549`.
- `std.Io.Reader.takeInt`, at `Io/Reader.zig:1169`.
- `std.json.Stringify.value`, at `json/Stringify.zig:573`.

A type that reads or writes a stream takes one of these. A caller then gives it a file, a socket
or a fixed buffer. `std.Io.Writer.fixed`, at `Io/Writer.zig:125`, writes into storage the caller
owns.

This idiom is for a stream. A type that reads one bounded message from bytes the caller already
holds takes a slice (section 4.7).

Wrong:

```zig
pub const Record = struct {
    key: u64,

    pub fn write(record: *const Record, out: []u8, out_len: *u32) void {
        std.mem.writeInt(u64, out[0..8], record.key, .little);
        out_len.* = 8;
    }
};

const std = @import("std");
```

Right:

```zig
pub const Record = struct {
    key: u64,

    pub fn write(record: *const Record, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeInt(u64, record.key, .little);
    }
};

const std = @import("std");
```

## 5. How to record a departure

A project can depart from TigerStyle or from std when it has a reason. Record each departure:

1. Write a numbered decision in the project's decisions document. Name the rule that you depart
   from, by its TigerStyle section or its std file and line. Name the reason, and the
   alternatives that the decision rejected.
2. Put a doc comment on the public declaration that departs. Cite the decision by its number.
3. When a lint rule reports the declaration, change the rule's configuration, and put a comment
   on the change that cites the decision:
   - When the rule has a setting for the case, use it, such as `kept_types` for a kept pointer.
   - Otherwise, exclude the path in the rule's `scope`. The rule then reads nothing in that file,
     so keep the file small.

```zig
/// Decision 12: the type keeps a pointer to its options, because one options value serves
/// every connection of a process and a copy costs 4 KiB for each one.
pub const Connection = struct {
    options: *const Options,
};

pub const Options = struct { table: [4096]u8 };
```

A departure without a decision is a defect. Fix the code, or write the decision.

## 6. Lint rules for this guide

pepegrillo holds two generic lint rules for this guide. Each one arrives switched off, so a
project turns it on in its own lint entry point.

- `type_function_suffix` reports a `pub` function that returns `type` and whose name ends with a
  configured suffix, `Of` by default (section 4.1).
- `kept_options_pointer` reports a `pub` function named `init`, or another configured name, that
  stores a `*const` parameter, or the address of a field of one, in a field of an out parameter
  or of the struct it returns (section 4.2). It does not report a `comptime` parameter, a pointer
  to a function, or a pointer to a type that `kept_types` names.

```zig
const rules = @import("pepegrillo").lint.rules;

pub const type_function_suffix = rules.type_function_suffix.Rule(.{
    .name = "type-function-suffix",
    .scope = .{ .extensions = &.{".zig"}, .include_directories = &.{"src"} },
    .suffixes = &.{"Of"},
});

pub const kept_options_pointer = rules.kept_options_pointer.Rule(.{
    .name = "kept-options-pointer",
    .scope = .{ .extensions = &.{".zig"}, .include_directories = &.{"src"} },
    .function_names = &.{"init"},
    .kept_types = &.{"VTable"},
});
```

Each rule reads syntax. The doc comment at the top of each rule's file tells what it does not see.
