defmodule Blitz.TestState.Json do
  @moduledoc false

  def encode!(value), do: encode(value)

  defp encode(map) when is_map(map) do
    contents =
      map
      |> Enum.map(fn {key, value} -> {key_to_string(key), value} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, value} -> encode(key) <> ":" <> encode(value) end)

    "{" <> contents <> "}"
  end

  defp encode(list) when is_list(list) do
    "[" <> Enum.map_join(list, ",", &encode/1) <> "]"
  end

  defp encode(true), do: "true"
  defp encode(false), do: "false"
  defp encode(nil), do: "null"

  defp encode(binary) when is_binary(binary) do
    "\"" <> escape(binary) <> "\""
  end

  defp encode(atom) when is_atom(atom), do: encode(Atom.to_string(atom))
  defp encode(integer) when is_integer(integer), do: Integer.to_string(integer)
  defp encode(float) when is_float(float), do: Float.to_string(float)

  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key), do: inspect(key)

  defp escape(binary) do
    binary
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end
end
