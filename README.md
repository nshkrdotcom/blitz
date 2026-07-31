# Blitz

<p align="center">
  <img src="assets/blitz.svg" alt="Blitz logo" width="200" />
</p>

<p align="center">
  <a href="https://hex.pm/packages/blitz"><img src="https://img.shields.io/hexpm/v/blitz.svg" alt="Hex.pm Version" /></a>
  <a href="https://hexdocs.pm/blitz/"><img src="https://img.shields.io/badge/hex-docs-blue.svg" alt="HexDocs" /></a>
  <a href="https://github.com/nshkrdotcom/blitz"><img src="https://img.shields.io/badge/github-nshkrdotcom/blitz-8da0cb?style=flat&logo=github" alt="GitHub" /></a>
</p>

Parallel command runner for Elixir tooling and Mix workspaces.

`Blitz` has two layers:

- `Blitz.run/2` and `Blitz.run!/2` for low-level parallel command fanout
- `Blitz.MixWorkspace` for config-driven `mix` orchestration across many child
  projects

It stays intentionally local and predictable. `Blitz` is not a job system,
workflow engine, or distributed scheduler.

## Features

- Runs isolated OS commands concurrently with `Task.async_stream/3`
- Prefixes streamed output with a stable `id | ...` label
- Preserves input ordering in the returned result list
- Keeps a bounded per-command output tail for post-failure summaries
- Raises with actionable aggregated failure details in `run!/2`
- Distinguishes normal exits, startup errors, timeouts, and worker crashes
- Accepts per-command working directories and environment overrides
- Runs staged commands as per-id pipelines with `Blitz.run_stages/2` — no
  barriers between stages
- Ships a reusable `Blitz.MixWorkspace` layer for Mix monorepos
- Supports config-driven parallelism with task weights, auto machine scaling,
  optional pinned multipliers, and per-task overrides
- Rejects unknown workspace configuration keys instead of silently ignoring
  them
- Keeps child projects isolated with per-project deps/build/lockfile/Hex paths
- Persists impact-aware task state so unchanged exact states can be skipped
- Plans workspace CI from git changes, project fingerprints, dependency state,
  command state, and previously passed results
- Labels impact decisions with exact-state, clean-baseline, impacted, forced, or
  missing-baseline coverage sources
- Keeps the default test-state store compact and prunes stale local artifacts
- Reuses one workspace snapshot for multi-stage impact CI pipelines

## Installation

Add `blitz` to your dependencies.

Default install:

```elixir
def deps do
  [
    {:blitz, "~> 0.4.1"}
  ]
end
```

Use this when your project is happy to treat `blitz` like a normal dependency.

Tooling-only install for monorepo roots, internal Mix tasks, or workspace
helpers:

```elixir
def deps do
  [
    {:blitz, "~> 0.4.1", runtime: false}
  ]
end
```

Use `runtime: false` when `blitz` is only there to power tooling such as:

- `mix blitz.workspace ...`
- root-level Mix aliases
- custom Mix tasks
- repo-local helper modules that orchestrate child projects

This keeps `blitz` out of your runtime application startup while still making
its modules available to compile and run your tooling.

Do not automatically move `blitz` to `only: [:dev, :test]`.

That is usually too narrow for workspace tooling, because repo-level commands
such as CI, docs, compile, or Dialyzer may still need `blitz` outside a local
test-only flow. If your project uses `blitz` for root tooling, `runtime: false`
is usually the right default. Add `only: ...` only when you are certain the
dependency is never needed outside those environments.

### Dialyzer Note For Tooling-Only Installs

If you install `blitz` with `runtime: false` and your project keeps a narrow
Dialyzer PLT, you may need to add `:blitz` explicitly to `plt_add_apps`.

This commonly matters when your project:

- calls `Blitz` or `Blitz.MixWorkspace` directly from Mix tasks or helper modules
- uses `plt_add_deps: :apps_direct`
- uses a small explicit `plt_add_apps` list

Example:

```elixir
def project do
  [
    app: :my_workspace,
    version: "0.4.1",
    deps: deps(),
    dialyzer: dialyzer()
  ]
end

defp deps do
  [
    {:blitz, "~> 0.4.1", runtime: false}
  ]
end

defp dialyzer do
  [
    plt_add_deps: :apps_direct,
    plt_add_apps: [:mix, :blitz]
  ]
end
```

