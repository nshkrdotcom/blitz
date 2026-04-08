defmodule Blitz.Result do
  @moduledoc """
  Result metadata for a completed command.
  """

  alias Blitz.Command

  @type failure_kind :: :exit | :startup_error | :timeout | :worker_crash

  defstruct [
    :id,
    :command,
    :args,
    :cd,
    :exit_code,
    :duration_ms,
    output_tail: [],
    failure_kind: nil,
    failure_reason: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          command: String.t(),
          args: [String.t()],
          cd: String.t() | nil,
          exit_code: non_neg_integer() | nil,
          duration_ms: non_neg_integer(),
          output_tail: [String.t()],
          failure_kind: failure_kind() | nil,
          failure_reason: String.t() | nil
        }

  @spec from_command(Command.t(), non_neg_integer(), non_neg_integer(), [String.t()]) :: t()
  def from_command(%Command{} = command, exit_code, duration_ms, output_tail) do
    command
    |> base_result(exit_code, duration_ms, output_tail)
    |> Map.put(:failure_kind, failure_kind_for_exit(exit_code))
  end

  @spec startup_error(Command.t(), non_neg_integer(), [String.t()], String.t()) :: t()
  def startup_error(%Command{} = command, duration_ms, output_tail, reason) do
    command
    |> base_result(nil, duration_ms, output_tail)
    |> Map.put(:failure_kind, :startup_error)
    |> Map.put(:failure_reason, reason)
  end

  @spec timeout(Command.t(), non_neg_integer(), [String.t()], timeout()) :: t()
  def timeout(%Command{} = command, duration_ms, output_tail, timeout_ms) do
    reason =
      case timeout_ms do
        :infinity -> "timeout"
        value -> "timeout after #{value}ms"
      end

    command
    |> base_result(nil, duration_ms, output_tail)
    |> Map.put(:failure_kind, :timeout)
    |> Map.put(:failure_reason, reason)
  end

  @spec worker_crash(Command.t(), non_neg_integer(), [String.t()], String.t()) :: t()
  def worker_crash(%Command{} = command, duration_ms, output_tail, reason) do
    command
    |> base_result(nil, duration_ms, output_tail)
    |> Map.put(:failure_kind, :worker_crash)
    |> Map.put(:failure_reason, reason)
  end

  @spec failed?(t()) :: boolean()
  def failed?(%__MODULE__{failure_kind: failure_kind}), do: not is_nil(failure_kind)

  @spec command_line(t()) :: String.t()
  def command_line(%__MODULE__{command: command, args: args}) do
    [command | args]
    |> Enum.map_join(" ", &render_command_segment/1)
  end

  defp base_result(%Command{} = command, exit_code, duration_ms, output_tail) do
    %__MODULE__{
      id: command.id,
      command: command.command,
      args: command.args,
      cd: command.cd,
      exit_code: exit_code,
      duration_ms: duration_ms,
      output_tail: output_tail
    }
  end

  defp failure_kind_for_exit(0), do: nil
  defp failure_kind_for_exit(_exit_code), do: :exit

  defp render_command_segment(segment) do
    if String.match?(segment, ~r"^[A-Za-z0-9_@%+=:,./-]+$"u) do
      segment
    else
      inspect(segment)
    end
  end
end
