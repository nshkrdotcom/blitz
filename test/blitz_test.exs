defmodule BlitzTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  alias Blitz.{Command, Error}

  test "runs commands in parallel and preserves input result order" do
    elixir = System.find_executable("elixir")

    commands = [
      Command.new(
        id: "slow",
        command: elixir,
        args: ["-e", ~s|Process.sleep(50); IO.puts("slow")|]
      ),
      Command.new(
        id: "fast",
        command: elixir,
        args: ["-e", ~s|IO.puts("fast")|]
      )
    ]

    output =
      capture_io(fn ->
        assert {:ok, [slow, fast]} = Blitz.run(commands, max_concurrency: 2)
        assert Enum.map([slow, fast], & &1.id) == ["slow", "fast"]
        assert slow.exit_code == 0
        assert fast.exit_code == 0
      end)

    assert output =~ "slow | slow"
    assert output =~ "fast | fast"
  end

  test "can retain output tails without emitting child output" do
    command =
      Command.new(
        id: "quiet",
        command: System.find_executable("elixir"),
        args: ["-e", ~s|IO.puts("retained")|]
      )

    output =
      capture_io(fn ->
        assert {:ok, [result]} =
                 Blitz.run([command], announce?: false, emit_output?: false)

        assert result.output_tail == ["retained"]
      end)

    assert output == ""
  end

  test "can retain complete child output in a durable command log" do
    root = Path.join(System.tmp_dir!(), "blitz-output-#{System.unique_integer([:positive])}")
    output_path = Path.join(root, "nested/command.log")

    on_exit(fn -> File.rm_rf!(root) end)

    command =
      Command.new(
        id: "durable",
        command: System.find_executable("elixir"),
        args: ["-e", ~s|IO.puts("stdout"); IO.puts(:stderr, "stderr")|],
        output_path: output_path
      )

    emitted =
      capture_io(fn ->
        assert {:ok, [result]} =
                 Blitz.run([command], announce?: false, emit_output?: false)

        assert result.output_path == output_path
        assert result.output_tail == ["stdout", "stderr"]
      end)

    assert emitted == ""
    assert File.read!(output_path) == "stdout\nstderr\n"
  end

  test "returns a structured error when commands fail" do
    elixir = System.find_executable("elixir")
    cwd = System.tmp_dir!()

    commands = [
      Blitz.command(
        id: "ok",
        command: elixir,
        args: ["-e", ~s|IO.puts("ok")|]
      ),
      Blitz.command(
        id: "boom",
        command: elixir,
        args: ["-e", ~s|IO.puts("first"); IO.puts("second"); System.halt(3)|],
        cd: cwd
      )
    ]

    capture_io(fn ->
      assert {:error, %Error{} = error} = Blitz.run(commands, max_concurrency: 2)
      assert [failure] = error.failures
      assert failure.id == "boom"
      assert failure.command == elixir
      assert failure.cd == cwd
      assert failure.exit_code == 3
      assert failure.failure_kind == :exit
      assert failure.duration_ms >= 0
      assert failure.output_tail == ["first", "second"]

      message = Exception.message(error)
      assert message =~ "parallel command run failed:"
      assert message =~ "\n\n  boom\n"
      assert message =~ "exit: 3"
      assert message =~ "cwd: #{cwd}"
      assert message =~ "cmd: #{elixir}"
      assert message =~ "duration: "
      assert message =~ "output tail:"
      assert message =~ "first"
      assert message =~ "second"
    end)
  end

  test "raises on failure in bang variant" do
    elixir = System.find_executable("elixir")

    command =
      Blitz.command(
        id: "boom",
        command: elixir,
        args: ["-e", ~s|System.halt(4)|]
      )

    error =
      assert_raise Error, fn ->
        capture_io(fn -> Blitz.run!([command]) end)
      end

    assert Exception.message(error) =~ "parallel command run failed:"
    assert Exception.message(error) =~ "exit: 4"
    assert Exception.message(error) =~ "cmd: #{elixir}"
  end

  test "keeps only a bounded output tail for failures" do
    elixir = System.find_executable("elixir")

    command =
      Blitz.command(
        id: "tail",
        command: elixir,
        args: [
          "-e",
          ~S"""
          Enum.each(1..60, fn number -> IO.puts("line #{number}") end)
          System.halt(9)
          """
        ]
      )

    capture_io(fn ->
      assert {:error, %Error{} = error} = Blitz.run([command], announce?: false)
      assert [failure] = error.failures
      assert failure.failure_kind == :exit
      assert failure.exit_code == 9
      assert length(failure.output_tail) == 50
      assert hd(failure.output_tail) == "line 11"
      assert List.last(failure.output_tail) == "line 60"

      message = Exception.message(error)
      refute message =~ "line 10"
      assert message =~ "line 11"
      assert message =~ "line 60"
    end)
  end

  describe "run_stages/2" do
    test "starts a later stage's command before an earlier stage fully completes" do
      with_stamp_dir(fn dir ->
        stages = [
          %{
            commands: [
              stamped_command("a", dir, "a1", "0"),
              stamped_command("b", dir, "b1", "1")
            ],
            max_concurrency: 2
          },
          %{commands: [stamped_command("a", dir, "a2", "0")], max_concurrency: 2}
        ]

        capture_io(fn ->
          assert {:ok, [[a1, b1], [a2]]} = Blitz.run_stages(stages)
          assert Enum.map([a1, b1, a2], & &1.id) == ["a", "b", "a"]
          assert Enum.all?([a1, b1, a2], &(&1.exit_code == 0))
        end)

        assert stamp(dir, "a2", :start) < stamp(dir, "b1", :end)
      end)
    end

    test "never starts a command before its same-id upstream command ends" do
      with_stamp_dir(fn dir ->
        stages = [
          %{commands: [stamped_command("a", dir, "a1", "0.4")], max_concurrency: 4},
          %{commands: [stamped_command("a", dir, "a2", "0")], max_concurrency: 4}
        ]

        capture_io(fn ->
          assert {:ok, _results} = Blitz.run_stages(stages)
        end)

        assert stamp(dir, "a2", :start) >= stamp(dir, "a1", :end)
      end)
    end

    test "enforces per-stage max_concurrency while stages overlap" do
      with_stamp_dir(fn dir ->
        stages = [
          %{
            commands: [
              stamped_command("a", dir, "a1", "0.3"),
              stamped_command("b", dir, "b1", "0.3")
            ],
            max_concurrency: 1
          },
          %{commands: [stamped_command("a", dir, "a2", "0.3")], max_concurrency: 2}
        ]

        capture_io(fn ->
          assert {:ok, _results} = Blitz.run_stages(stages)
        end)

        first_end = min(stamp(dir, "a1", :end), stamp(dir, "b1", :end))
        second_start = max(stamp(dir, "a1", :start), stamp(dir, "b1", :start))

        assert second_start >= first_end

        assert intervals_overlap?(
                 {stamp(dir, "b1", :start), stamp(dir, "b1", :end)},
                 {stamp(dir, "a2", :start), stamp(dir, "a2", :end)}
               )
      end)
    end

    test "enforces one aggregate concurrency bound across overlapping stages" do
      with_stamp_dir(fn dir ->
        stages = [
          %{
            commands: [
              stamped_command("a", dir, "a1", "0.3"),
              stamped_command("b", dir, "b1", "0.3")
            ],
            max_concurrency: 1
          },
          %{commands: [stamped_command("a", dir, "a2", "0.3")], max_concurrency: 1}
        ]

        capture_io(fn ->
          assert {:ok, _results} = Blitz.run_stages(stages)
        end)

        b1_interval = {stamp(dir, "b1", :start), stamp(dir, "b1", :end)}
        a2_interval = {stamp(dir, "a2", :start), stamp(dir, "a2", :end)}

        refute intervals_overlap?(b1_interval, a2_interval)
      end)
    end

    test "a failure blocks same-id downstream commands and stops new launches" do
      with_stamp_dir(fn dir ->
        stages = [
          %{
            commands: [
              stamped_command("a", dir, "a1", "0", exit_code: 3),
              stamped_command("b", dir, "b1", "0.5")
            ],
            max_concurrency: 2
          },
          %{
            commands: [
              stamped_command("a", dir, "a2", "0"),
              stamped_command("b", dir, "b2", "0")
            ],
            max_concurrency: 2
          }
        ]

        capture_io(fn ->
          assert {:error, %Error{} = error, [[a1, b1], []]} = Blitz.run_stages(stages)
          assert [failure] = error.failures
          assert failure.id == "a"
          assert failure.exit_code == 3
          assert a1.id == "a"
          assert b1.id == "b"
          assert b1.exit_code == 0
        end)

        refute File.exists?(Path.join(dir, "a2.start"))
        refute File.exists?(Path.join(dir, "b2.start"))
      end)
    end

    test "announces overlapping starts before earlier-stage completions" do
      with_stamp_dir(fn dir ->
        stages = [
          %{
            commands: [
              stamped_command("a", dir, "a1", "0"),
              stamped_command("b", dir, "b1", "1")
            ],
            max_concurrency: 2
          },
          %{commands: [stamped_command("a", dir, "a2", "0")], max_concurrency: 2}
        ]

        output = capture_io(fn -> assert {:ok, _results} = Blitz.run_stages(stages) end)

        starts = :binary.matches(output, "==> ")
        {first_completion, _length} = :binary.match(output, "<== ")
        {stage2_start, _length} = :binary.match(output, "a2.start")
        {b1_completion, _length} = :binary.match(output, "<== b:")

        assert length(starts) == 3

        assert starts
               |> Enum.take(2)
               |> Enum.all?(fn {offset, _} -> offset < first_completion end)

        assert stage2_start < b1_completion
      end)
    end

    test "run_stages! returns per-stage results on success and raises on failure" do
      with_stamp_dir(fn dir ->
        stages = [%{commands: [stamped_command("a", dir, "a1", "0")], max_concurrency: 1}]

        capture_io(fn ->
          assert [[%Blitz.Result{id: "a", exit_code: 0}]] = Blitz.run_stages!(stages)
        end)

        failing = [
          %{commands: [stamped_command("a", dir, "a2", "0", exit_code: 7)], max_concurrency: 1}
        ]

        error =
          assert_raise Error, fn ->
            capture_io(fn -> Blitz.run_stages!(failing) end)
          end

        assert Exception.message(error) =~ "exit: 7"
      end)
    end
  end

  defp stamped_command(id, dir, name, sleep_seconds, opts \\ []) do
    exit_code = Keyword.get(opts, :exit_code, 0)

    script =
      "date +%s%N > #{dir}/#{name}.start; sleep #{sleep_seconds}; " <>
        "date +%s%N > #{dir}/#{name}.end; exit #{exit_code}"

    Blitz.command(id: id, command: System.find_executable("bash"), args: ["-c", script])
  end

  defp stamp(dir, name, kind) do
    dir
    |> Path.join("#{name}.#{kind}")
    |> File.read!()
    |> String.trim()
    |> String.to_integer()
  end

  defp intervals_overlap?({left_start, left_end}, {right_start, right_end}) do
    left_start < right_end and right_start < left_end
  end

  defp with_stamp_dir(fun) do
    dir =
      System.tmp_dir!()
      |> Path.join("blitz_stages_#{System.unique_integer([:positive])}")

    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    try do
      fun.(dir)
    after
      File.rm_rf!(dir)
    end
  end

  test "reports timed out workers distinctly from command exits" do
    bash = System.find_executable("bash")

    command =
      Blitz.command(
        id: "sleepy",
        command: bash,
        args: ["-lc", "echo starting; sleep 1"]
      )

    capture_io(fn ->
      assert {:error, %Error{} = error} = Blitz.run([command], announce?: false, timeout: 50)
      assert [failure] = error.failures
      assert failure.failure_kind == :timeout
      assert failure.exit_code == nil
      assert failure.duration_ms >= 0
      assert failure.output_tail == ["starting"]

      message = Exception.message(error)
      assert message =~ "parallel command run failed:"
      assert message =~ "failure: timed out"
      assert message =~ "cmd: #{bash}"
      assert message =~ "reason: timeout after 50ms"
      assert message =~ "starting"
    end)
  end
end
