# Move to the API of 2026-11-07

The owner ruled on 2026-11-07 that pepegrillo's API follows TigerStyle first, then Zig 0.16's
standard library (`docs/api.md`). Seven findings of the API audit changed names and signatures
in one set of breaking commits. This page lists each change, so that a project moves in one pass.

No verdict changes. Each tool prints the same lines and exits with the same status. A
configuration or a call that names an old name does not compile, and the compile error names the
old name.

Do these steps in order:

1. Pin the new commit with `zig fetch --save=pepegrillo git+https://github.com/c4milo/pepegrillo#<commit>`.
2. Confirm that `.lazy = true` is still set in `build.zig.zon`.
3. Rename each old name in the tables below.
4. Change each signature in the sections below.
5. Run `zig build test`.

## 1. Names that left a file namespace

Each root exports names, and not files. `lint` keeps five file namespaces: `lint.report`,
`lint.paths`, `lint.ast`, `lint.harness` and `lint.rules.<rule>`.

| Old name | New name |
| --- | --- |
| `lint.driver.Linter` | `lint.Linter` |
| `lint.driver.Run` | removed: use the `Linter(rules)` value (section 3) |
| `lint.driver.Options` | `lint.Linter(rules).Options` |
| `lint.driver.ArgumentError` | `lint.Linter(rules).ArgumentError` |
| `lint.driver.exit_status(count, errors)` | `linter.exit_status()` |
| `lint.scope.Scope` | `lint.Scope` |
| `lint.ast_scan.<name>` | `lint.ast.<name>` |
| `lint.text.Line` | `lint.Line` |
| `lint.text.LineIterator` | `lint.LineIterator` |
| `lint.text.count_lines` | `lint.count_lines` |
| `lint.text.is_word_byte` | `lint.is_word_byte` |
| `lint.names.assert_all_resolve` | `lint.assert_all_resolve` |
| `lint.names.assert_all_match` | `lint.assert_all_match` |
| `lint.names.resolves`, `lint.names.matches` | removed |
| `lint.rules.forbidden_references.ParameterTypes` | `lint.ast.ParameterTypes` |
| `lint.rules.magic_numbers.ParameterTypes` | `lint.ast.ParameterTypes` |
| `complexity.scorer.<name>`, `complexity.report.<name>` | `complexity.<name>` |
| `complexity.report.paths` | `lint.paths` |
| `commit.config.Config` | `commit.Config` |
| `commit.config.invalid_reason(&config)` | `commit.check_config(config)` |
| `commit.config.default_commit_types` | `commit.commit_types_default` |
| `commit.config.default_trailer_keys` | `commit.trailer_keys_default` |
| `commit.findings.Finding` | `commit.Finding` |
| `commit.findings.Findings` | `commit.Findings` |
| `commit.arguments`, `commit.git_log`, `commit.message`, `commit.rules`, `commit.subject` | removed |
| `commit.exit_status`, `commit.range_command` | removed |
| `tla.tlc.states_path` | `tla.states_path` |
| `tla.header`, `tla.models`, `tla.tlc`, `tla.matches` | removed |
| `lean.toolchain_file`, `lean.lake_candidates`, `lean.status_of` | removed |
| `instructions.baseline`, `instructions.cachegrind`, `instructions.measure` | removed |
| `checkfree.assembly`, `checkfree.report` | removed |

`complexity` exports `FunctionScore`, `ScoreError`, `score_source`, `functions_per_file_max`,
`tree_depth_max`, `Options`, `Report`, `parse_arguments`, `print_report`, `score_max_default`,
`source_len_max`, `exit_usage` and `main`. The other names of its two files are removed.

## 2. Qualifier last

A limit puts its qualifier last, and pepegrillo's unit for a size in bytes is `_len`.

| Old name | New name |
| --- | --- |
| `commit.Config.max_subject_columns` | `subject_columns_max` |
| `commit.Config.max_body_columns` | `body_columns_max` |
| `commit.Config.max_body_paragraphs` | `body_paragraphs_max` |
| `commit.Config.max_body_words` | `body_words_max` |
| `commit.Config.max_trailing_blank_lines` | `trailing_blank_lines_max` |
| `commit.Config.max_findings` | `findings_max` |
| `commit.Config.max_message_lines` | `message_lines_max` |
| `commit.Config.max_commits_per_run` | `commits_per_run_max` |
| `commit.Config.max_message_bytes` | `message_len_max` |
| `commit.Config.max_git_output_bytes` | `git_output_len_max` |
| `commit.Findings.max_findings` | `commit.Findings.findings_max` |
| `lint.rules.file_length.Config.max_lines` | `lines_max` |
| `lint.rules.file_length.default_max_lines` | `lines_max_default` |
| `lint.rules.magic_numbers.Config.largest_allowed_literal` | `literal_max` |
| `lint.rules.magic_numbers.default_largest_allowed_literal` | `literal_max_default` |
| `lint.rules.relative_import.max_resolved_segments` | `resolved_segments_max` |
| `lint.rules.static_alignment.max_type_depth` | `type_depth_max` |
| `lint.rules.unreleased_acquire.default_release_prefixes` | `release_prefixes_default` |
| `lint.rules.unreleased_acquire.default_release_suffixes` | `release_suffixes_default` |
| `lint.rules.unreleased_acquire.max_registered_defers` | `registered_defers_max` |
| `lint.rules.unbounded_loop.default_length_reader_names` | `length_reader_names_default` |
| `lint.report.max_findings` | `findings_max` |
| `lint.report.max_file_bytes` | `file_len_max` |
| `lint.ast.max_tree_depth` | `tree_depth_max` |
| `lint.ast.max_chain_bytes` | `chain_len_max` |
| `lint.ast.max_deferred_identifiers` | `deferred_identifiers_max` |
| `lint.driver.max_rules`, `lint.driver.max_path_bytes` | removed with `lint.driver` |
| `complexity.default_max_score` | `score_max_default` |
| `complexity.max_source_bytes` | `source_len_max` |
| `complexity.max_functions_per_file` | `functions_per_file_max` |
| `complexity.max_tree_depth` | `tree_depth_max` |
| `complexity.Options.max_score` | `complexity.Options.score_max` |

