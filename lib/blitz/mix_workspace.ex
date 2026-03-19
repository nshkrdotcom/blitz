defmodule Blitz.MixWorkspace do
  @moduledoc """
  Config-driven runner for Mix-oriented multi-project workspaces.

  Workspace configuration lives in the root project's `mix.exs` under the
  `:blitz_workspace` key. `Blitz.MixWorkspace` expands the configured project
  patterns, builds isolated child `mix` commands, and runs staged workspace
  tasks through `Blitz`.

  Parallelism stays workspace-owned:

  - `base` config describes task weight
  - `multiplier` describes machine size
  - `:auto` multiplier mode scales from local schedulers and memory
  - per-task overrides and CLI `-j` still take precedence when present
  """

  alias Blitz.Command

  @type task_name :: atom()
  @type workspace_config :: keyword() | map()
  @type runner_args :: [String.t()]

  @type stage :: %{
          task: task_name(),
          commands: [Command.t()],
          max_concurrency: pos_integer()
        }

  @default_isolation %{
    deps_path: true,
    build_path: true,
    lockfile: true,
    hex_home: "_build/hex",
    unset_env: ["HEX_API_KEY"]
  }

  @default_parallelism %{
    base: %{},
    env: nil,
    multiplier: :auto,
    overrides: %{}
  }

  @gib 1_073_741_824

  @doc """
  Loads and normalizes workspace configuration from the current Mix project.
  """
  @spec load!(keyword()) :: map()
  def load!(project_config \\ Mix.Project.config()) do
    project_config
    |> extract_workspace_config!()
    |> normalize_workspace!()
  end

  @doc """
  Returns the normalized workspace root for the current Mix project.
  """
  @spec root_dir() :: String.t()
  def root_dir do
    load!() |> root_dir()
  end

  @doc """
  Returns the normalized workspace root from a workspace config.
  """
  @spec root_dir(workspace_config()) :: String.t()
  def root_dir(workspace_config) do
    workspace_config
    |> normalize_workspace!()
    |> Map.fetch!(:root)
  end

  @doc """
  Returns workspace project paths in stable configured order.
  """
  @spec project_paths() :: [String.t()]
  def project_paths do
    load!() |> project_paths()
  end

  @doc """
  Returns workspace project paths in stable configured order.
  """
  @spec project_paths(workspace_config()) :: [String.t()]
  def project_paths(workspace_config) do
    workspace = normalize_workspace!(workspace_config)

    workspace.projects
    |> Enum.flat_map(&expand_project_spec(workspace.root, &1))
    |> Enum.uniq()
  end

  @doc """
  Returns workspace project paths excluding the root `"."` entry.
  """
  @spec package_paths() :: [String.t()]
  def package_paths do
    load!() |> package_paths()
  end

  @doc """
  Returns workspace project paths excluding the root `"."` entry.
  """
  @spec package_paths(workspace_config()) :: [String.t()]
  def package_paths(workspace_config) do
    workspace_config
    |> project_paths()
    |> Enum.reject(&(&1 == "."))
  end

  @doc """
  Builds task args for a configured workspace task.
  """
  @spec task_args(workspace_config(), task_name(), [String.t()]) :: [String.t()]
  def task_args(workspace_config, task, extra_args \\ []) do
    workspace = normalize_workspace!(workspace_config)
    task_config = fetch_task!(workspace, task)

    task_config.args ++ maybe_color_args(task_config, extra_args) ++ extra_args
  end

  @doc """
  Builds environment overrides for a project/task pair.
  """
  @spec command_env(workspace_config(), String.t(), task_name()) :: [
          {String.t(), String.t() | nil}
        ]
  def command_env(workspace_config, project_path, task) do
    workspace = normalize_workspace!(workspace_config)
    task_config = fetch_task!(workspace, task)
    project_root = project_root(workspace, project_path)

    isolation_env(workspace, project_root, task_config) ++
      callback_env(workspace, task_config, project_path, project_root, task)
  end

  @doc """
  Returns the effective concurrency for a workspace task.
  """
  @spec max_concurrency(workspace_config(), task_name(), pos_integer() | nil) :: pos_integer()
  def max_concurrency(workspace_config, task, runner_override \\ nil) do
    workspace = normalize_workspace!(workspace_config)

    runner_override || env_override(workspace) || configured_concurrency(workspace, task)
  end

  @doc """
  Returns a recommended workspace multiplier for the current machine.

  Auto mode uses the lower of a CPU-derived class and a memory-derived class so
  heavy Mix tasks do not scale only on one axis. Pass `:schedulers_online` and
  `:memory_bytes` to make detection deterministic in tests or custom tooling.
  """
  @spec autodetect_multiplier(keyword()) :: 1 | 2 | 3 | 4 | 6
  def autodetect_multiplier(opts \\ []) do
    cpu_multiplier =
      opts
      |> Keyword.get(:schedulers_online, schedulers_online())
      |> normalize_positive_integer!(:schedulers_online)
      |> cpu_multiplier()

    memory_multiplier =
      opts
      |> Keyword.get(:memory_bytes, total_memory_bytes())
      |> memory_multiplier()

    case memory_multiplier do
      nil -> cpu_multiplier
      value -> min(cpu_multiplier, value)
    end
  end

  @doc """
  Splits runner-level args from child task args.
  """
  @spec split_runner_args([String.t()]) :: {runner_args(), keyword()}
  def split_runner_args(args) do
    {task_args, max_concurrency} = do_split_runner_args(args, [], nil)
    runner_opts = if max_concurrency, do: [max_concurrency: max_concurrency], else: []

    {Enum.reverse(task_args), runner_opts}
  end

  @doc """
  Builds the staged execution plan for a workspace task.
  """
  @spec plan(workspace_config(), task_name(), [String.t()]) :: [stage()]
  def plan(workspace_config, task, args \\ []) do
    workspace = normalize_workspace!(workspace_config)
    task_config = fetch_task!(workspace, task)
    {task_args, runner_opts} = split_runner_args(args)
    runner_override = Keyword.get(runner_opts, :max_concurrency)

    preflight_stage =
      case pending_dep_commands(workspace, task_config, runner_override) do
        [] ->
          []

        commands ->
          [
            %{
              task: :deps_get,
              commands: commands,
              max_concurrency: max_concurrency(workspace, :deps_get, runner_override)
            }
          ]
      end

    task_stage =
      case project_commands(workspace, task, task_args) do
        [] ->
          []

        commands ->
          [
            %{
              task: task,
              commands: commands,
              max_concurrency: max_concurrency(workspace, task, runner_override)
            }
          ]
      end

    preflight_stage ++ task_stage
  end

  @doc """
  Runs a configured workspace task for the current Mix project.
  """
  @spec run!(task_name(), [String.t()]) :: :ok
  def run!(task, args) when is_atom(task) do
    run!(load!(), task, args)
  end

  @doc """
  Runs a configured workspace task.
  """
  @spec run!(workspace_config(), task_name(), [String.t()]) :: :ok
  def run!(workspace_config, task, args) do
    workspace_config
    |> plan(task, args)
    |> Enum.each(fn stage ->
      Blitz.run!(stage.commands, max_concurrency: stage.max_concurrency)
    end)

    :ok
  end

  @doc """
  Resolves a CLI task name against the configured workspace tasks.
  """
  @spec resolve_task_name!(workspace_config(), String.t()) :: task_name()
  def resolve_task_name!(workspace_config, task_name) when is_binary(task_name) do
    workspace = normalize_workspace!(workspace_config)

    case Enum.find(Map.keys(workspace.tasks), &(Atom.to_string(&1) == task_name)) do
      nil ->
        configured =
          workspace.tasks
          |> Map.keys()
          |> Enum.map_join(", ", &Atom.to_string/1)

        Mix.raise(
          "unknown Blitz workspace task #{inspect(task_name)}. Configured tasks: #{configured}"
        )

      task ->
        task
    end
  end

  @doc """
  Builds a stable hashed name for a workspace project path.
  """
  @spec hashed_project_name(String.t(), String.t(), keyword()) :: String.t()
  def hashed_project_name(base_name, project_path, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, 63)
    hash_bytes = Keyword.get(opts, :hash_bytes, 8)
    suffix = project_slug(project_path) <> "_" <> project_hash(project_path, hash_bytes)
    separator_size = 1
    max_base_bytes = max(max_bytes - byte_size(suffix) - separator_size, 1)

    base_name
    |> binary_part(0, min(byte_size(base_name), max_base_bytes))
    |> String.trim_trailing("_")
    |> then(fn
      "" -> suffix
      truncated_base -> "#{truncated_base}_#{suffix}"
    end)
  end

  defp extract_workspace_config!(project_config) do
    cond do
      workspace_config?(project_config) ->
        project_config

      has_blitz_workspace_key?(project_config) ->
        get_config_value(project_config, :blitz_workspace)

      true ->
        Mix.raise("missing :blitz_workspace configuration in mix.exs")
    end
  end

  defp normalize_workspace!(workspace_config) do
    workspace_config =
      case workspace_config do
        %{root: _root, projects: _projects, tasks: _tasks} -> workspace_config
        [root: _root, projects: _projects, tasks: _tasks] -> workspace_config
        _ -> extract_workspace_config!(workspace_config)
      end

    %{
      root:
        workspace_config
        |> get_config_value(:root, File.cwd!())
        |> to_string()
        |> Path.expand(),
      projects:
        workspace_config
        |> get_config_value(:projects, ["."])
        |> Enum.map(&to_string/1),
      tasks:
        workspace_config
        |> get_config_value(:tasks)
        |> normalize_tasks!(),
      isolation:
        workspace_config
        |> get_config_value(:isolation, [])
        |> normalize_isolation(),
      parallelism:
        workspace_config
        |> get_config_value(:parallelism, [])
        |> normalize_parallelism()
    }
  end

  defp normalize_tasks!(task_configs) when is_map(task_configs) do
    task_configs
    |> Enum.into([])
    |> normalize_tasks!()
  end

  defp normalize_tasks!(task_configs) when is_list(task_configs) do
    Enum.into(task_configs, %{}, fn {task_name, task_config} ->
      task_name = normalize_task_name!(task_name)

      task_config =
        task_config
        |> normalize_nested_config()
        |> then(fn config ->
          %{
            args:
              config
              |> get_config_value(:args)
              |> Enum.map(&to_string/1),
            color: get_config_value(config, :color, false),
            env: get_config_value(config, :env, nil),
            mix_env: normalize_mix_env(get_config_value(config, :mix_env, :inherit)),
            preflight?: get_config_value(config, :preflight?, task_name != :deps_get)
          }
        end)

      {task_name, task_config}
    end)
  end

  defp normalize_isolation(config) do
    config = normalize_nested_config(config)

    %{
      deps_path: get_config_value(config, :deps_path, @default_isolation.deps_path),
      build_path: get_config_value(config, :build_path, @default_isolation.build_path),
      lockfile: get_config_value(config, :lockfile, @default_isolation.lockfile),
      hex_home: get_config_value(config, :hex_home, @default_isolation.hex_home),
      unset_env:
        config
        |> get_config_value(:unset_env, @default_isolation.unset_env)
        |> Enum.map(&to_string/1)
    }
  end

  defp normalize_parallelism(config) do
    config = normalize_nested_config(config)

    %{
      base:
        config
        |> get_config_value(:base, @default_parallelism.base)
        |> normalize_positive_integer_map(),
      env:
        config
        |> get_config_value(:env, @default_parallelism.env)
        |> normalize_optional_string(),
      multiplier:
        config
        |> get_config_value(:multiplier, @default_parallelism.multiplier)
        |> normalize_multiplier!(:multiplier),
      overrides:
        config
        |> get_config_value(:overrides, @default_parallelism.overrides)
        |> normalize_positive_integer_map()
    }
  end

  defp normalize_positive_integer_map(values) when is_map(values) do
    values
    |> Enum.into([])
    |> normalize_positive_integer_map()
  end

  defp normalize_positive_integer_map(values) when is_list(values) do
    Enum.into(values, %{}, fn {task_name, value} ->
      {normalize_task_name!(task_name), normalize_positive_integer!(value, task_name)}
    end)
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value), do: to_string(value)

  defp normalize_mix_env(nil), do: :inherit
  defp normalize_mix_env(:inherit), do: :inherit
  defp normalize_mix_env(value), do: to_string(value)

  defp normalize_positive_integer!(value, _name)
       when is_integer(value) and value > 0 do
    value
  end

  defp normalize_positive_integer!(value, name) do
    Mix.raise("expected #{inspect(name)} to be a positive integer, got: #{inspect(value)}")
  end

  defp normalize_positive_number!(value, _name) when is_integer(value) and value > 0, do: value
  defp normalize_positive_number!(value, _name) when is_float(value) and value > 0.0, do: value

  defp normalize_positive_number!(value, name) do
    Mix.raise("expected #{inspect(name)} to be a positive number, got: #{inspect(value)}")
  end

  defp normalize_multiplier!(:auto, _name), do: :auto
  defp normalize_multiplier!(value, name), do: normalize_positive_number!(value, name)

  defp project_root(workspace, "."), do: workspace.root
  defp project_root(workspace, project_path), do: Path.join(workspace.root, project_path)

  defp expand_project_spec(root, project_spec) do
    if glob?(project_spec) do
      root
      |> Path.join(project_spec)
      |> Path.wildcard()
      |> Enum.filter(&File.regular?(Path.join(&1, "mix.exs")))
      |> Enum.sort()
      |> Enum.map(&Path.relative_to(&1, root))
    else
      project_root = project_root(%{root: root}, project_spec)

      if File.regular?(Path.join(project_root, "mix.exs")) do
        [Path.relative_to(project_root, root)]
      else
        []
      end
    end
  end

  defp glob?(project_spec) do
    String.contains?(project_spec, ["*", "?", "["])
  end

  defp maybe_color_args(%{color: false}, _extra_args), do: []

  defp maybe_color_args(%{color: true}, extra_args) do
    if Enum.any?(extra_args, &(&1 in ["--color", "--no-color"])) do
      []
    else
      ["--color"]
    end
  end

  defp fetch_task!(workspace, task) do
    case Map.fetch(workspace.tasks, task) do
      {:ok, task_config} ->
        task_config

      :error ->
        configured =
          workspace.tasks
          |> Map.keys()
          |> Enum.map_join(", ", &inspect/1)

        Mix.raise("unknown workspace task #{inspect(task)}. Configured tasks: #{configured}")
    end
  end

  defp isolation_env(workspace, project_root, task_config) do
    mix_env = task_mix_env(task_config)

    []
    |> maybe_prepend_env(
      workspace.isolation.deps_path,
      {"MIX_DEPS_PATH", Path.join(project_root, "deps")}
    )
    |> maybe_prepend_env(
      workspace.isolation.build_path,
      {"MIX_BUILD_PATH", Path.join(project_root, "_build/#{mix_env}")}
    )
    |> maybe_prepend_env(
      workspace.isolation.lockfile,
      {"MIX_LOCKFILE", Path.join(project_root, "mix.lock")}
    )
    |> maybe_prepend_env(
      workspace.isolation.hex_home,
      {"HEX_HOME", Path.join(project_root, workspace.isolation.hex_home)}
    )
    |> Kernel.++(Enum.map(workspace.isolation.unset_env, &{&1, nil}))
  end

  defp callback_env(workspace, task_config, project_path, project_root, task) do
    context = %{
      project_path: project_path,
      project_root: project_root,
      root: workspace.root,
      task: task,
      task_config: task_config
    }

    case task_config.env do
      nil ->
        []

      fun when is_function(fun, 1) ->
        fun.(context) |> normalize_env()

      {module, function} ->
        apply(module, function, [context]) |> normalize_env()

      {module, function, extra_args} when is_list(extra_args) ->
        apply(module, function, [context | extra_args]) |> normalize_env()

      other ->
        Mix.raise("expected task env callback to be a function or MFA, got: #{inspect(other)}")
    end
  end

  defp normalize_env(environment) when is_map(environment) do
    environment
    |> Enum.map(fn {key, value} -> {to_string(key), normalize_env_value(value)} end)
  end

  defp normalize_env(environment) when is_list(environment) do
    Enum.map(environment, fn {key, value} -> {to_string(key), normalize_env_value(value)} end)
  end

  defp normalize_env_value(nil), do: nil
  defp normalize_env_value(value), do: to_string(value)

  defp pending_dep_commands(_workspace, %{preflight?: false}, _runner_override), do: []

  defp pending_dep_commands(workspace, _task_config, _runner_override) do
    workspace
    |> project_paths()
    |> Enum.filter(&deps_missing?(workspace, &1))
    |> Enum.map(&project_command(workspace, &1, :deps_get, []))
  end

  defp deps_missing?(workspace, project_path) do
    project_root = project_root(workspace, project_path)

    File.exists?(Path.join(project_root, "mix.lock")) and
      not File.dir?(Path.join(project_root, "deps"))
  end

  defp project_commands(workspace, task, task_args) do
    Enum.map(project_paths(workspace), &project_command(workspace, &1, task, task_args))
  end

  defp project_command(workspace, project_path, task, extra_args) do
    Blitz.command(
      id: project_path,
      command: "mix",
      args: task_args(workspace, task, extra_args),
      cd: project_root(workspace, project_path),
      env: command_env(workspace, project_path, task)
    )
  end

  defp task_mix_env(%{mix_env: :inherit}), do: System.get_env("MIX_ENV", "dev")
  defp task_mix_env(%{mix_env: mix_env}), do: mix_env

  defp env_override(workspace) do
    case workspace.parallelism.env do
      nil ->
        nil

      env_name ->
        case System.get_env(env_name) do
          nil -> nil
          value -> parse_positive_integer!(value, env_name)
        end
    end
  end

  defp configured_concurrency(workspace, task) do
    case Map.fetch(workspace.parallelism.overrides, task) do
      {:ok, value} ->
        value

      :error ->
        case Map.fetch(workspace.parallelism.base, task) do
          {:ok, base} ->
            max(1, round(base * resolve_multiplier(workspace.parallelism.multiplier)))

          :error ->
            1
        end
    end
  end

  defp resolve_multiplier(:auto), do: autodetect_multiplier()
  defp resolve_multiplier(multiplier), do: multiplier

  defp schedulers_online do
    :erlang.system_info(:schedulers_online)
  end

  defp total_memory_bytes do
    linux_total_memory_bytes() || darwin_total_memory_bytes()
  end

  defp linux_total_memory_bytes do
    case File.read("/proc/meminfo") do
      {:ok, contents} ->
        case Regex.run(~r/^MemTotal:\s+(\d+)\s+kB$/m, contents, capture: :all_but_first) do
          [kilobytes] ->
            kilobytes
            |> String.to_integer()
            |> Kernel.*(1024)

          _ ->
            nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp darwin_total_memory_bytes do
    case System.cmd("sysctl", ["-n", "hw.memsize"], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {bytes, ""} when bytes > 0 -> bytes
          _ -> nil
        end

      {_output, _exit_status} ->
        nil
    end
  rescue
    ErlangError -> nil
  end

  defp cpu_multiplier(schedulers) when schedulers >= 32, do: 6
  defp cpu_multiplier(schedulers) when schedulers >= 24, do: 4
  defp cpu_multiplier(schedulers) when schedulers >= 16, do: 3
  defp cpu_multiplier(schedulers) when schedulers >= 8, do: 2
  defp cpu_multiplier(_schedulers), do: 1

  defp memory_multiplier(nil), do: nil
  defp memory_multiplier(bytes) when bytes >= 192 * @gib, do: 6
  defp memory_multiplier(bytes) when bytes >= 96 * @gib, do: 4
  defp memory_multiplier(bytes) when bytes >= 48 * @gib, do: 3
  defp memory_multiplier(bytes) when bytes >= 16 * @gib, do: 2
  defp memory_multiplier(_bytes), do: 1

  defp do_split_runner_args([], task_args, max_concurrency) do
    {task_args, max_concurrency}
  end

  defp do_split_runner_args(["--" | rest], task_args, max_concurrency) do
    {Enum.reverse(task_args) ++ rest, max_concurrency}
  end

  defp do_split_runner_args(["--max-concurrency", value | rest], task_args, _max_concurrency) do
    do_split_runner_args(rest, task_args, parse_positive_integer!(value, "--max-concurrency"))
  end

  defp do_split_runner_args(
         [<<"--max-concurrency=", value::binary>> | rest],
         task_args,
         _max_concurrency
       ) do
    do_split_runner_args(rest, task_args, parse_positive_integer!(value, "--max-concurrency"))
  end

  defp do_split_runner_args(["-j", value | rest], task_args, _max_concurrency) do
    do_split_runner_args(rest, task_args, parse_positive_integer!(value, "-j"))
  end

  defp do_split_runner_args([arg | rest], task_args, max_concurrency) do
    do_split_runner_args(rest, [arg | task_args], max_concurrency)
  end

  defp parse_positive_integer!(value, name) do
    case Integer.parse(to_string(value)) do
      {parsed, ""} when parsed > 0 ->
        parsed

      _ ->
        Mix.raise("expected #{name} to be a positive integer, got: #{inspect(value)}")
    end
  end

  defp maybe_prepend_env(env, false, _pair), do: env
  defp maybe_prepend_env(env, nil, _pair), do: env
  defp maybe_prepend_env(env, _setting, pair), do: env ++ [pair]

  defp project_slug(project_path) do
    project_path
    |> String.replace(".", "workspace")
    |> String.replace(~r/[^a-zA-Z0-9]+/u, "_")
    |> String.trim("_")
    |> String.downcase()
  end

  defp project_hash(project_path, hash_bytes) do
    :crypto.hash(:sha256, project_path)
    |> Base.encode16(case: :lower)
    |> binary_part(0, hash_bytes)
  end

  defp normalize_task_name!(task_name) when is_atom(task_name), do: task_name
  defp normalize_task_name!(task_name) when is_binary(task_name), do: String.to_atom(task_name)

  defp normalize_nested_config(config) when is_map(config), do: config
  defp normalize_nested_config(config) when is_list(config), do: config

  defp workspace_config?(config) do
    has_config_key?(config, :root) and has_config_key?(config, :projects) and
      has_config_key?(config, :tasks)
  end

  defp has_blitz_workspace_key?(config), do: has_config_key?(config, :blitz_workspace)

  defp has_config_key?(config, key) when is_list(config), do: Keyword.has_key?(config, key)
  defp has_config_key?(config, key) when is_map(config), do: Map.has_key?(config, key)

  defp get_config_value(config, key, default \\ :no_default)

  defp get_config_value(config, key, default) when is_list(config) do
    case {default, Keyword.fetch(config, key)} do
      {:no_default, :error} -> Mix.raise("missing required workspace config #{inspect(key)}")
      {default, :error} -> default
      {_default, {:ok, value}} -> value
    end
  end

  defp get_config_value(config, key, default) when is_map(config) do
    case {default, Map.fetch(config, key)} do
      {:no_default, :error} -> Mix.raise("missing required workspace config #{inspect(key)}")
      {default, :error} -> default
      {_default, {:ok, value}} -> value
    end
  end
end
