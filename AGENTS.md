# Repository Guidelines

## Project Structure
- `lib/` contains Blitz runtime modules, Mix tasks, workspace planning, and test-state support.
- `test/` contains ExUnit coverage; env mutation belongs only in tests.
- `guides/`, `README.md`, and `CHANGELOG.md` must stay aligned with dependency-source and runtime-env behavior.
- `doc/` is generated output and should not be edited.

## Dependency Sources
- Dependency source selection is handled by `build_support/dependency_sources.exs` and `build_support/dependency_sources.config.exs`.
- Local dependency overrides use `.dependency_sources.local.exs`.
- Dependency source selection must not use environment variables.
- This repo has no internal dependency declarations today, so the config is intentionally empty.

## Runtime Env
- Runtime application code under `lib/**` must not call direct OS env APIs such as `System.get_env`, `System.fetch_env`, `System.put_env`, or `System.delete_env`.
- Workspace concurrency is explicit through `-j`, `--max-concurrency`, or `parallelism.max_concurrency`; do not add env-backed concurrency selection.
- Test-state store location and retention are explicit through options or Mix task flags such as `--store-dir` and `--retention`; do not add env-backed defaults.
- Library APIs receive explicit options, config structs, application config materialized by the top-level app, or caller-supplied env maps.
- Tests may manipulate env only for config-boundary or compatibility checks.

## Gates
- Run `mix format`.
- Run `mix compile --warnings-as-errors`.
- Run `mix test`.
- Run `mix credo --strict`.
- Run `mix dialyzer`.
- Run `mix docs --warnings-as-errors`.
