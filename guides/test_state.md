# Test State

Blitz persists task-state evidence under `.blitz/test_state_v1` by default. Pass
`--store-dir` to place it on a CI cache volume.

The default store is intentionally compact:

- `indexes/task_states.ndjson`: latest result and latest passed result per
  task-state hash
- `baselines/current.json`: the latest clean passing baseline for dirty
  workspace reuse
- `manifests/<hash>.json`: clean-pipeline pass manifests for `run_many!`

The task-state index handles exact dirty-state memoization. The clean baseline
lets a dirty workspace skip unimpacted project/task states that were proven by
the latest clean run. Pipeline manifests allow a clean workspace to skip a
previously passed multi-stage CI pipeline before rebuilding every project
fingerprint.

Exact dirty-state memoization is separate from clean-baseline coverage. A first
dirty run from a fresh clean baseline must use the clean baseline for
unimpacted work; exact dirty-state skips are valid only after that dirty command
has passed once.

Append-only audit streams are opt-in:

```bash
mix blitz.workspace.impact test --retention audit
```

Audit retention writes:

- `results.ndjson`: append-only command result records
- `commits/<commit>.ndjson`: per-commit result streams when a commit is known
- `indexes/by_task_state/<hash>.json`: one JSON index per task state

Compact retention is the default for local `.blitz` stores because stale history
is not needed to answer whether the current exact state may skip.

## What Gets Hashed

Each task-state hash includes:

- `workspace_state_hash`: project paths, task config, isolation config,
  parallelism config, Elixir version, OTP version, and Blitz version
- `project_task_hash`: project files relevant to the task, local dependency
  state, and dependency closure where applicable
- `command_hash`: executable, args, cwd, and command environment hash

Project fingerprints include `mix.exs` and `mix.lock` content hashes. Blitz also
parses `mix.lock` as local dependency metadata when possible, so Hex and Git
lock entries contribute to dependency state. If parsing fails, the file content
hash still participates in task hashes.

## Does `mix.lock` Suffice?

A `mix.lock` content hash is sufficient for Hex and pinned Git dependency
resolution state because it changes when Mix writes a different resolved
dependency entry. It also captures resolved versions and checksums for each
project that owns its own lockfile.

It is not sufficient by itself for path dependencies. Path dependencies can
change without changing the caller's `mix.lock`, so Blitz also fingerprints
local path dependency source state when the path resolves inside the workspace.
That source state participates in dependency-sensitive execution tasks such as
`compile`, `test`, `dialyzer`, and `docs`. `deps_get` uses a narrower dependency
declaration hash built from `mix.exs` declarations and path dependency `mix.exs`
state, so ordinary path dependency source edits do not refetch dependencies.

It is also not sufficient for unpinned Git dependencies unless the lockfile has
already been refreshed to the exact commit that was tested. The tested state must
therefore include the lockfile content hash, and CI should run from a checked-in
or otherwise preserved lockfile. When a Git dependency has no lockfile entry,
Blitz treats that dependency as unsafe for reuse and gives dependency-sensitive
task states non-reusable evidence rather than allowing deterministic skips.

## When State Is Written

Blitz writes state after command execution:

- passing commands update the task-state index and `latest_passed_result_id`
- failing commands replace the task-state index with a failed latest result
- successful `run_many!` pipelines write a clean-pipeline manifest when the
  workspace is clean
- successful clean `run_many!` pipelines write `baselines/current.json`
- dry-runs do not write

A later command skips only when `latest_passed_result_id` is present for the
exact task state. A newer failed result for the same state removes skip
eligibility until that state passes again.

Compact pruning runs after successful execution. It removes default-stale
artifacts such as append streams and commit streams, keeps the current clean
baseline, and `run_many!` also prunes task-state indexes down to the current
pipeline surface. You can run the cleanup manually:

Workspace invalidator files are part of the workspace state fingerprint. The
default invalidators are root `mix.exs`, `.mix_workspace_ops/sources.tsv`,
`build_support/dependency_resolver.exs`, and
`build_support/workspace_contract.exs`, plus any downstream paths provided in
`:workspace_invalidators`. If one of these files changes, old exact task-state
coverage no longer matches and the configured impact policy can rerun the
workspace conservatively.

```bash
mix blitz.test_state.prune
mix blitz.test_state.prune --store-dir /tmp/blitz-test-state
```

## Memoization Semantics

The store is memoization of verified command outcomes. It is not a replacement
for Mix compilation artifacts, Dialyzer PLTs, dependency caches, or docs output.

The skipped unit is:

```text
workspace + project + task + command + env + dependency state + relevant files
```

Any change to that unit creates a different hash. Reverting to a previously
tested state can skip immediately because the exact passed hash is already in
the store.

For dependency-affecting files such as `mix.exs`, Blitz uses the current
workspace graph to select owner plus reverse local dependents for
dependency-sensitive tasks. Owner-only tasks such as `format` and `credo` remain
limited to the changed project unless policy expands them.