Why this is needed:

- `runtime: false` means `:blitz` is not treated as a runtime application
- a restricted PLT may therefore omit `:blitz`
- Dialyzer can then report `unknown_function` warnings for calls like
  `Blitz.MixWorkspace.root_dir/0`

If your Dialyzer setup already includes all needed deps or apps, no extra
configuration is required.

## Quick Start

Build command structs with `Blitz.command/1` and execute them with `Blitz.run/2`
or `Blitz.run!/2`.

```elixir
commands = [
  Blitz.command(id: "root", command: "mix", args: ["test"], cd: "/repo"),
  Blitz.command(id: "core/contracts", command: "mix", args: ["test"], cd: "/repo/core/contracts")
]

Blitz.run!(commands, max_concurrency: 2)
```

Each command streams output with a stable `id | ...` prefix and `run!/2` raises
with an actionable failure summary if any command fails.

For multi-stage work, `Blitz.run_stages/2` and `Blitz.run_stages!/2` run each
stage's commands under that stage's `max_concurrency` without a barrier between
stages: a command in a later stage starts as soon as every same-id command in
earlier stages has succeeded, even while other ids are still on earlier stages.
The aggregate in-flight count is also bounded by the largest stage
`max_concurrency`, so stages with a limit of `1` are globally serial.

```elixir
stages = [
  %{commands: compile_commands, max_concurrency: 4},
  %{commands: test_commands, max_concurrency: 4}
]

Blitz.run_stages!(stages)
```

A failed command permanently blocks same-id commands in later stages, and no
new commands launch after the first failure; in-flight commands finish and are
reported.

## Mix Workspaces

`Blitz.MixWorkspace` moves the common Mix-monorepo concerns out of repo-local
wrapper code:

- project discovery
- per-task `mix` args
- preflight `deps.get` for projects that still need deps
- isolated `MIX_DEPS_PATH`, `MIX_BUILD_PATH`, `MIX_LOCKFILE`, and `HEX_HOME`
- task-specific env hooks
- configurable parallelism per task family
- barrier-free staging: a project's task starts as soon as that project's
  preflight finished, even while other projects are still fetching deps

Configure it in your root `mix.exs`:

```elixir
def project do
  [
    app: :my_workspace,
    version: "0.4.1",
    deps: deps(),
    aliases: aliases(),
    blitz_workspace: blitz_workspace()
  ]
end

defp aliases do
  [
    "monorepo.test": ["blitz.workspace test"],
    "monorepo.compile": ["blitz.workspace compile"]
  ]
end

defp blitz_workspace do
  [
    root: __DIR__,
    projects: [".", "apps/*", "libs/*"],
    parallelism: [
      base: [deps_get: 3, format: 4, compile: 2, test: 2],
      multiplier: :auto,
      overrides: [dialyzer: 1]
    ],
    tasks: [
      deps_get: [args: ["deps.get"], preflight?: false],
      format: [args: ["format"]],
      compile: [args: ["compile", "--warnings-as-errors"]],
      test: [args: ["test"], mix_env: "test", color: true]
    ]
  ]
end
```

Then run:

```bash
mix blitz.workspace test
mix blitz.workspace test -j 6
mix blitz.workspace test -- --seed 0
mix monorepo.test
mix monorepo.test --seed 0
mix monorepo.test -j 6
```

`color: true` injects `--color` for tasks that support it, which restores ANSI
output such as the normal ExUnit colors from `mix test`.

For tooling-root workspaces, the most common dependency shape is:

```elixir
{:blitz, "~> 0.4.1", runtime: false}
```

If that project also keeps a narrow Dialyzer PLT, add `:blitz` to
`plt_add_apps` as shown in the installation section above.

## Impact-Aware CI

`Blitz.MixWorkspace.Impact` adds a deterministic test-state layer on top of the
normal workspace planner. It fingerprints each project, local dependency edges,
`mix.lock` content, the command/environment, workspace configuration, Elixir/OTP,
and the Blitz version. A command is skipped when that exact task state has a
latest passed result, or when a dirty workspace change does not impact that
project/task and the current state is covered by the latest clean baseline.

