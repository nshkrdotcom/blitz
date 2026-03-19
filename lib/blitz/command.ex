defmodule Blitz.Command do
  @moduledoc """
  Command specification for `Blitz`.
  """

  @enforce_keys [:id, :command]
  defstruct [:id, :command, args: [], cd: nil, env: []]

  @type env_value :: String.t() | nil
  @type env_pair :: {String.t(), env_value()}

  @type t :: %__MODULE__{
          id: String.t(),
          command: String.t(),
          args: [String.t()],
          cd: String.t() | nil,
          env: [env_pair()]
        }

  @doc """
  Builds a `%Blitz.Command{}` from a keyword list or map.
  """
  @spec new(keyword() | map()) :: t()
  def new(attributes) when is_list(attributes) do
    attributes
    |> Enum.into(%{})
    |> new()
  end

  def new(%__MODULE__{} = command), do: command

  def new(attributes) when is_map(attributes) do
    %__MODULE__{
      id: attributes |> fetch!(:id) |> to_string(),
      command: attributes |> fetch!(:command) |> to_string(),
      args: attributes |> Map.get(:args, []) |> Enum.map(&to_string/1),
      cd: optional_string(attributes, :cd),
      env: normalize_env(Map.get(attributes, :env, []))
    }
  end

  defp fetch!(attributes, key) do
    case Map.fetch(attributes, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "missing required command field #{inspect(key)}"
    end
  end

  defp optional_string(attributes, key) do
    case Map.get(attributes, key) do
      nil -> nil
      value -> to_string(value)
    end
  end

  defp normalize_env(environment) when is_map(environment) do
    environment
    |> Enum.map(fn {key, value} ->
      {to_string(key), normalize_env_value(value)}
    end)
  end

  defp normalize_env(environment) when is_list(environment) do
    Enum.map(environment, fn {key, value} ->
      {to_string(key), normalize_env_value(value)}
    end)
  end

  defp normalize_env_value(nil), do: nil
  defp normalize_env_value(value), do: to_string(value)
end
