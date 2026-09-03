defmodule Blitz.OutputBuffer do
  @moduledoc false

  @default_tail_limit 50

  defstruct [
    :id,
    :output_device,
    :output_path,
    :tail_store,
    :tail_store_key,
    emit_output?: true,
    prefix_output?: true,
    buffer: "",
    tail_limit: @default_tail_limit,
    tail_lines: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          output_device: IO.device() | nil,
          output_path: String.t() | nil,
          emit_output?: boolean(),
          prefix_output?: boolean(),
          buffer: String.t(),
          tail_limit: pos_integer(),
          tail_lines: [String.t()],
          tail_store: :ets.tid() | nil,
          tail_store_key: term()
        }

  @spec new(String.t(), keyword()) :: t()
  def new(id, opts) do
    output_path = Keyword.get(opts, :output_path)

    state = %__MODULE__{
      id: id,
      emit_output?: Keyword.get(opts, :emit_output?, true),
      prefix_output?: Keyword.get(opts, :prefix_output?, true),
      tail_limit: Keyword.get(opts, :tail_limit, @default_tail_limit),
      tail_store: Keyword.get(opts, :tail_store),
      tail_store_key: Keyword.get(opts, :tail_store_key),
      output_path: output_path,
      output_device: open_output(output_path)
    }

    sync_tail_store(state)
  end

  @spec emit(t(), iodata()) :: t()
  def emit(%__MODULE__{} = state, data) do
    bytes = IO.iodata_to_binary(data)
    write_output(state, bytes)

    bytes
    |> String.replace("\r\n", "\n")
    |> then(&flush_chunks(state, &1))
  end

  @spec flush(t()) :: t()
  def flush(%__MODULE__{buffer: ""} = state), do: state

  def flush(%__MODULE__{} = state) do
    write_line(state, state.buffer)

    state
    |> remember_line(state.buffer)
    |> Map.put(:buffer, "")
  end

  @spec tail(t()) :: [String.t()]
  def tail(%__MODULE__{tail_lines: tail_lines}), do: tail_lines

  @spec tail_from_store(:ets.tid(), term()) :: [String.t()]
  def tail_from_store(table, key) do
    case :ets.lookup(table, key) do
      [{^key, tail_lines}] -> tail_lines
      [] -> []
    end
  end

  @spec close(t()) :: t()
  def close(%__MODULE__{output_device: nil} = state), do: state

  def close(%__MODULE__{output_device: device} = state) do
    _ = File.close(device)
    %{state | output_device: nil}
  end

  defimpl Collectable do
    def into(initial) do
      collector = fn
        state, {:cont, data} ->
          Blitz.OutputBuffer.emit(state, data)

        state, :done ->
          state |> Blitz.OutputBuffer.flush() |> Blitz.OutputBuffer.close()

        state, :halt ->
          Blitz.OutputBuffer.close(state)
          :ok
      end

      {initial, collector}
    end
  end

  defp flush_chunks(state, chunk) do
    [trailing | completed] =
      (state.buffer <> chunk)
      |> String.split("\n", trim: false)
      |> Enum.reverse()

    state =
      completed
      |> Enum.reverse()
      |> Enum.reduce(state, &emit_line(&2, &1))

    %{state | buffer: trailing}
  end

  defp emit_line(state, line) do
    write_line(state, line)
    remember_line(state, line)
  end

  defp remember_line(%__MODULE__{} = state, line) do
    tail_lines =
      state.tail_lines
      |> Kernel.++([line])
      |> Enum.take(-state.tail_limit)

    state
    |> Map.put(:tail_lines, tail_lines)
    |> sync_tail_store()
  end

  defp sync_tail_store(%__MODULE__{tail_store: nil} = state), do: state

  defp sync_tail_store(%__MODULE__{tail_store_key: nil} = state), do: state

  defp sync_tail_store(%__MODULE__{} = state) do
    :ets.insert(state.tail_store, {state.tail_store_key, state.tail_lines})
    state
  end

  defp open_output(nil), do: nil

  defp open_output(path) do
    File.mkdir_p!(Path.dirname(path))
    File.open!(path, [:write, :binary])
  end

  defp write_output(%__MODULE__{output_device: nil}, _bytes), do: :ok
  defp write_output(%__MODULE__{output_device: device}, bytes), do: IO.binwrite(device, bytes)

  defp write_line(%__MODULE__{emit_output?: false}, _line), do: :ok

  defp write_line(%__MODULE__{id: id, prefix_output?: true}, line) do
    IO.write("#{id} | #{line}\n")
  end

  defp write_line(%__MODULE__{prefix_output?: false}, line) do
    IO.write("#{line}\n")
  end
end
