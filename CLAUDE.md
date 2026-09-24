# pepegrillo rules

pepegrillo is the developer tooling a Zig 0.16 project runs from its build to hold its tree to its
own rules. It holds a lint engine with generic rules a project configures, a cognitive-complexity
scorer, a commit-message linter, a runner for TLA+ models under TLC, and a runner for Lean proofs
under lake. Home: github.com/c4milo/pepegrillo.

## What pepegrillo is

- **Generic engines, configured by the project.** A project states its settings as a comptime
  configuration: the directories a rule reads, the references it forbids, its thresholds, its
  commit scopes, and the documents a message cites. A rule only one project could want stays in
  that project, written against `lint.report`, `lint.ast`, `lint.paths` and `lint.harness`.
- **It names no project that uses it.** No project name appears in code, tests, fixtures, or
  documents. Fixtures use neutral names such as `src/store/page.zig`.
- **Developer tooling.** It reads the filesystem, runs git, TLC, lake and curl, and allocates from
  an arena. A project runs it from its build and never links it into what it ships.
- **One layout for formal specifications.** TLA+ models live in `spec/tla/<model>/` and a Lean
  project in `spec/lean/`, in every project that uses the `tla` and `lean` tools.
- **No dependencies.** The Zig standard library only.

## Behaviour is part of the interface

A project's configuration reproduces the verdicts its tree had before it adopted pepegrillo, and
keeps reproducing them across pepegrillo versions.

- A change that alters a verdict under an existing configuration is a breaking change: a new
  finding, a lost finding, a changed score, a changed exit status. Mark the commit subject with
  `!` and say which configurations it changes.
- A new check arrives switched off, so adopting it is the project's commit and not pepegrillo's.
- The report format is part of the interface too. Every tool prints a finding the way the Zig
  compiler prints an error, `path:line:column: error: [rule] message`, and leaves out the line and
  the column when a finding has none. `src/report_line.zig` writes it.

## Conventions

- Zig 0.16. Functions and variables are snake_case; types, and functions that return a type, are
  TitleCase.
- Names spell words out: `field_section_size`, not `fss`. One-letter names only for loop indices.
  `_len` counts bytes.
- Functions stay at cognitive complexity 15 or less, `test` blocks included, scored by pepegrillo's
  own scorer. Split the function; never raise the threshold.
- A hand-written file stays at or under 500 lines, its tests included. Split the file and name
  every piece after the file it came from: `markdown.zig` becomes `markdown_table.zig` and so on.
  Four or more files sharing a prefix move into a subdirectory named for it.
- Every limit is a named constant with a doc comment, near the top of the file that uses it.
- Tests live in the file they test, or in `<file>_test.zig` beside it when the file would pass 500
  lines.
- Operational errors — an unreadable file, a malformed argument, a limit reached — return error
  values. Assertions are for programmer error.
- Write prose in active voice with plain words: short sentences with one idea each, terms defined
  before use, and no metaphors. Name what literally happens.
- Every Markdown file is GitHub-flavored and renders on GitHub as written: real list markers,
  pipes inside a table cell escaped as `\|`, fenced code blocks with a language.

## Tests are proved by mutation

A test no mutation can fail is not a test. When you add or change a check, break it on purpose and
confirm a test fails. Report each mutation as `CAUGHT` or `NOT CAUGHT` in the commit body. A
`NOT CAUGHT` is a missing test.

## Commits

- A Conventional Commit: `type(scope)!: description`. The type is one of `feat`, `fix`, `docs`,
  `test`, `refactor`, `perf`, `build`, `ci`, `chore`. The scopes are `lint`, `complexity`,
  `commit`, `tla`, `lean`, `hooks` and `build`.
- The description is imperative, starts with a lowercase letter, has no final period, and the
  subject line stays at or under 72 columns.
- One blank line after the subject. A body line stays at or under 100 columns, and the body stays
  at or under 3 paragraphs and 100 words. The body says why.
- Stage by explicit path. `zig build test` passes before every commit.

## Layout

- `src/pepegrillo.zig` is the module a project imports: `lint`, `complexity`, `commit`, `tla`,
  `lean`, and `report_line`, the finding line every tool prints.
- `src/lint/` is the engine: `driver.zig`, `report.zig`, `scope.zig`, `paths.zig`, `text.zig`,
  `ast.zig`, `ast_read.zig`, `ast_scan.zig`, `names.zig`, `harness.zig`. `src/lint/rules/` holds
  the generic rules.
- `src/complexity/` is the cognitive-complexity scorer and its report.
- `src/commit/` is the commit-message linter.
- `src/tla/` runs TLC: `tla.zig` the tool, `tla_models.zig` where the configurations are,
  `tla_header.zig` what each one expects, `tla_tlc.zig` the jar, its pin and TLC's verdict.
- `src/lean/` runs lake over a project's Lean proofs.
- `hooks/pre-push` is the git hook a project installs.
- `tools/` holds pepegrillo's own configured entry points, which run pepegrillo over itself.

## Commands

- Test: `zig build test` runs the lint and the complexity score over pepegrillo itself, every unit
  test, and the format check.
- Commit messages: `zig build lint-commits` checks `origin/main..HEAD`; `zig build hooks` points
  this clone's `core.hooksPath` at `hooks/`.
- Format: `zig fmt --check build.zig src tools`.
