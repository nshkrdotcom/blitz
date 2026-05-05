defmodule Blitz.TestState.Hash do
  @moduledoc false

  @spec hash(term(), term()) :: String.t()
  def hash(schema, value) do
    payload = {:blitz_test_state_hash, to_string(schema), canonical(value)}

    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(payload))
      |> Base.encode16(case: :lower)

    "sha256:" <> digest
  end

  @spec short(String.t()) :: String.t()
  def short("sha256:" <> digest), do: binary_part(digest, 0, min(byte_size(digest), 12))
  def short(value), do: binary_part(value, 0, min(byte_size(value), 12))

  defp canonical(%_struct{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.put(:__struct__, struct.__struct__)
    |> canonical()
  end

  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {canonical_key(key), canonical(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(list) when is_list(list) do
    if Keyword.keyword?(list) do
      list
      |> Enum.map(fn {key, value} -> {canonical_key(key), canonical(value)} end)
      |> Enum.sort_by(&elem(&1, 0))
    else
      Enum.map(list, &canonical/1)
    end
  end

  defp canonical(tuple) when is_tuple(tuple) do
    {:tuple, tuple |> Tuple.to_list() |> Enum.map(&canonical/1)}
  end

  defp canonical(fun) when is_function(fun) do
    info = Map.new(:erlang.fun_info(fun))

    {:function,
     %{
       module: Map.get(info, :module),
       name: Map.get(info, :name),
       arity: Map.get(info, :arity),
       type: Map.get(info, :type)
     }}
  end

  defp canonical(boolean) when is_boolean(boolean), do: {:boolean, boolean}
  defp canonical(nil), do: nil
  defp canonical(atom) when is_atom(atom), do: {:atom, Atom.to_string(atom)}
  defp canonical(binary) when is_binary(binary), do: {:binary, binary}
  defp canonical(integer) when is_integer(integer), do: {:integer, integer}
  defp canonical(float) when is_float(float), do: {:float, float}
  defp canonical(value), do: {:inspect, inspect(value)}

  defp canonical_key(key) when is_atom(key), do: "atom:" <> Atom.to_string(key)
  defp canonical_key(key) when is_binary(key), do: "binary:" <> key
  defp canonical_key(key), do: "term:" <> inspect(key)
end