The flag `--max` of the complexity tool does not change.

## 3. The lint driver

`Linter(rules)` holds the state of one run, and `Run` is removed. `Options.enabled` holds
`rules.len` entries in place of 32.

```zig
// Before.
var run: pepegrillo.lint.driver.Run = .{ .context = context, .enabled = options.enabled };
try Linter.dispatch(&run, file);
try Linter.lint_path(&run, path);

// After.
var linter: Linter = .{ .context = context, .enabled = options.enabled };
try linter.dispatch(&file);
try linter.lint_path(path);
```

`Linter.walk_directory` is removed: `lint_path` walks a directory.

## 4. A rule's check and its findings

| Old signature | New signature |
| --- | --- |
| `check(context: *report.Context, file: report.File) !void` | `check(context: *report.Context, file: *const report.File) !void` |
| `findings.add(rule, path, line, column, format, arguments)` | `findings.add(path, line, column, rule, format, arguments)` |
| `context.read_file(path) ?[:0]u8` | `context.read_file(path) Io.Dir.ReadFileAllocError![:0]u8` |
| `report_line.write(out, location, severity, rule, ...)` | `report_line.write(out, &location, severity, rule, ...)` |

A rule that reads a second file writes `context.read_file(path) catch` in place of
`context.read_file(path) orelse`. A missing file is `error.FileNotFound`.

## 5. The commit linter's severity

`commit.Severity` is removed, and `commit` uses `report_line.Severity`.

| Old | New |
| --- | --- |
| `commit.Severity` | `pepegrillo.report_line.Severity` |
| `.violation` | `.@"error"` |
| `finding.severity.text()` returns `violation` | returns `error` |
| `Severity.line_severity()` | removed: the severity is the line's severity |
| `findings.record(severity, source, rule, ...)` | `findings.record(source, severity, rule, ...)` |
| `findings.count_violations()` | `findings.count_errors()` |

A configuration that sets `.unknown_scope_severity = .violation` sets `.@"error"`.

## 6. One entry shape for five tools

`tla`, `lean`, `instructions`, `checkfree` and `commit` share one entry shape and one context,
`pepegrillo.Context`, which holds `arena`, `io`, `environ`, `out` and `errors`.

```zig
pub fn check_config(comptime project: Config) ?[]const u8
pub fn run(context: *const pepegrillo.Context, comptime project: Config, given: []const []const u8) !u8
pub fn main(init: std.process.Init, comptime project: Config) !void
```

| Old call | New call |
| --- | --- |
| `tla.Context` | `pepegrillo.Context` |
| `tla.run(context, project, given)` | `tla.run(&context, project, given)` |
| `tla.verified_jar(context, project)` | `tla.verified_jar(&context, project)` |
| `lean.run(arena, io, environ, project, errors)` | `lean.run(&context, project, &.{})` |
| `instructions.Context` | `pepegrillo.Context`, with `environ` |
| `instructions.start(context, project, given)` | `instructions.run(&context, project, given)` |
| `instructions.run(context, project, counter, invocation)` | removed |
| `instructions.parse_arguments`, `instructions.Invocation` | removed |
| `checkfree.run(arena, io, project, given, out, errors)` | `checkfree.run(&context, project, given)` |
| `commit.run(arena, io, project, given, out, errors)` | `commit.run(&context, project, given)` |
| `commit.config.invalid_reason(&project)` | `commit.check_config(project)` |

`tla.check_config` is public, and `lean.check_config` is new. `lean.check_config` refuses an
empty `directory` and an empty `lake_arguments` at compile time. `lean.run` reads no argument.

A project that builds a context for `lean.run` writes:

```zig
const context: pepegrillo.Context = .{
    .arena = arena,
    .io = init.io,
    .environ = init.environ_map,
    .out = &out.interface,
    .errors = &errors.interface,
};
const status = try pepegrillo.lean.run(&context, proofs, &.{});
```

## 7. The guide step

`add_guide_step` in pepegrillo's `build.zig` adds the `guide` step to a project's build. The step
installs `docs/performance/` and `docs/api.md` to `zig-out/docs/`. A project can replace its own
guide step with it (README.md, Guides). Its own step keeps working, and installs no `api.md`.
