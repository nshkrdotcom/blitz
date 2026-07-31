# Downstream Integration

Downstream repos should keep their local CI command stable and delegate the
selection logic to Blitz. During Blitz development, use a path dependency so the
downstream repo exercises the local Blitz checkout:

```elixir
defp deps do
  [
    {:blitz, path: "../blitz", runtime: false}
  ]
end
```

After the Blitz release is published, switch back to the Hex dependency:

```elixir
{:blitz, "~> 0.4.1", runtime: false}
```

## Repo-Local `mix ci`

Keep a repo-local Mix task when the downstream repo needs custom command mapping
or task ordering:

```elixir
defp aliases do
  [
    ci: ["workspace.impact.ci"],
    "ci.full": [
      "blitz.workspace deps_get",
      "blitz.workspace format --check-formatted",
      "blitz.workspace compile",
      "blitz.workspace test",
      "blitz.workspace credo --strict",
      "blitz.workspace dialyzer",
      "blitz.workspace docs"
    ]
  ]
end
```

The repo-local task should call `run_many!/3` for full CI pipelines so Blitz can
reuse one workspace snapshot and write a clean-pipeline manifest:

```elixir
Blitz.MixWorkspace.Impact.run_many!(
  workspace,
  [
    {:deps_get, []},
    {:format, ["--check-formatted"]},
    {:compile, []},
    {:test, []},
    {:credo, ["--strict"]},
    {:dialyzer, []},
    {:docs, []}
  ],
  opts
)
```

Do not use an impact-skippable `deps_get` result as the only bootstrap for a
workspace command. Fetched dependency trees are disposable checkout state:
they can be absent even when the dependency declaration and lockfile still
match a previously passing task-state hash. A root alias that must be
self-bootstrapping should run `blitz.workspace deps_get` unconditionally
before its impact-aware pipeline. Impact-aware `deps_get` remains useful only
after an independent bootstrap guarantee owns the physical dependency trees.

Use `command_mapper` when the downstream repo wraps `mix` with a script, env
shim, or another executable. Use `only_projects` when one CI stage must be split,
such as package tests first and the root test suite last.

When using a path dependency during Blitz development, make sure the downstream
task recompiles the local Blitz dependency when the sibling checkout changes.
Otherwise the downstream repo can execute stale BEAM files while the source
checkout and docs describe newer impact behavior.

## Validation Checklist

For a downstream target:

- `mix ci --dry-run` lists the expected seven task families.
- A first real `mix ci` writes `.blitz/test_state_v1/indexes/task_states.ndjson`,
  `baselines/current.json`, and a clean-pipeline manifest when the workspace is
  clean.
- A second `mix ci` on the same clean commit skips from the pipeline manifest.
- A second `mix ci --dry-run` skips exact passed states through the task-state
  indexes and skips unimpacted dirty states through the clean baseline; dry-run
  lines should show `source=exact_task_state` or `source=clean_baseline` as
  appropriate.
- A docs-only change selects docs work and skips unchanged compile/test states
  that already have passing coverage.
- A source change selects compile/test/credo/dialyzer/docs for the owning project
  and dependency-sensitive closure tasks for local dependents, while `deps_get`
  remains skipped unless dependency declarations changed.
- A child `mix.exs` change selects dependency-sensitive tasks for the owner and
  reverse local dependents, owner-only `format` and `credo`, and no unrelated
  projects.
- A workspace invalidator change, such as a shared dependency resolver file,
  selects the conservative workspace surface even when prior clean task-state
  coverage exists.
- Unlocked Git dependencies without matching `mix.lock` entries do not produce
  reusable deterministic skip evidence.
- `mix ci --force` selects all planned commands.
- `mix ci -j 1` never overlaps commands across task stages; larger limits
  preserve pipelining while bounding the aggregate in-flight count.
- `.blitz/test_state_v1` does not contain stale `results.ndjson`,
  `commits/`, or `output/` artifacts in the default compact retention mode.

Use `--store-dir` for repeatable local validation without polluting the default
store:

```bash
mix ci --dry-run --store-dir /tmp/blitz-test-state
mix ci --store-dir /tmp/blitz-test-state
mix ci --dry-run --store-dir /tmp/blitz-test-state
```
