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
