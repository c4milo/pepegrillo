# Performance work

The method moved to the folder [`docs/performance/`](performance/performance.md).
`performance.md` holds its six steps, `performance_hardware.md` step 4's rules for the hardware,
and `performance_zig.md` what Zig 0.16 does to hot code.

A project whose `zig build guide` installs this file installs only this page. Add the step with
`add_guide_step` from pepegrillo's `build.zig` instead, which installs the folder and
`docs/api.md` (README.md, Guides):

```zig
const pepegrillo_build = b.lazyImport(@This(), "pepegrillo") orelse return;
pepegrillo_build.add_guide_step(b, pepegrillo);
```

This page stays until every project installs the folder.
