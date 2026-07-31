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

  @spec run_stages([Blitz.stage()], [option()]) ::
          {:ok, [[Result.t()]]} | {:error, Error.t(), [[Result.t()]]}
  def run_stages(stages, opts \\ []) do
    stage_specs = normalize_stages!(stages)
    options = normalize_stage_options(opts, stage_specs)
    items = stage_items(stage_specs)
    output_tail_table = :ets.new(__MODULE__, [:set, :public])
    started_at_table = :ets.new(__MODULE__, [:set, :public])

    results_by_index =
      try do
        scheduler =
          Task.async(fn ->
            Process.flag(:trap_exit, true)

            %{
              options: options,
              caps: stage_caps(stage_specs),
              output_tail_table: output_tail_table,
              started_at_table: started_at_table,
              pending: items,
              running: %{},
              running_counts: %{},
              chain: initial_chain(items),
              results: %{},
              failed?: false
            }
            |> launch_ready()
            |> stage_loop()
          end)

        Task.await(scheduler, :infinity)
      after
        :ets.delete(output_tail_table)
        :ets.delete(started_at_table)
      end

    grouped = group_stage_results(stage_specs, items, results_by_index)
    completed = for item <- items, result = results_by_index[item.global_index], do: result

    case Enum.any?(completed, &Result.failed?/1) do
      true -> {:error, Error.new(completed), grouped}
      false -> {:ok, grouped}
    end
  end

  @spec run_stages!([Blitz.stage()], [option()]) :: [[Result.t()]]
  def run_stages!(stages, opts \\ []) do
    case run_stages(stages, opts) do
      {:ok, results} -> results
      {:error, error, _results} -> raise error
    end
  end

  defp normalize_stage_options(opts, stage_specs) do
    %{
      announce?: Keyword.get(opts, :announce?, true),
      max_concurrency:
        stage_specs
        |> Enum.map(& &1.max_concurrency)
        |> Enum.max(fn -> System.schedulers_online() end),
      prefix_output?: Keyword.get(opts, :prefix_output?, true),
      timeout: Keyword.get(opts, :timeout, :infinity)
    }
  end

  defp normalize_stages!(stages) do
    Enum.map(stages, fn stage ->
      %{
        commands: stage |> Map.fetch!(:commands) |> Enum.map(&Command.new/1),
        max_concurrency:
          stage
          |> Map.get(:max_concurrency, System.schedulers_online())
          |> normalize_max_concurrency!()
      }
    end)
  end

  defp stage_items(stage_specs) do
    stage_specs
    |> Enum.with_index()
    |> Enum.flat_map(fn {stage, stage_index} ->
      Enum.map(stage.commands, &%{stage_index: stage_index, command: &1})
    end)
    |> Enum.with_index()
    |> Enum.map(fn {item, global_index} -> Map.put(item, :global_index, global_index) end)
  end

  defp stage_caps(stage_specs) do
    stage_specs
    |> Enum.with_index()
    |> Map.new(fn {stage, stage_index} -> {stage_index, stage.max_concurrency} end)
  end

  defp initial_chain(items) do
    Enum.reduce(items, %{}, fn item, chain ->
      Map.update(
        chain,
        {item.stage_index, item.command.id},
        %{expected: 1, ok: 0, failed: 0},
        &%{&1 | expected: &1.expected + 1}
      )
    end)
  end

  defp upstream_status(chain, %{stage_index: stage_index, command: %Command{id: id}}) do
    0..(stage_index - 1)//1
    |> Enum.reduce_while(:ready, fn earlier_stage, _status ->
      case Map.fetch(chain, {earlier_stage, id}) do
        :error -> {:cont, :ready}
        {:ok, %{failed: failed}} when failed > 0 -> {:halt, :blocked}
        {:ok, %{expected: expected, ok: expected}} -> {:cont, :ready}
        {:ok, _incomplete} -> {:halt, :waiting}
      end
    end)
  end

  defp launch_ready(%{failed?: true} = state), do: state

  defp launch_ready(state) do
    {state, kept} =
      Enum.reduce(state.pending, {state, []}, fn item, {state, kept} ->
        case upstream_status(state.chain, item) do
          :blocked ->
            {state, kept}

          :waiting ->
            {state, [item | kept]}

          :ready ->
            launch_if_capacity(state, item, kept)
        end
      end)

    %{state | pending: Enum.reverse(kept)}
  end

  defp launch_if_capacity(state, item, kept) do
    stage_available? =
      Map.get(state.running_counts, item.stage_index, 0) <
        Map.fetch!(state.caps, item.stage_index)

    aggregate_available? = map_size(state.running) < state.options.max_concurrency

    if stage_available? and aggregate_available? do
      {launch_item(state, item), kept}
    else
      {state, [item | kept]}
    end
  end

  defp launch_item(state, item) do
    task =
      Task.async(fn ->
        run_command(
          {item.command, item.global_index},
          state.options,
          state.output_tail_table,
          state.started_at_table
        )
      end)

    timer =
      case state.options.timeout do
        :infinity -> nil
        timeout -> Process.send_after(self(), {:stage_timeout, task.ref}, timeout)
      end

    %{
      state
      | running: Map.put(state.running, task.ref, %{item: item, task: task, timer: timer}),
        running_counts: Map.update(state.running_counts, item.stage_index, 1, &(&1 + 1))
    }
  end

  defp stage_loop(%{running: running} = state) when map_size(running) == 0 do
    if state.pending == [] or state.failed? do
      state.results
    else
      raise "Blitz.Runner staged scheduler stalled with pending commands"
    end
  end

  defp stage_loop(state) do
    receive do
      {ref, {_global_index, result}} when is_map_key(state.running, ref) ->
        Process.demonitor(ref, [:flush])

        state
        |> complete_item(ref, result)
        |> launch_ready()
        |> stage_loop()

      {:DOWN, ref, :process, _pid, reason} when is_map_key(state.running, ref) ->
        %{item: item} = Map.fetch!(state.running, ref)

        result =
          Result.worker_crash(
            item.command,
            duration_ms(item.global_index, state.started_at_table),
            OutputBuffer.tail_from_store(state.output_tail_table, item.global_index),
            format_exit_reason(reason)
          )

        announce_completion(result, state.options)

        state
        |> complete_item(ref, result)
        |> launch_ready()
        |> stage_loop()

      {:stage_timeout, ref} when is_map_key(state.running, ref) ->
        %{item: item, task: task} = Map.fetch!(state.running, ref)
        Task.shutdown(task, :brutal_kill)

        result =
          Result.timeout(
            item.command,
            duration_ms(item.global_index, state.started_at_table),
            OutputBuffer.tail_from_store(state.output_tail_table, item.global_index),
            state.options.timeout
          )

        announce_completion(result, state.options)

        state
        |> complete_item(ref, result)
        |> launch_ready()
        |> stage_loop()

      {:stage_timeout, _stale_ref} ->
        stage_loop(state)

      {:EXIT, _pid, _reason} ->
        stage_loop(state)
    end
  end

  defp complete_item(state, ref, result) do
    %{item: item, timer: timer} = Map.fetch!(state.running, ref)

    if timer, do: Process.cancel_timer(timer)

    chain_key = {item.stage_index, item.command.id}
    outcome = if Result.failed?(result), do: :failed, else: :ok

    %{
      state
      | running: Map.delete(state.running, ref),
        running_counts: Map.update!(state.running_counts, item.stage_index, &(&1 - 1)),
        results: Map.put(state.results, item.global_index, result),
        chain: Map.update!(state.chain, chain_key, &Map.update!(&1, outcome, fn n -> n + 1 end)),
        failed?: state.failed? or outcome == :failed
    }
  end

  defp group_stage_results(stage_specs, items, results_by_index) do
    stage_specs
    |> Enum.with_index()
    |> Enum.map(fn {_stage, stage_index} ->
      for item <- items,
          item.stage_index == stage_index,
          result = results_by_index[item.global_index],
          do: result
    end)
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
