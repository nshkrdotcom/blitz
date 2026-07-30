# Impact CI

Blitz impact CI is a workspace execution layer that answers two questions before
running a command:

1. Has this exact task state already passed?
2. If the workspace is dirty, is this project/task still covered by the latest
   clean baseline because the current diff does not impact it?

The task state combines:

- workspace project composition
- the selected Mix task and command arguments
- command executable, cwd, and environment
- project file fingerprints
- local dependency fingerprints
- `mix.exs` and `mix.lock` content hashes
- Elixir, OTP, and Blitz versions

If the exact task state has a latest passed result, Blitz skips the command. If
the state is new, failed most recently, or `--force` is used, Blitz runs it and
persists the result.

Multi-stage callers should use `Blitz.MixWorkspace.Impact.run_many!/3`. It
builds the workspace snapshot once, applies each requested task against that
snapshot, and writes a clean baseline plus a clean-pipeline manifest after a
successful clean run. Execution is pipelined per project rather than
barriered per task family: a project's `test` command can start as soon as
that project's `compile` succeeded, while other projects are still
compiling. Each task family still respects its own configured concurrency. A later identical clean run can skip from that manifest
before project fingerprinting, which is the fastest path for repeated `mix ci`
checks. Dirty runs use the clean baseline to skip unimpacted project/task pairs.

## Commands

Run a single configured workspace task through the impact planner:

```bash
mix blitz.workspace.impact test
mix blitz.workspace.impact compile --dry-run
mix blitz.workspace.impact docs --base main --head HEAD
mix blitz.workspace.impact test --force
mix blitz.test_state.prune
```

Task arguments belong after `--`:

```bash
mix blitz.workspace.impact test --dry-run -- --seed 0
```

## Decisions

Each planned command receives one decision:

- `run`: no passed result exists for the exact task state, or the file change
  impacts the task and no exact passed result exists.
- `skip`: an exact passed task-state index exists, or the latest clean baseline
  covers an unimpacted dirty project/task state.
- `force_run`: `--force` was requested.

Decision maps include `coverage_source` so callers and tests can distinguish
`:exact_task_state`, `:clean_baseline`, `:impacted`, `:force`, and
`:missing_clean_baseline` without parsing dry-run output.

Dry-runs print every decision and a selected/skipped/total summary without
writing the store. Each line includes the machine-readable coverage source and
whether a matching clean baseline was available:

```text
Blitz impact dry-run
skip test apps/core 8df1c94a915a source=clean_baseline baseline=true clean baseline passed; not impacted
run docs apps/web f64f661313f2 source=impacted baseline=true changed apps/web/README.md
Blitz impact summary: selected=1 skipped=1 total=2
```

## Impact Rules

Git changes decide which tasks are considered impacted. Task-state hashes decide
whether impacted work has already been proven.

Current file classification:

- `mix.exs`: all known tasks
- `mix.lock`: `compile`, `test`, `dialyzer`, and `docs`; `deps_get` is not
  selected only because lockfile output changed
- Markdown, `docs/`, or `guides/`: `docs`
- `.formatter.exs`: `format`
- `.credo.exs`: `credo`
- files under `test/`: `format`, `test`, `credo`
- `.ex` or `.exs`: `format`, `compile`, `test`, `credo`, `dialyzer`, `docs`
- unknown files: all known tasks

Dependency-affecting source changes expand through reverse local dependency
closure for `compile`, `test`, `dialyzer`, and `docs`. `deps_get` uses
dependency declaration state instead, so it stays skipped for source-only edits
and reruns when `mix.exs` or dependency declarations change.

Workspace invalidators are treated conservatively. By default, root `mix.exs`,
`build_support/dependency_resolver.exs`, and
`build_support/workspace_contract.exs` select every configured project/task when
changed. These files are also fingerprinted into the workspace task state, so a
previously passed exact state cannot hide a changed resolver or workspace
contract.

## Seven-Stage CI

Blitz does not hardcode a universal CI pipeline. A downstream repo wires its own
pipeline by calling the impact runner for the task families it cares about. A
typical Mix monorepo pipeline is:

```elixir
[
  {:deps_get, []},
  {:format, ["--check-formatted"]},
  {:compile, []},
  {:test, []},
  {:credo, ["--strict"]},
  {:dialyzer, []},
  {:docs, []}
]
```

Downstream aliases can keep `mix ci` as the public command while delegating to a
repo-local task that invokes `Blitz.MixWorkspace.Impact.run_many!/3`.
