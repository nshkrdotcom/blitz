defmodule Blitz do
  @moduledoc """
  Lightweight parallel command execution for Elixir tooling.

  `Blitz` runs isolated OS commands with bounded concurrency and prefixes
  streamed output with a stable command id so parallel logs remain readable.

  For config-driven Mix monorepos, see `Blitz.MixWorkspace`.
  """

  alias Blitz.{Command, Runner}

  @type command :: Command.t()
  @type run_option ::
          {:announce?, boolean()}
          | {:emit_output?, boolean()}
          | {:max_concurrency, pos_integer()}
          | {:prefix_output?, boolean()}
          | {:timeout, timeout()}
  @type stage :: %{
          optional(atom()) => term(),
          :commands => [command()],
          :max_concurrency => pos_integer()
        }
  @type stage_option ::
          {:announce?, boolean()}
          | {:emit_output?, boolean()}
          | {:prefix_output?, boolean()}
          | {:timeout, timeout()}

  @doc """
  Builds a `%Blitz.Command{}` from a keyword list or map.
  """
  @spec command(keyword() | map()) :: Command.t()
  def command(attributes) do
    Command.new(attributes)
  end

  @doc """
  Runs commands in parallel and returns their results.
  """
  @spec run([command()], [run_option()]) ::
          {:ok, [Blitz.Result.t()]} | {:error, Blitz.Error.t()}
  def run(commands, opts \\ []) do
    Runner.run(commands, opts)
  end

  @doc """
  Runs commands in parallel and raises if any command fails.
  """
  @spec run!([command()], [run_option()]) :: [Blitz.Result.t()]
  def run!(commands, opts \\ []) do
    Runner.run!(commands, opts)
  end

  @doc """
  Runs staged commands as per-id pipelines without barriers between stages.

  Each stage bounds its own commands with its `:max_concurrency`, and total
  in-flight commands across all stages never exceed the largest stage
  `:max_concurrency`. A command in a later stage starts as soon as every
  same-id command in earlier stages has succeeded — it does not wait for the
  rest of the earlier stage. A failed command permanently blocks same-id
  commands in later stages, and no new commands launch after the first
  failure; in-flight commands finish and are reported.

  Returns `{:ok, results_per_stage}` when every launched command succeeds, or
  `{:error, error, results_per_stage}` where `results_per_stage` contains only
  the commands that actually ran.
  """
  @spec run_stages([stage()], [stage_option()]) ::
          {:ok, [[Blitz.Result.t()]]} | {:error, Blitz.Error.t(), [[Blitz.Result.t()]]}
  def run_stages(stages, opts \\ []) do
    Runner.run_stages(stages, opts)
  end

  @doc """
  Runs staged commands as per-id pipelines and raises if any command fails.
  """
  @spec run_stages!([stage()], [stage_option()]) :: [[Blitz.Result.t()]]
  def run_stages!(stages, opts \\ []) do
    Runner.run_stages!(stages, opts)
  end
end
