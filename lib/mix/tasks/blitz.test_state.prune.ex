defmodule Mix.Tasks.Blitz.TestState.Prune do
  use Mix.Task

  alias Blitz.TestState.Store

  @moduledoc """
  Prune compact Blitz test-state artifacts.

  Usage:

      mix blitz.test_state.prune
      mix blitz.test_state.prune --store-dir /tmp/blitz-test-state
  """

  @shortdoc "Prune compact Blitz test-state artifacts"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          store_dir: :string,
          root: :string
        ]
      )

    validate_invalid!(invalid)
    validate_positional!(positional)

    root = opts[:root] || File.cwd!()
    store = Store.new(root, opts)
    Store.prune!(store)

    Mix.shell().info("Pruned Blitz test state at #{store.root}")
  after
    Mix.Task.reenable("blitz.test_state.prune")
  end

  defp validate_invalid!([]), do: :ok

  defp validate_invalid!(invalid) do
    Mix.raise("Invalid options: #{inspect(invalid)}")
  end

  defp validate_positional!([]), do: :ok

  defp validate_positional!(positional) do
    Mix.raise("Unexpected arguments: #{Enum.join(positional, " ")}")
  end
end
