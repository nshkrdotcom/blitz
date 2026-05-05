defmodule Blitz.MixWorkspace.DependencyState do
  @moduledoc false

  alias Blitz.TestState.{FileFingerprint, Hash}

  @spec snapshot(String.t(), String.t(), [String.t()], map()) :: map()
  def snapshot(root, project_path, active_project_paths, basic_project_states) do
    project_root = project_root(root, project_path)
    lock = read_lock(project_root)

    deps =
      project_root
      |> declared_deps()
      |> Enum.map(
        &dependency_entry(
          &1,
          root,
          project_root,
          active_project_paths,
          basic_project_states,
          lock
        )
      )
      |> Enum.sort_by(&Map.get(&1, :app))

    %{
      dependencies: deps,
      dependency_declaration_hash:
        Hash.hash("dependency_declaration_state", deps_get_entries(deps)),
      dependency_hash: Hash.hash("dependency_state", deps),
      local_dependencies: local_dependencies(deps)
    }
  end

  defp dependency_entry(dep, root, project_root, active_project_paths, basic_project_states, lock) do
    {app, requirement, opts} = normalize_dep(dep)
    lock_entry = Map.get(lock, Atom.to_string(app)) || Map.get(lock, app)

    declared = declared_source(requirement, opts)

    resolved =
      resolved_source(
        app,
        opts,
        lock_entry,
        root,
        project_root,
        active_project_paths,
        basic_project_states
      )

    %{
      app: Atom.to_string(app),
      declared: declared,
      resolved: resolved
    }
  end

  defp normalize_dep({app, opts}) when is_atom(app) and is_list(opts), do: {app, nil, opts}
  defp normalize_dep({app, requirement}) when is_atom(app), do: {app, requirement, []}

  defp normalize_dep({app, requirement, opts}) when is_atom(app),
    do: {app, requirement, opts || []}

  defp declared_source(requirement, opts) do
    cond do
      path = Keyword.get(opts, :path) ->
        %{kind: "path", path: to_string(path)}

      git = Keyword.get(opts, :git) ->
        %{
          kind: "git",
          git: to_string(git),
          ref: git_ref(opts),
          subdir: optional_string(opts, :subdir)
        }

      github = Keyword.get(opts, :github) ->
        %{
          kind: "git",
          github: to_string(github),
          ref: git_ref(opts),
          subdir: optional_string(opts, :subdir)
        }

      true ->
        %{kind: "hex", requirement: requirement_string(requirement)}
    end
  end

  defp requirement_string(requirement), do: optional_to_string(requirement)

  defp resolved_source(
         app,
         opts,
         lock_entry,
         root,
         project_root,
         active_project_paths,
         basic_project_states
       ) do
    cond do
      path = Keyword.get(opts, :path) ->
        resolved_path(path, root, project_root, active_project_paths, basic_project_states)

      Keyword.has_key?(opts, :git) or Keyword.has_key?(opts, :github) ->
        git_state = %{
          kind: "git",
          app: Atom.to_string(app),
          lock: inspect(lock_entry),
          unsafe_unlocked?: is_nil(lock_entry)
        }

        if is_nil(lock_entry) do
          Map.put(git_state, :unsafe_nonce, unsafe_nonce())
        else
          git_state
        end

      lock_entry ->
        %{kind: "lock", app: Atom.to_string(app), lock: inspect(lock_entry)}

      true ->
        %{kind: "unlocked", app: Atom.to_string(app)}
    end
  end

  defp resolved_path(path, root, project_root, active_project_paths, basic_project_states) do
    expanded = Path.expand(to_string(path), project_root)
    relative = Path.relative_to(expanded, root)

    if relative in active_project_paths do
      state = Map.fetch!(basic_project_states, relative)

      %{
        kind: "local_project",
        project_path: relative,
        source_hash: state.source_hash,
        mix_exs_hash: state.mix_exs_hash
      }
    else
      %{
        kind: "path",
        path: expanded,
        mix_exs_hash: single_file_hash(expanded, "mix.exs"),
        source_hash: FileFingerprint.path_tree(expanded)
      }
    end
  end

  defp deps_get_entries(deps) do
    Enum.map(deps, fn %{app: app, declared: declared, resolved: resolved} ->
      %{
        app: app,
        declared: declared,
        resolved: deps_get_resolved_source(resolved)
      }
    end)
  end

  defp deps_get_resolved_source(%{
         kind: "local_project",
         project_path: project_path,
         mix_exs_hash: mix_exs_hash
       }) do
    %{kind: "local_project", project_path: project_path, mix_exs_hash: mix_exs_hash}
  end

  defp deps_get_resolved_source(%{kind: "path", path: path, mix_exs_hash: mix_exs_hash}) do
    %{kind: "path", path: path, mix_exs_hash: mix_exs_hash}
  end

  defp deps_get_resolved_source(%{
         kind: "git",
         app: app,
         unsafe_unlocked?: true,
         unsafe_nonce: unsafe_nonce
       }) do
    %{kind: "git", app: app, unsafe_unlocked?: true, unsafe_nonce: unsafe_nonce}
  end

  defp deps_get_resolved_source(%{kind: kind, app: app})
       when kind in ["git", "lock", "unlocked"] do
    %{kind: kind, app: app}
  end

  defp single_file_hash(root, file) do
    path = Path.join(root, file)

    entry =
      case File.read(path) do
        {:ok, contents} -> %{path: file, status: "present", hash: Hash.hash("file", contents)}
        {:error, :enoent} -> %{path: file, status: "missing"}
        {:error, reason} -> %{path: file, status: "error", reason: inspect(reason)}
      end

    Hash.hash("files:" <> file, [entry])
  end

  defp local_dependencies(deps) do
    deps
    |> Enum.flat_map(fn
      %{resolved: %{kind: "local_project", project_path: project_path}} -> [project_path]
      _other -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp declared_deps(project_root) do
    if same_path?(project_root, File.cwd!()) do
      Mix.Project.config()
      |> Keyword.get(:deps, [])
    else
      app = :"blitz_state_#{:erlang.unique_integer([:positive])}"
      previous_options = Code.compiler_options()
      Code.compiler_options(ignore_module_conflict: true)

      try do
        Mix.Project.in_project(app, project_root, fn _module ->
          Mix.Project.config()
          |> Keyword.get(:deps, [])
        end)
      after
        Code.compiler_options(previous_options)
      end
    end
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

  defp same_path?(left, right), do: Path.expand(left) == Path.expand(right)

  defp read_lock(project_root) do
    path = Path.join(project_root, "mix.lock")

    if File.exists?(path) do
      case path |> File.read!() |> normalize_lock_source() |> Code.eval_string([], file: path) do
        {lock, _binding} when is_map(lock) -> lock
        _other -> %{}
      end
    else
      %{}
    end
  rescue
    _error -> %{}
  catch
    _kind, _reason -> %{}
  end

  defp normalize_lock_source(contents) do
    Regex.replace(~r/"([A-Za-z_][A-Za-z0-9_]*)":/, contents, "\\1:")
  end

  defp project_root(root, "."), do: root
  defp project_root(root, project_path), do: Path.join(root, project_path)

  defp git_ref(opts) do
    [:ref, :branch, :tag]
    |> Enum.find_value(&Keyword.get(opts, &1))
    |> optional_to_string()
  end

  defp optional_string(opts, key), do: opts |> Keyword.get(key) |> optional_to_string()
  defp optional_to_string(nil), do: nil
  defp optional_to_string(value), do: to_string(value)
  defp unsafe_nonce, do: System.unique_integer([:positive, :monotonic])
end
