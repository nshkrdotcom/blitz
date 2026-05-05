# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-05-05

### Added
- Added impact-aware `Blitz.MixWorkspace.Impact` planning and execution for
  task-state based workspace CI.
- Added `.blitz/test_state_v1` persistence with a compact exact task-state
  index for passed-result reuse.
- Added deterministic project, dependency, command, environment, and workspace
  hashing for Mix workspace tasks.
- Added `mix blitz.workspace.impact` for dry-runs, forced runs, and base/head
  change planning.
- Added `mix blitz.test_state.prune` for manual compact-store cleanup.
- Added clean-commit pipeline manifests for fast `run_many!` skips when an
  identical clean workspace CI pipeline has already passed.
- Added clean-baseline ledgers for baseline-aware dirty workspace planning.
- Added machine-readable decision coverage sources for exact task-state,
  clean-baseline, impacted, forced, and missing-baseline outcomes.
- Added unlocked Git dependency safeguards so unpinned Git dependencies without
  lockfile entries do not receive reusable deterministic skip evidence.
- Added guides for impact CI, persisted test state, and downstream integration.

### Changed
- Expanded HexDocs extras and package files to include the new guides.
- Changed default test-state retention from audit-style append streams to a
  compact local cache. Append-only `results.ndjson` and per-commit streams are
  now opt-in with `BLITZ_TEST_STATE_RETENTION=audit`.
- Changed `Blitz.MixWorkspace.Impact.run_many!/3` to snapshot workspace state
  once for the whole task list instead of replanning each task independently.
- Changed dirty-worktree planning to skip unimpacted project/task states when
  the current task state is covered by the latest clean baseline.
- Changed project dependency snapshots to include parsed `mix.lock` entries
  where available while still treating local path dependencies as source
  fingerprints.
- Changed `deps_get` task-state hashing to use dependency declaration state
  instead of dependency execution state, so local path dependency source edits do
  not force dependency fetches for reverse dependents.
- Changed dry-run baseline skip text to distinguish clean-baseline coverage from
  exact dirty-state memoization, including the coverage source and baseline
  availability for each decision.

### Fixed
- Ignored `.blitz/**` in git dirty-state, changed-file, and repo-file discovery
  so the test-state store cannot make itself look like impacted source input.
- Fixed `mix.lock` changes so lockfile output churn does not automatically
  select `deps_get`; dependency-sensitive tasks still rerun for the owning
  project and reverse local dependents.
- Fixed source-change impact planning so `deps_get` stays skipped unless a
  dependency declaration or project `mix.exs` changes.
- Fixed first dirty-run coverage for child README and source edits with root
  test splitting, including root projects that depend on child path packages.
- Fixed workspace invalidator handling so files such as
  `build_support/dependency_resolver.exs` and
  `build_support/workspace_contract.exs` are fingerprinted into the workspace
  task state and cannot be hidden by previously covered exact task states.

## [0.2.0] - 2026-04-07

### Changed
- Enriched `Blitz.Result` with bounded `output_tail`, explicit `failure_kind`,
  and structured failure metadata used by `Blitz.Error`.
- Reworked `Blitz.Error` to render actionable failure summaries with command,
  cwd, duration, reason, and a bounded output excerpt.
- Changed timeout handling to return structured timeout failures instead of
  exiting the caller process.

### Fixed
- Preserved the last output lines for failing commands so callers do not need a
  second repro to inspect the likely root cause.
- Reported worker crashes distinctly from normal non-zero command exits.

## [0.1.0] - 2026-03-19

### Added
- Initial release.
