defmodule Blitz.Result do
  @moduledoc """
  Result metadata for a completed command.
  """

  alias Blitz.Command

  defstruct [:id, :command, :args, :cd, :exit_code, :duration_ms]

  @type t :: %__MODULE__{
          id: String.t(),
          command: String.t(),
          args: [String.t()],
          cd: String.t() | nil,
          exit_code: non_neg_integer(),
          duration_ms: non_neg_integer()
        }

  @spec from_command(Command.t(), non_neg_integer(), non_neg_integer()) :: t()
  def from_command(%Command{} = command, exit_code, duration_ms) do
    %__MODULE__{
      id: command.id,
      command: command.command,
      args: command.args,
      cd: command.cd,
      exit_code: exit_code,
      duration_ms: duration_ms
    }
  end
end
