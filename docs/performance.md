# Performance work

The method moved to the folder [`docs/performance/`](performance/performance.md).
`performance.md` holds its six steps, `performance_hardware.md` step 4's rules for the hardware,
and `performance_zig.md` what Zig 0.16 does to hot code.

A project whose `zig build guide` installs this file installs only this page. Install the folder
instead:

```zig
step.dependOn(&b.addInstallDirectory(.{
    .source_dir = pepegrillo.path("docs/performance"),
    .install_dir = .prefix,
    .install_subdir = "docs/performance",
}).step);
```

This page stays until every project installs the folder.
