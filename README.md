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
- Ships a reusable `Blitz.MixWorkspace` layer for Mix monorepos
- Supports config-driven parallelism with task weights, auto machine scaling,
  optional pinned multipliers, and per-task overrides
- Keeps child projects isolated with per-project deps/build/lockfile/Hex paths

## Installation

Add `blitz` to your dependencies.

Default install:

```elixir
def deps do
  [
    {:blitz, "~> 0.2.0"}
  ]
end
```

Use this when your project is happy to treat `blitz` like a normal dependency.

Tooling-only install for monorepo roots, internal Mix tasks, or workspace
helpers:

```elixir
def deps do
  [
    {:blitz, "~> 0.2.0", runtime: false}
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
    version: "0.2.0",
    deps: deps(),
    dialyzer: dialyzer()
  ]
end

defp deps do
  [
    {:blitz, "~> 0.2.0", runtime: false}
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

## Mix Workspaces

`Blitz.MixWorkspace` moves the common Mix-monorepo concerns out of repo-local
wrapper code:

- project discovery
- per-task `mix` args
- preflight `deps.get` for projects that still need deps
- isolated `MIX_DEPS_PATH`, `MIX_BUILD_PATH`, `MIX_LOCKFILE`, and `HEX_HOME`
- task-specific env hooks
- configurable parallelism per task family

Configure it in your root `mix.exs`:

```elixir
def project do
  [
    app: :my_workspace,
    version: "0.2.0",
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
      env: "MY_WORKSPACE_MAX_CONCURRENCY",
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
{:blitz, "~> 0.2.0", runtime: false}
```

If that project also keeps a narrow Dialyzer PLT, add `:blitz` to
`plt_add_apps` as shown in the installation section above.

## Parallelism Model

`Blitz.MixWorkspace` keeps concurrency policy explicit and predictable.

The intended model is:

- `base` describes relative task weight
- `multiplier` describes machine size
- `overrides` handles exceptional tasks

If you omit `multiplier`, `Blitz` defaults to `:auto`.

Each workspace task gets one effective `max_concurrency` value. Resolution
order is:

1. `-j N` or `--max-concurrency N` on the current invocation
2. the configured environment override from `parallelism.env`
3. the per-task value in `parallelism.overrides`
4. `round(base * resolved_multiplier)` from `parallelism.base` and
   `parallelism.multiplier`
5. fallback `1` if the task has no configured base count

The formula is:

```text
resolved_multiplier =
  multiplier == :auto ? autodetect_multiplier() : multiplier

effective(task) =
  cli_override
  || env_override
  || per_task_override
  || round(base[task] * resolved_multiplier)
  || 1
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
  env: "MY_WORKSPACE_MAX_CONCURRENCY",
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
- `MY_WORKSPACE_MAX_CONCURRENCY=10 mix blitz.workspace test` uses `10`
- `mix blitz.workspace test -j 12` uses `12`

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

Task config keys:

- `args` is the child `mix` argv list, such as `["test"]` or
  `["compile", "--warnings-as-errors"]`.
- `mix_env` selects the isolated build-path suffix used for the task. Use
  `:inherit` to derive it from the current `MIX_ENV` or fall back to `dev`.
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

To override concurrency from the shell without changing `mix.exs`, set
`parallelism.env`:

```elixir
parallelism: [
  base: [test: 2, compile: 2],
  multiplier: :auto,
  env: "BLITZ_MAX_CONCURRENCY"
]
```

Then run with:

```bash
BLITZ_MAX_CONCURRENCY=8 mix blitz.workspace test
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
