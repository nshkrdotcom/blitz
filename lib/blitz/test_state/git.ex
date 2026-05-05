defmodule Blitz.TestState.Git do
  @moduledoc false

  @spec metadata(String.t()) :: map()
  def metadata(root) do
    if git_repo?(root) do
      %{
        repo?: true,
        commit: cmd(root, ["rev-parse", "HEAD"]),
        tree: cmd(root, ["rev-parse", "HEAD^{tree}"]),
        dirty?: dirty?(root)
      }
    else
      %{repo?: false, commit: nil, tree: nil, dirty?: nil}
    end
  end

  @spec changed_files(String.t(), keyword()) :: {:ok, [String.t()]} | :unknown
  def changed_files(root, opts \\ []) do
    if git_repo?(root) do
      base = Keyword.get(opts, :base)
      head = Keyword.get(opts, :head)

      files =
        cond do
          base && head ->
            diff_files(root, [base, head])

          base ->
            diff_files(root, [base, "HEAD"]) ++ working_tree_files(root)

          true ->
            working_tree_files(root)
        end

      {:ok, files |> reject_blitz_store() |> Enum.uniq() |> Enum.sort()}
    else
      :unknown
    end
  end

  @spec repo_files(String.t()) :: {:ok, [String.t()]} | :unknown
  def repo_files(root) do
    if git_repo?(root) do
      {:ok,
       (ls_files(root, []) ++ ls_files(root, ["--others", "--exclude-standard"]))
       |> reject_blitz_store()
       |> Enum.uniq()}
    else
      :unknown
    end
  end

  defp git_repo?(root) do
    case System.cmd("git", ["-C", root, "rev-parse", "--is-inside-work-tree"],
           stderr_to_stdout: true
         ) do
      {"true\n", 0} -> true
      _other -> false
    end
  rescue
    ErlangError -> false
  end

  defp dirty?(root) do
    case System.cmd("git", ["-C", root, "status", "--porcelain"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> split_lines()
        |> Enum.reject(&blitz_status_line?/1)
        |> Enum.any?()

      _other ->
        nil
    end
  end

  defp working_tree_files(root) do
    diff_files(root, ["HEAD"]) ++
      diff_files(root, ["--cached", "HEAD"]) ++
      ls_files(root, ["--others", "--exclude-standard"])
  end

  defp diff_files(root, args) do
    case System.cmd("git", ["-C", root, "diff", "--name-only" | args], stderr_to_stdout: true) do
      {output, 0} -> split_lines(output)
      _other -> []
    end
  end

  defp ls_files(root, args) do
    case System.cmd("git", ["-C", root, "ls-files" | args], stderr_to_stdout: true) do
      {output, 0} -> split_lines(output)
      _other -> []
    end
  end

  defp cmd(root, args) do
    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _other -> nil
    end
  end

  defp split_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reject(&(&1 == ""))
  end

  defp reject_blitz_store(files) do
    Enum.reject(files, &blitz_store_path?/1)
  end

  defp blitz_store_path?(path) do
    path == ".blitz" or String.starts_with?(path, ".blitz/")
  end

  defp blitz_status_line?(line) do
    line
    |> String.slice(3..-1//1)
    |> blitz_store_path?()
  end
end
