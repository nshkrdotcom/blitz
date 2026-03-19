defmodule Blitz.OutputBuffer do
  @moduledoc false

  defstruct [:id, prefix_output?: true, buffer: ""]

  @type t :: %__MODULE__{
          id: String.t(),
          prefix_output?: boolean(),
          buffer: String.t()
        }

  @spec new(String.t(), keyword()) :: t()
  def new(id, opts) do
    %__MODULE__{
      id: id,
      prefix_output?: Keyword.get(opts, :prefix_output?, true)
    }
  end

  @spec emit(t(), iodata()) :: t()
  def emit(%__MODULE__{} = state, data) do
    data
    |> IO.iodata_to_binary()
    |> String.replace("\r\n", "\n")
    |> then(&flush_chunks(state, &1))
  end

  @spec flush(t()) :: t()
  def flush(%__MODULE__{buffer: ""} = state), do: state

  def flush(%__MODULE__{} = state) do
    write_line(state, state.buffer)
    %{state | buffer: ""}
  end

  defimpl Collectable do
    def into(initial) do
      collector = fn
        state, {:cont, data} -> Blitz.OutputBuffer.emit(state, data)
        state, :done -> Blitz.OutputBuffer.flush(state)
        _state, :halt -> :ok
      end

      {initial, collector}
    end
  end

  defp flush_chunks(state, chunk) do
    [trailing | completed] =
      (state.buffer <> chunk)
      |> String.split("\n", trim: false)
      |> Enum.reverse()

    completed
    |> Enum.reverse()
    |> Enum.each(&write_line(state, &1))

    %{state | buffer: trailing}
  end

  defp write_line(%__MODULE__{id: id, prefix_output?: true}, line) do
    IO.write("#{id} | #{line}\n")
  end

  defp write_line(%__MODULE__{prefix_output?: false}, line) do
    IO.write("#{line}\n")
  end
end
