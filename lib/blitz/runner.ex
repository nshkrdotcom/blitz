defmodule Blitz.Runner do
  @moduledoc false

  alias Blitz.{Command, Error, OutputBuffer, Result}

  @type option ::
          {:announce?, boolean()}
          | {:max_concurrency, pos_integer()}
          | {:prefix_output?, boolean()}
          | {:timeout, timeout()}

  @spec run([Command.t()], [option()]) ::
          {:ok, [Result.t()]} | {:error, Error.t()}
  def run(commands, opts \\ []) do
    options = normalize_options(opts)

    results =
      commands
      |> Enum.map(&Command.new/1)
      |> Enum.with_index()
      |> Task.async_stream(&run_command(&1, options),
        max_concurrency: options.max_concurrency,
        ordered: false,
        timeout: options.timeout
      )
      |> Enum.map(&unwrap_stream_result/1)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    case Enum.any?(results, &(&1.exit_code != 0)) do
      true -> {:error, Error.new(results)}
      false -> {:ok, results}
    end
  end

  @spec run!([Command.t()], [option()]) :: [Result.t()]
  def run!(commands, opts \\ []) do
    case run(commands, opts) do
      {:ok, results} -> results
      {:error, error} -> raise error
    end
  end

  defp run_command({command, index}, options) do
    announce_command(command, options)

    output_buffer = OutputBuffer.new(command.id, prefix_output?: options.prefix_output?)
    started_at = System.monotonic_time(:millisecond)

    exit_code =
      try do
        {_, code} =
          System.cmd(command.command, command.args, system_cmd_options(command, output_buffer))

        code
      rescue
        error ->
          message = Exception.message(error)

          output_buffer
          |> OutputBuffer.emit(message)
          |> OutputBuffer.flush()

          127
      end

    duration_ms = System.monotonic_time(:millisecond) - started_at
    result = Result.from_command(command, exit_code, duration_ms)

    announce_completion(result, options)

    {index, result}
  end

  defp unwrap_stream_result({:ok, result}), do: result

  defp unwrap_stream_result({:exit, reason}) do
    raise "parallel worker crashed: #{inspect(reason)}"
  end

  defp announce_command(command, %{announce?: false}), do: command

  defp announce_command(command, _options) do
    rendered_args =
      case Enum.join(command.args, " ") do
        "" -> ""
        args -> " #{args}"
      end

    IO.puts("==> #{command.id}: #{command.command}#{rendered_args}")
  end

  defp announce_completion(_result, %{announce?: false}), do: :ok

  defp announce_completion(result, _options) do
    status =
      case result.exit_code do
        0 -> "ok"
        exit_code -> "failed (#{exit_code})"
      end

    IO.puts("<== #{result.id}: #{status} in #{result.duration_ms}ms")
  end

  defp normalize_options(opts) do
    max_concurrency =
      opts
      |> Keyword.get(:max_concurrency, System.schedulers_online())
      |> normalize_max_concurrency!()

    %{
      announce?: Keyword.get(opts, :announce?, true),
      max_concurrency: max_concurrency,
      prefix_output?: Keyword.get(opts, :prefix_output?, true),
      timeout: Keyword.get(opts, :timeout, :infinity)
    }
  end

  defp normalize_max_concurrency!(max_concurrency)
       when is_integer(max_concurrency) and max_concurrency > 0 do
    max_concurrency
  end

  defp normalize_max_concurrency!(max_concurrency) do
    raise ArgumentError,
          "expected :max_concurrency to be a positive integer, got: #{inspect(max_concurrency)}"
  end

  defp system_cmd_options(command, output_buffer) do
    base_options = [into: output_buffer, stderr_to_stdout: true]

    base_options
    |> maybe_put_option(:cd, command.cd)
    |> maybe_put_option(:env, command.env)
  end

  defp maybe_put_option(options, _key, nil), do: options
  defp maybe_put_option(options, _key, []), do: options
  defp maybe_put_option(options, key, value), do: Keyword.put(options, key, value)
end
