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

    commands = [
      Blitz.command(
        id: "ok",
        command: elixir,
        args: ["-e", ~s|IO.puts("ok")|]
      ),
      Blitz.command(
        id: "boom",
        command: elixir,
        args: ["-e", ~s|IO.puts("boom"); System.halt(3)|]
      )
    ]

    capture_io(fn ->
      assert {:error, %Error{} = error} = Blitz.run(commands, max_concurrency: 2)
      assert Enum.map(error.failures, &{&1.id, &1.exit_code}) == [{"boom", 3}]
      assert Exception.message(error) =~ "boom: exit code 3"
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

    assert_raise Error, "parallel command run failed:\n  boom: exit code 4", fn ->
      capture_io(fn -> Blitz.run!([command]) end)
    end
  end
end
