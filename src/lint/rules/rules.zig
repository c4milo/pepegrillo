//! The generic rules. Each is configured by the project that runs it: `Rule(config)` returns a type
//! with the `name` and `check` the driver dispatches to.

pub const forbidden_references = @import("forbidden_references.zig");
pub const file_length = @import("file_length.zig");
pub const magic_numbers = @import("magic_numbers.zig");
pub const denied_words = @import("denied_words.zig");
pub const unbounded_loop = @import("unbounded_loop.zig");
pub const relative_import = @import("relative_import.zig");
pub const defer_order = @import("defer_order.zig");
pub const unreleased_acquire = @import("unreleased_acquire.zig");
pub const markdown = @import("markdown.zig");
pub const static_alignment = @import("static_alignment.zig");

test {
    _ = forbidden_references;
    _ = file_length;
    _ = magic_numbers;
    _ = denied_words;
    _ = unbounded_loop;
    _ = relative_import;
    _ = defer_order;
    _ = unreleased_acquire;
    _ = markdown;
    _ = static_alignment;
}
