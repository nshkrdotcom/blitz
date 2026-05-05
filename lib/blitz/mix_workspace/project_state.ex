defmodule Blitz.MixWorkspace.ProjectState do
  @moduledoc false

  alias Blitz.MixWorkspace.DependencyState
  alias Blitz.TestState.{FileFingerprint, Hash}

  @spec snapshot_all(map()) :: map()
  def snapshot_all(workspace) do
    project_paths = Blitz.MixWorkspace.project_paths(workspace)

    basic =
      Map.new(project_paths, fn project_path ->
        {project_path, FileFingerprint.project(workspace.root, project_path)}
      end)

    Map.new(project_paths, fn project_path ->
      deps = DependencyState.snapshot(workspace.root, project_path, project_paths, basic)
      state = Map.merge(Map.fetch!(basic, project_path), deps)
      {project_path, Map.put(state, :project_state_hash, Hash.hash("project_state", state))}
    end)
  end

  @spec task_hash(map(), atom()) :: String.t()
  def task_hash(project_state, task) do
    Hash.hash("project_task:" <> Atom.to_string(task), task_inputs(project_state, task))
  end

  @spec local_dependency_graph(map()) :: map()
  def local_dependency_graph(project_states) do
    Map.new(project_states, fn {project_path, state} ->
      {project_path, Map.get(state, :local_dependencies, [])}
    end)
  end

  defp task_inputs(state, :format) do
    Map.take(state, [:project_path, :format_hash, :config_hash])
  end

  defp task_inputs(state, :compile) do
    Map.take(state, [
      :project_path,
      :source_hash,
      :config_hash,
      :mix_exs_hash,
      :mix_lock_hash,
      :dependency_hash
    ])
  end

  defp task_inputs(state, :test) do
    Map.take(state, [
      :project_path,
      :source_hash,
      :test_hash,
      :config_hash,
      :mix_exs_hash,
      :mix_lock_hash,
      :dependency_hash
    ])
  end

  defp task_inputs(state, :credo) do
    Map.take(state, [
      :project_path,
      :source_hash,
      :test_hash,
      :credo_hash,
      :config_hash,
      :mix_exs_hash
    ])
  end

  defp task_inputs(state, :dialyzer) do
    Map.take(state, [
      :project_path,
      :source_hash,
      :config_hash,
      :mix_exs_hash,
      :mix_lock_hash,
      :dependency_hash
    ])
  end

  defp task_inputs(state, :docs) do
    Map.take(state, [
      :project_path,
      :source_hash,
      :docs_hash,
      :mix_exs_hash,
      :mix_lock_hash,
      :dependency_hash
    ])
  end

  defp task_inputs(state, :deps_get) do
    Map.take(state, [:project_path, :mix_exs_hash, :dependency_declaration_hash])
  end

  defp task_inputs(state, _task) do
    Map.take(state, [
      :project_path,
      :files_hash,
      :mix_exs_hash,
      :mix_lock_hash,
      :dependency_hash
    ])
  end
end
