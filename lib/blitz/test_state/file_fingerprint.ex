defmodule Blitz.TestState.FileFingerprint do
  @moduledoc false

  alias Blitz.TestState.{Git, Hash}

  @excluded_segments [".git", ".blitz", "_build", "deps", "doc"]

  def project(root, project_path) do
    project_root = project_root(root, project_path)
    files = project_files(root, project_path)

    %{
      project_path: project_path,
      files_hash: hash_files(project_root, files, "all"),
      source_hash:
        files |> Enum.filter(&source_file?/1) |> hash_filtered_files(project_root, "source"),
      test_hash: files |> Enum.filter(&test_file?/1) |> hash_filtered_files(project_root, "test"),
      docs_hash: files |> Enum.filter(&docs_file?/1) |> hash_filtered_files(project_root, "docs"),
      format_hash:
        files |> Enum.filter(&format_file?/1) |> hash_filtered_files(project_root, "format"),
      credo_hash:
        files |> Enum.filter(&credo_file?/1) |> hash_filtered_files(project_root, "credo"),
      config_hash:
        files |> Enum.filter(&config_file?/1) |> hash_filtered_files(project_root, "config"),
      mix_exs_hash: single_file_hash(project_root, "mix.exs"),
      mix_lock_hash: single_file_hash(project_root, "mix.lock")
    }
  end

  @spec path_tree(String.t()) :: String.t()
  def path_tree(path) do
    root = Path.expand(path)

    files =
      root
      |> all_files()
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.reject(&excluded?/1)
      |> Enum.sort()

    hash_files(root, files, "path_tree")
  end

  @spec project_files(String.t(), String.t()) :: [String.t()]
  def project_files(root, ".") do
    case Git.repo_files(root) do
      {:ok, files} ->
        files
        |> Enum.reject(&(nested_project_file?(root, &1) or excluded?(&1)))
        |> Enum.sort()

      :unknown ->
        root
        |> all_files()
        |> Enum.map(&Path.relative_to(&1, root))
        |> Enum.reject(&(nested_project_file?(root, &1) or excluded?(&1)))
        |> Enum.sort()
    end
  end

  def project_files(root, project_path) do
    prefix = project_path <> "/"

    files =
      case Git.repo_files(root) do
        {:ok, repo_files} ->
          repo_files

        :unknown ->
          root
          |> all_files()
          |> Enum.map(&Path.relative_to(&1, root))
      end

    files
    |> Enum.filter(&(String.starts_with?(&1, prefix) or &1 == project_path))
    |> Enum.map(&String.replace_prefix(&1, prefix, ""))
    |> Enum.reject(&(&1 == project_path or &1 == "" or excluded?(&1)))
    |> Enum.sort()
  end

  defp single_file_hash(project_root, file), do: hash_files(project_root, [file], file)

  defp project_root(root, "."), do: root
  defp project_root(root, project_path), do: Path.join(root, project_path)

  defp hash_filtered_files(files, root, label), do: hash_files(root, files, label)

  defp hash_files(root, files, label) do
    entries =
      files
      |> Enum.sort()
      |> Enum.map(fn file ->
        path = Path.join(root, file)

        case File.read(path) do
          {:ok, contents} -> %{path: file, status: "present", hash: Hash.hash("file", contents)}
          {:error, :enoent} -> %{path: file, status: "missing"}
          {:error, reason} -> %{path: file, status: "error", reason: inspect(reason)}
        end
      end)

    Hash.hash("files:" <> label, entries)
  end

  defp all_files(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
  end

  defp nested_project_file?(root, file) do
    file != "mix.exs" and
      file
      |> Path.dirname()
      |> ancestor_dirs()
      |> Enum.any?(fn dir -> File.regular?(Path.join([root, dir, "mix.exs"])) end)
  end

  defp ancestor_dirs("."), do: []

  defp ancestor_dirs(dir) do
    dir
    |> Path.split()
    |> Enum.scan(fn segment, acc -> Path.join(acc, segment) end)
  end

  defp excluded?(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 in @excluded_segments))
  end

  defp source_file?(path) do
    String.starts_with?(path, ["lib/", "src/", "priv/"]) or
      path in ["mix.exs"] or String.starts_with?(path, "config/")
  end

  defp test_file?(path), do: String.starts_with?(path, "test/")

  defp docs_file?(path) do
    path == "README.md" or String.ends_with?(path, ".md") or
      String.starts_with?(path, ["guides/", "docs/"])
  end

  defp format_file?(path) do
    path == ".formatter.exs" or String.ends_with?(path, [".ex", ".exs"])
  end

  defp credo_file?(path) do
    path == ".credo.exs" or String.ends_with?(path, [".ex", ".exs"])
  end

  defp config_file?(path) do
    String.starts_with?(path, "config/") or path in [".formatter.exs", ".credo.exs"]
  end
end