Persisted state defaults to:

```text
.blitz/test_state_v1
```

Pass `--store-dir` when CI should read/write a shared cache volume. The default
store is compact: it keeps exact task-state indexes, a current clean baseline,
and clean-pipeline manifests. It prunes stale local artifacts after successful
multi-stage runs.

Use audit retention only when you need append-only result streams:

```bash
mix blitz.workspace.impact test --retention audit
```

Run a dry plan:

```bash
mix blitz.workspace.impact test --dry-run
mix blitz.workspace.impact compile --base main --head HEAD
mix blitz.workspace.impact docs --force
mix blitz.test_state.prune
```

Task-specific arguments should be passed after `--`:

```bash
mix blitz.workspace.impact test --dry-run -- --seed 0
```

Impact-aware execution is memoization of verified task states, not a build cache.
If the project files, dependency state, lockfile content, command, environment,
workspace configuration, configured workspace invalidator files, Elixir/OTP, or
Blitz version changes, the task state changes and the command runs again unless
that exact state has already passed.
For multi-stage callers using `Blitz.MixWorkspace.Impact.run_many!/3`, a clean
workspace writes a clean baseline ledger and can also skip from a pipeline
manifest before rebuilding every project fingerprint. Dirty workspaces use the
baseline ledger plus the current git diff to avoid rerunning unimpacted
project/task pairs. Decision records expose whether a skip came from an exact
passed task state or the clean baseline, so downstream tests can assert the
first dirty run without parsing terminal text.

See the guides for the full design:

- [Impact CI](guides/impact_ci.md)
- [Test State](guides/test_state.md)
- [Downstream Integration](guides/downstream_integration.md)

## Parallelism Model

`Blitz.MixWorkspace` keeps concurrency policy explicit and predictable.

The intended model is:

- `base` describes relative task weight
- `multiplier` describes machine size
- `overrides` handles exceptional tasks

If you omit `multiplier`, `Blitz` defaults to `:auto`.

Each workspace task gets one effective `max_concurrency` value:

1. `-j N` or `--max-concurrency N` explicitly pins every stage to `N`.
2. Otherwise, `parallelism.overrides[task]` or
   `round(parallelism.base[task] * resolved_multiplier)` supplies the
   task-specific limit.
3. `parallelism.max_concurrency` bounds that task-specific value and supplies
   the default for a task without one.
4. A task with no configured limit falls back to `1`.

Across a pipelined run, the largest effective stage limit is also the aggregate
in-flight command limit. Thus `-j 1` is genuinely serial even though later
stages are eligible to start without a barrier.

The formula is:

```text
resolved_multiplier =
  multiplier == :auto ? autodetect_multiplier() : multiplier

task_limit =
  per_task_override
  || round(base[task] * resolved_multiplier)

effective(task) =
  cli_override
  || min_if_both_present(workspace_max_concurrency, task_limit)
  || workspace_max_concurrency
  || task_limit
  || 1

aggregate_limit = max(effective(stage.task) for stage in planned_stages)
```

`autodetect_multiplier()` uses the lower of a CPU class and a memory class:

- CPU classes: `8 => 2`, `16 => 3`, `24 => 4`, `32 => 6`
- Memory classes: `16 GiB => 2`, `48 GiB => 3`, `96 GiB => 4`, `192 GiB => 6`

That keeps auto-scaling simple and legible:

- a machine with more schedulers but not enough RAM does not get an inflated
  multiplier
- a machine with lots of RAM but modest CPU does not scale only on memory

Example with a pinned multiplier:

```elixir
parallelism: [
  max_concurrency: nil,
  multiplier: 2,
  base: [
    deps_get: 3,
    format: 4,
    compile: 2,
    test: 2,
    credo: 2,
    dialyzer: 1,
    docs: 1
  ],
  overrides: []
]
```

That produces these defaults:

```text
deps_get = 6
format   = 8
compile  = 4
test     = 4
credo    = 4
dialyzer = 2
docs     = 2
```

Then:

