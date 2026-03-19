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
          | {:max_concurrency, pos_integer()}
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
end
