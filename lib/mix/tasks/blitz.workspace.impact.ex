defmodule Mix.Tasks.Blitz.Workspace.Impact do
  use Mix.Task

  alias Blitz.MixWorkspace

  @moduledoc """
  Run a configured Blitz workspace task with test-state impact skipping.

  Usage:

      mix blitz.workspace.impact test --dry-run
      mix blitz.workspace.impact compile --base main --head HEAD
  """

  @shortdoc "Run a Blitz workspace task with impact-aware skipping"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          dry_run: :boolean,
          force: :boolean,
          explain: :boolean,
          base: :string,
          head: :string,
          store_dir: :string
        ],
        aliases: [f: :force]
      )

    validate_invalid!(invalid)

    case positional do
      [task_name | task_args] ->
        workspace = MixWorkspace.load!()
        task = MixWorkspace.resolve_task_name!(workspace, task_name)
        MixWorkspace.Impact.run!(workspace, task, task_args, normalize_opts(opts))

      [] ->
        Mix.raise("""
        Expected a Blitz workspace task name.

        Usage: mix blitz.workspace.impact <task> [task args]
        """)
    end
  after
    Mix.Task.reenable("blitz.workspace.impact")
  end

  defp normalize_opts(opts) do
    opts
    |> Keyword.update(:dry_run, false, & &1)
    |> Keyword.update(:force, false, & &1)
  end

  defp validate_invalid!([]), do: :ok

  defp validate_invalid!(invalid) do
    Mix.raise("Invalid options: #{inspect(invalid)}")
  end
end