- `mix blitz.workspace test` uses `4`
- `parallelism.max_concurrency: 3` bounds the test task at `3`
- `parallelism.max_concurrency: 10` leaves the task-specific value at `4`
- `mix blitz.workspace test -j 12` explicitly uses `12`

Example with auto mode:

```elixir
parallelism: [
  base: [
    deps_get: 3,
    format: 4,
    compile: 2,
    test: 2,
    credo: 2,
    dialyzer: 1,
    docs: 1
  ],
  multiplier: :auto
]
```

On a machine with `24` schedulers and `160 GiB` RAM, `autodetect_multiplier()`
returns `4`, so that same policy becomes:

```text
deps_get = 12
format   = 16
compile  = 8
test     = 8
credo    = 8
dialyzer = 4
docs     = 4
```

`Blitz` does not hardcode task-family counts. The library provides the auto
machine scaler and the precedence rules; your workspace still owns the task
weights. If you want a fixed policy, pin `multiplier` to a number in
`mix.exs`.

Why not make every task flat by default? Because the base counts are meant to
describe task weight, while the multiplier describes machine size. In most
workspaces:

- `deps.get` and `format` are relatively cheap
- `compile`, `test`, and `credo` already create meaningful CPU, IO, or service
  pressure on their own
- `dialyzer` and `docs` are usually the heaviest on memory and code loading

You can absolutely choose a flatter policy for a stronger machine. `Blitz`
does not prevent that. The defaults simply encode that these task families are
not equal in cost.

Workspace config keys:

- `root` sets the workspace root. It defaults to the current directory.
- `projects` is an ordered list of literal paths and glob patterns. Only entries
  containing a `mix.exs` file are included.
- `tasks` defines the named workspace tasks that `mix blitz.workspace <task>`
  can run.
- `parallelism` configures computed concurrency per task family.
- `isolation` controls which child-project paths and env vars are isolated.

Unknown keys in `blitz_workspace`, `parallelism`, `isolation`, or a task config
raise a configuration error that lists the supported keys, so a misspelled key
cannot silently degrade the workspace (for example to concurrency `1`).

Task config keys:

- `args` is the child `mix` argv list, such as `["test"]` or
  `["compile", "--warnings-as-errors"]`.
- `mix_env` selects the isolated build-path suffix used for the task. Use
  `:inherit` to derive it from the current `Mix.env()`.
- `color: true` injects `--color` unless `--color` or `--no-color` is already
  present in the extra args.
- `preflight?` controls whether the task first runs `deps.get` for projects that
  have a `mix.lock` but no `deps` directory. It defaults to `true` for normal
  tasks and `false` for `deps_get`.
- `env` adds task-specific environment overrides via a callback. Use it for
  values such as `MIX_ENV`, database names, or credentials.

`env` callbacks may be provided as:

- `fn context -> ... end`
- `{Module, :function}`
- `{Module, :function, extra_args}`

The callback receives a context map with:

- `:project_path`
- `:project_root`
- `:root`
- `:task`
- `:task_config`

Example task env hook:

```elixir
defp blitz_workspace do
  [
    root: __DIR__,
    projects: [".", "apps/*"],
    tasks: [
      deps_get: [args: ["deps.get"], preflight?: false],
      test: [
        args: ["test"],
        mix_env: "test",
        color: true,
        env: &test_database_env/1
      ]
    ]
  ]
end

defp test_database_env(%{project_path: project_path}) do
  [
    {"PGDATABASE",
     Blitz.MixWorkspace.hashed_project_name("my_workspace_test", project_path)}
  ]
end
```

Isolation defaults:

- `MIX_DEPS_PATH` => `<project>/deps`
- `MIX_BUILD_PATH` => `<project>/_build/<mix_env>`
- `MIX_LOCKFILE` => `<project>/mix.lock`
- `HEX_HOME` => `<project>/_build/hex`
- `HEX_API_KEY` is unset by default

Override or disable them with `isolation`:

```elixir
blitz_workspace: [
  root: __DIR__,
  projects: [".", "apps/*"],
  isolation: [
    deps_path: true,
    build_path: true,
    lockfile: true,
    hex_home: "_build/hex",
    unset_env: ["HEX_API_KEY", "AWS_SESSION_TOKEN"]
  ],
  tasks: [
    deps_get: [args: ["deps.get"], preflight?: false],
    test: [args: ["test"], mix_env: "test", color: true]
  ]
]
```

