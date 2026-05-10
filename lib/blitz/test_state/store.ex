defmodule Blitz.TestState.Store do
  @moduledoc false

  alias Blitz.TestState.{Hash, Json}

  defstruct [:root, retention: :compact]

  @type t :: %__MODULE__{root: String.t(), retention: :compact | :audit}

  @spec new(String.t(), keyword()) :: t()
  def new(workspace_root, opts \\ []) do
    root =
      Keyword.get(opts, :store_dir) ||
        Path.join([workspace_root, ".blitz", "test_state_v1"])

    retention =
      opts
      |> Keyword.get(:retention, :compact)
      |> normalize_retention()

    %__MODULE__{root: Path.expand(root), retention: retention}
  end

  @spec covered?(t(), String.t()) :: boolean()
  def covered?(%__MODULE__{} = store, task_state_hash) do
    case compact_coverage(store, task_state_hash) do
      {:ok, covered?} -> covered?
      :error -> legacy_coverage(store, task_state_hash)
    end
  end

  defp legacy_coverage(store, task_state_hash) do
    index_path = task_state_index_path(store, task_state_hash)

    case File.read(index_path) do
      {:ok, contents} ->
        passed_index_contents?(contents)

      {:error, _reason} ->
        false
    end
  end

  def append_result!(%__MODULE__{} = store, record) do
    ensure_store!(store)

    record =
      record
      |> Map.put_new(:schema, "blitz-result-v1")
      |> Map.put_new(:recorded_at, now())
      |> put_result_id()

    line = Json.encode!(record) <> "\n"
    append_audit_record!(store, record, line)
    write_task_state_index!(store, record)

    record
  end

  @spec prune!(t(), keyword()) :: :ok
  def prune!(%__MODULE__{} = store, opts \\ []) do
    ensure_store!(store)

    if store.retention == :compact do
      store.root
      |> Path.join("results.ndjson")
      |> File.rm()
      |> ignore_missing()

      Enum.each(["commits", "output", Path.join("indexes", "by_project")], fn relative_path ->
        store.root
        |> Path.join(relative_path)
        |> File.rm_rf!()
      end)

      prune_task_state_indexes!(store, Keyword.get(opts, :keep_task_state_hashes))
      prune_manifests!(store, Keyword.get(opts, :keep_pipeline_hashes))
    end

    :ok
  end

  @spec write_clean_baseline!(t(), map()) :: map()
  def write_clean_baseline!(%__MODULE__{} = store, baseline) do
    ensure_store!(store)

    baseline =
      baseline
      |> Map.put_new(:schema, "blitz-clean-baseline-v1")
      |> Map.put_new(:status, "passed")
      |> Map.put_new(:updated_at, now())

    write_json_atomic!(current_baseline_path(store), baseline)
    baseline
  end

  @spec latest_clean_baseline(t(), String.t()) :: {:ok, map()} | :error
  def latest_clean_baseline(%__MODULE__{} = store, workspace_state_hash) do
    case File.read(current_baseline_path(store)) do
      {:ok, contents} ->
        if String.contains?(contents, ~s("status":"passed")) and
             String.contains?(contents, ~s("workspace_state_hash":"#{workspace_state_hash}")) do
          {:ok, %{contents: contents, workspace_state_hash: workspace_state_hash}}
        else
          :error
        end

      {:error, _reason} ->
        :error
    end
  end

  @spec covered_by_baseline?(map(), String.t(), atom() | String.t(), String.t()) :: boolean()
  def covered_by_baseline?(%{contents: contents}, _project_path, _task, task_state_hash) do
    String.contains?(contents, ~s("task_state_hash":"#{task_state_hash}"))
  end

  @spec write_pipeline_manifest!(t(), %{
          required(:pipeline_hash) => term(),
          optional(any()) => any()
        }) ::
          map()
  def write_pipeline_manifest!(%__MODULE__{} = store, %{pipeline_hash: pipeline_hash} = manifest) do
    ensure_store!(store)

    manifest =
      manifest
      |> Map.put_new(:schema, "blitz-pipeline-manifest-v1")
      |> Map.put_new(:updated_at, now())

    write_json_atomic!(pipeline_manifest_path(store, pipeline_hash), manifest)
    manifest
  end

  @spec passed_pipeline_manifest(t(), String.t()) :: {:ok, map()} | :error
  def passed_pipeline_manifest(%__MODULE__{} = store, pipeline_hash) do
    path = pipeline_manifest_path(store, pipeline_hash)

    case File.read(path) do
      {:ok, contents} ->
        if String.contains?(contents, ~s("status":"passed")) do
          {:ok,
           %{
             pipeline_hash: pipeline_hash,
             total_commands: integer_field(contents, "total_commands") || 0
           }}
        else
          :error
        end

      {:error, _reason} ->
        :error
    end
  end

  @spec ensure_store!(t()) :: :ok
  def ensure_store!(%__MODULE__{} = store) do
    paths =
      [
        store.root,
        Path.join(store.root, "indexes"),
        Path.join(store.root, "baselines"),
        Path.join(store.root, "manifests")
      ] ++ audit_paths(store)

    Enum.each(paths, &File.mkdir_p!/1)

    :ok
  end

  defp normalize_retention(:audit), do: :audit
  defp normalize_retention("audit"), do: :audit
  defp normalize_retention(:compact), do: :compact
  defp normalize_retention("compact"), do: :compact
  defp normalize_retention(_other), do: :compact

  defp audit_paths(%{retention: :audit} = store) do
    [
      Path.join(store.root, "commits"),
      Path.join([store.root, "indexes", "by_task_state"]),
      Path.join([store.root, "indexes", "by_project"]),
      Path.join(store.root, "output")
    ]
  end

  defp audit_paths(_store), do: []

  defp put_result_id(record) do
    Map.put_new(record, :result_id, Hash.hash("result_id", Map.delete(record, :result_id)))
  end

  defp append_audit_record!(%{retention: :compact}, _record, _line), do: :ok

  defp append_audit_record!(%{retention: :audit} = store, record, line) do
    File.write!(Path.join(store.root, "results.ndjson"), line, [:append])
    append_commit_record!(store, record, line)
  end

  defp append_commit_record!(_store, record, _line) when not is_map_key(record, :repo_commit),
    do: :ok

  defp append_commit_record!(_store, %{repo_commit: nil}, _line), do: :ok

  defp append_commit_record!(store, %{repo_commit: commit}, line) do
    File.write!(Path.join([store.root, "commits", safe_name(commit) <> ".ndjson"]), line, [
      :append
    ])
  end

  defp write_task_state_index!(store, %{task_state_hash: task_state_hash} = record) do
    index = %{
      schema: "blitz-task-state-index-v1",
      task_state_hash: task_state_hash,
      latest_result_id: record.result_id,
      latest_passed_result_id: latest_passed_result_id(record),
      project_path: Map.get(record, :project_path),
      task: Map.get(record, :task),
      updated_at: now()
    }

    if store.retention == :audit do
      write_json_atomic!(task_state_index_path(store, task_state_hash), index)
    else
      File.mkdir_p!(Path.dirname(compact_task_state_index_path(store)))
      File.write!(compact_task_state_index_path(store), Json.encode!(index) <> "\n", [:append])
    end
  end

  defp latest_passed_result_id(%{status: "passed", result_id: result_id}), do: result_id
  defp latest_passed_result_id(_record), do: nil

  defp task_state_index_path(store, task_state_hash) do
    Path.join([store.root, "indexes", "by_task_state", safe_name(task_state_hash) <> ".json"])
  end

  defp pipeline_manifest_path(store, pipeline_hash) do
    Path.join([store.root, "manifests", safe_name(pipeline_hash) <> ".json"])
  end

  defp current_baseline_path(store) do
    Path.join([store.root, "baselines", "current.json"])
  end

  defp prune_task_state_indexes!(store, nil) do
    compact_task_state_index_path(store)
    |> compact_latest_lines(nil)
    |> write_compact_task_state_index!(store)
  end

  defp prune_task_state_indexes!(store, keep_task_state_hashes) do
    compact_task_state_index_path(store)
    |> compact_latest_lines(MapSet.new(keep_task_state_hashes))
    |> write_compact_task_state_index!(store)

    keep =
      keep_task_state_hashes
      |> Enum.map(&(safe_name(&1) <> ".json"))
      |> MapSet.new()

    [store.root, "indexes", "by_task_state", "*.json"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) in keep))
    |> Enum.each(&File.rm!/1)

    [store.root, "indexes", "by_task_state"]
    |> Path.join()
    |> File.rm_rf!()
  end

  defp prune_manifests!(_store, nil), do: :ok

  defp prune_manifests!(store, keep_pipeline_hashes) do
    keep =
      keep_pipeline_hashes
      |> Enum.map(&(safe_name(&1) <> ".json"))
      |> MapSet.new()

    [store.root, "manifests", "*.json"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) in keep))
    |> Enum.each(&File.rm!/1)
  end

  defp ignore_missing(:ok), do: :ok
  defp ignore_missing({:error, :enoent}), do: :ok

  defp ignore_missing({:error, reason}),
    do: raise("could not remove compact store artifact: #{inspect(reason)}")

  defp integer_field(contents, field) do
    case Regex.run(~r/"#{Regex.escape(field)}":(\d+)/, contents) do
      [_, integer] -> String.to_integer(integer)
      nil -> nil
    end
  end

  defp compact_coverage(store, task_state_hash) do
    store
    |> compact_task_state_index_path()
    |> compact_latest_line(task_state_hash)
    |> case do
      nil -> :error
      line -> {:ok, passed_index_contents?(line)}
    end
  end

  defp compact_latest_line(path, task_state_hash) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.find(&(index_line_task_state_hash(&1) == task_state_hash))

      {:error, _reason} ->
        nil
    end
  end

  defp compact_latest_lines(path, keep) do
    lines =
      case File.read(path) do
        {:ok, contents} -> String.split(contents, "\n", trim: true)
        {:error, _reason} -> []
      end

    lines
    |> Enum.reduce(%{}, fn line, latest ->
      case index_line_task_state_hash(line) do
        nil -> latest
        task_state_hash -> Map.put(latest, task_state_hash, line)
      end
    end)
    |> Enum.reject(fn {task_state_hash, _line} ->
      keep && not MapSet.member?(keep, task_state_hash)
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp write_compact_task_state_index!([], store) do
    compact_task_state_index_path(store)
    |> File.rm()
    |> ignore_missing()
  end

  defp write_compact_task_state_index!(lines, store) do
    path = compact_task_state_index_path(store)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.join(lines, "\n") <> "\n")
  end

  defp compact_task_state_index_path(store) do
    Path.join([store.root, "indexes", "task_states.ndjson"])
  end

  defp index_line_task_state_hash(line) do
    case Regex.run(~r/"task_state_hash":"([^"]+)"/, line) do
      [_, task_state_hash] -> task_state_hash
      nil -> nil
    end
  end

  defp passed_index_contents?(contents) do
    String.contains?(contents, ~s("latest_passed_result_id")) and
      not String.contains?(contents, ~s("latest_passed_result_id":null))
  end

  defp write_json_atomic!(path, value) do
    File.mkdir_p!(Path.dirname(path))
    tmp_path = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))
    File.write!(tmp_path, Json.encode!(value) <> "\n")
    File.rename!(tmp_path, path)
  end

  defp now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp safe_name(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
  end
end
