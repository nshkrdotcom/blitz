defmodule Mix.Tasks.Blitz.Workspace do
  use Mix.Task

  @moduledoc """
  Run a configured Blitz workspace task from the current Mix project.

  Usage:

      mix blitz.workspace <task> [task args]
      mix blitz.workspace <task> -j 4 -- [task args passed through verbatim]
  """

  @shortdoc "Run a configured Blitz workspace task"

  @impl Mix.Task
  def run(args) do
    do_run(args)
  after
    Mix.Task.reenable("blitz.workspace")
  end

  defp do_run([task_name | args]) do
    workspace = Blitz.MixWorkspace.load!()
    task = Blitz.MixWorkspace.resolve_task_name!(workspace, task_name)
    Blitz.MixWorkspace.run!(workspace, task, args)
  end

  defp do_run([]) do
    Mix.raise("""
    Expected a Blitz workspace task name.

    Usage: mix blitz.workspace <task> [task args]
    """)
  end
end