To set a workspace ceiling and a default for tasks without weights, configure
`parallelism.max_concurrency`. To explicitly pin every stage for one
invocation, pass `-j`/`--max-concurrency`:

```elixir
parallelism: [
  base: [test: 2, compile: 2],
  multiplier: :auto,
  max_concurrency: 8
]
```

Then run with:

```bash
mix blitz.workspace test
mix blitz.workspace test -j 12
```

## Example Output

```text
==> root: mix test
==> core/contracts: mix test
root | ...
core/contracts | ...
<== core/contracts: ok in 241ms
<== root: ok in 613ms
```

## Command Shape

`Blitz.command/1` accepts a map or keyword list with these fields:

- `:id` - required stable label for logs and results
- `:command` - required executable name or absolute path
- `:args` - optional list of CLI arguments
- `:cd` - optional working directory
- `:env` - optional environment overrides as a keyword list or map

Example with environment overrides:

```elixir
command =
  Blitz.command(
    id: "lint",
    command: "mix",
    args: ["format", "--check-formatted"],
    cd: "/workspace/apps/core",
    env: %{"MIX_ENV" => "test", "CI" => "true"}
  )
```

## Run Options

`Blitz.run/2` and `Blitz.run!/2` accept these options:

- `:max_concurrency` - defaults to `System.schedulers_online()`
- `:announce?` - prints start and completion lines when `true`
- `:prefix_output?` - prefixes command output lines when `true`
- `:timeout` - per-task timeout passed to `Task.async_stream/3`; timed-out
  tasks are killed and reported as structured timeout failures

## Return Values

`Blitz.run/2` returns:

```elixir
{:ok, [%Blitz.Result{}, ...]}
```

on success, or:

```elixir
{:error, %Blitz.Error{}}
```

when one or more commands fail.

Each `Blitz.Result` contains:

- `id`
- `command`
- `args`
- `cd`
- `exit_code`
- `duration_ms`
- `output_tail`
- `failure_kind`
- `failure_reason`

Results are returned in the same order as the input command list even though the
commands themselves run concurrently.

`output_tail` keeps the last 50 rendered lines for that command without storing
the full log in memory.

`failure_kind` is `nil` for success and one of:

- `:exit`
- `:startup_error`
- `:timeout`
- `:worker_crash`

`exit_code` is only set for normal process exits. The other failure kinds carry
their detail in `failure_reason`.

## Failure Handling

Use `run/2` when your caller wants to branch on success or failure:

```elixir
case Blitz.run(commands, max_concurrency: 4) do
  {:ok, results} ->
    IO.inspect(results, label: "parallel run complete")

  {:error, error} ->
    IO.puts(Exception.message(error))
end
```

Use `run!/2` when failure should stop execution immediately:

```elixir
Blitz.run!(commands, max_concurrency: 4, timeout: 30_000)
```

Example raised message:

```text
parallel command run failed:

  core/dispatch_runtime
    exit: 1
    cwd: /repo/core/dispatch_runtime
    cmd: mix compile --warnings-as-errors
    duration: 2143ms
    output tail:
      ** (Mix) Can't continue due to errors on dependencies
      Dependencies have diverged:
      * libgraph ...
```

## Typical Use Cases

- Running `mix test` across multiple umbrella children or sibling repos
- Fanning out format, lint, or docs generation tasks in internal tooling
- Building lightweight orchestration around shell scripts without introducing a job system
- Keeping monorepo command output readable during local development or CI

## Design Notes

- Output is streamed as commands run instead of buffered until completion
- Failures are aggregated into a single `Blitz.Error` structure with bounded
  excerpts for each failing command
- Missing executables, timeouts, and worker crashes are reported distinctly
  from normal non-zero exits
- Per-command `cd` and `env` values keep tasks isolated from each other
- `Blitz.MixWorkspace` keeps repo-specific policy in `mix.exs`, not in bespoke
  runner modules

## Development

```bash
mix test
mix credo --strict
mix dialyzer
```

## License

`Blitz` is released under the MIT License. See [LICENSE](LICENSE).
