defmodule Blitz.Error do
  @moduledoc """
  Raised when one or more parallel commands fail.
  """

  defexception [:message, :failures, :results]

  alias Blitz.Result

  @type t :: %__MODULE__{
          message: String.t(),
          failures: [Result.t()],
          results: [Result.t()]
        }

  @spec new([Result.t()]) :: t()
  def new(results) do
    failures = Enum.filter(results, &(&1.exit_code != 0))

    %__MODULE__{
      message: build_message(failures),
      failures: failures,
      results: results
    }
  end

  defp build_message(failures) do
    summary =
      failures
      |> Enum.map_join("\n", fn result ->
        "  #{result.id}: exit code #{result.exit_code}"
      end)

    "parallel command run failed:\n#{summary}"
  end
end
