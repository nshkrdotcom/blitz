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
    failures = Enum.filter(results, &Result.failed?/1)

    %__MODULE__{
      message: build_message(failures),
      failures: failures,
      results: results
    }
  end

  defp build_message(failures) do
    failures
    |> Enum.map_join("\n\n", &render_failure/1)
    |> then(&"parallel command run failed:\n\n#{&1}")
  end

  defp render_failure(result) do
    [
      "  #{result.id}",
      "    #{failure_summary(result)}",
      render_cwd(result),
      "    cmd: #{Result.command_line(result)}",
      "    duration: #{result.duration_ms}ms",
      render_reason(result),
      "    output tail:",
      render_output_tail(result)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp failure_summary(%Result{failure_kind: :exit, exit_code: exit_code}),
    do: "exit: #{exit_code}"

  defp failure_summary(%Result{failure_kind: :startup_error}),
    do: "failure: command failed to start"

  defp failure_summary(%Result{failure_kind: :timeout}), do: "failure: timed out"
  defp failure_summary(%Result{failure_kind: :worker_crash}), do: "failure: worker crashed"

  defp render_cwd(%Result{cd: nil}), do: nil
  defp render_cwd(%Result{cd: cd}), do: "    cwd: #{cd}"

  defp render_reason(%Result{failure_reason: nil}), do: nil
  defp render_reason(%Result{failure_reason: reason}), do: "    reason: #{reason}"

  defp render_output_tail(%Result{output_tail: []}), do: "      <no output captured>"

  defp render_output_tail(%Result{output_tail: output_tail}) do
    Enum.map_join(output_tail, "\n", &"      #{&1}")
  end
end
