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
    output_tail_table = :ets.new(__MODULE__, [:set, :public])
    started_at_table = :ets.new(__MODULE__, [:set, :public])

    results =
      try do
        commands
        |> Enum.map(&Command.new/1)
        |> Enum.with_index()
        |> Task.async_stream(&run_command(&1, options, output_tail_table, started_at_table),
          max_concurrency: options.max_concurrency,
          ordered: false,
          on_timeout: :kill_task,
          timeout: options.timeout,
          zip_input_on_exit: true
        )
        |> Enum.map(&unwrap_stream_result(&1, options, output_tail_table, started_at_table))
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))
      after
        :ets.delete(output_tail_table)
        :ets.delete(started_at_table)
      end

    case Enum.any?(results, &Result.failed?/1) do
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

  defp run_command({command, index}, options, output_tail_table, started_at_table) do
    started_at = System.monotonic_time(:millisecond)
    :ets.insert(started_at_table, {index, started_at})

    announce_command(command, options)

    output_buffer =
      OutputBuffer.new(command.id,
        prefix_output?: options.prefix_output?,
        tail_store: output_tail_table,
        tail_store_key: index
      )

    result =
      command
      |> execute_command(output_buffer)
      |> build_result(command, started_at)

    announce_completion(result, options)

    {index, result}
  end

  defp unwrap_stream_result({:ok, result}, _options, _output_tail_table, _started_at_table),
    do: result

  defp unwrap_stream_result(
         {:exit, {{command, index}, reason}},
         options,
         output_tail_table,
         started_at_table
       ) do
    duration_ms = duration_ms(index, started_at_table)
    output_tail = OutputBuffer.tail_from_store(output_tail_table, index)

    result =
      case reason do
        :timeout ->
          Result.timeout(command, duration_ms, output_tail, options.timeout)

        _reason ->
          Result.worker_crash(command, duration_ms, output_tail, format_exit_reason(reason))
      end

    announce_completion(result, options)

    {index, result}
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
    status = completion_status(result)

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

  defp execute_command(command, output_buffer) do
    {output_buffer, exit_code} =
      System.cmd(command.command, command.args, system_cmd_options(command, output_buffer))

    {:ok, output_buffer, exit_code}
  rescue
    error ->
      message = Exception.format_banner(:error, error)

      output_buffer =
        output_buffer
        |> OutputBuffer.emit(message)
        |> OutputBuffer.flush()

      {:startup_error, output_buffer, message}
  catch
    kind, reason ->
      message = Exception.format_banner(kind, reason)

      output_buffer =
        output_buffer
        |> OutputBuffer.emit(message)
        |> OutputBuffer.flush()

      {:startup_error, output_buffer, message}
  end

  defp build_result({:ok, output_buffer, exit_code}, command, started_at) do
    Result.from_command(
      command,
      exit_code,
      System.monotonic_time(:millisecond) - started_at,
      OutputBuffer.tail(output_buffer)
    )
  end

  defp build_result({:startup_error, output_buffer, message}, command, started_at) do
    Result.startup_error(
      command,
      System.monotonic_time(:millisecond) - started_at,
      OutputBuffer.tail(output_buffer),
      message
    )
  end

  defp completion_status(%Result{failure_kind: nil}), do: "ok"

  defp completion_status(%Result{failure_kind: :exit, exit_code: exit_code}),
    do: "failed (#{exit_code})"

  defp completion_status(%Result{failure_kind: :startup_error}), do: "command error"
  defp completion_status(%Result{failure_kind: :timeout}), do: "timed out"
  defp completion_status(%Result{failure_kind: :worker_crash}), do: "worker crashed"

  defp duration_ms(index, started_at_table) do
    started_at =
      case :ets.lookup(started_at_table, index) do
        [{^index, value}] -> value
        [] -> System.monotonic_time(:millisecond)
      end

    System.monotonic_time(:millisecond) - started_at
  end

  defp format_exit_reason(reason), do: Exception.format_banner(:exit, reason)
end
