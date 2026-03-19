defmodule Blitz.MixWorkspaceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Blitz.MixWorkspace

  @gib 1_073_741_824

  test "discovers projects in configured stable order" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "core/zulu")
      create_mix_project!(root, "core/alpha")
      create_mix_project!(root, "apps/bravo")
      create_mix_project!(root, "apps/able")
      File.mkdir_p!(Path.join(root, "apps/notes"))

      workspace =
        workspace_config(root,
          projects: [".", "core/*", "apps/*"]
        )

      assert MixWorkspace.project_paths(workspace) == [
               ".",
               "core/alpha",
               "core/zulu",
               "apps/able",
               "apps/bravo"
             ]

      assert MixWorkspace.package_paths(workspace) == [
               "core/alpha",
               "core/zulu",
               "apps/able",
               "apps/bravo"
             ]
    end)
  end

  test "builds task args with color support and respects explicit color flags" do
    workspace = workspace_config("/tmp/workspace")

    assert MixWorkspace.task_args(workspace, :test, ["--seed", "0"]) == [
             "test",
             "--color",
             "--seed",
             "0"
           ]

    assert MixWorkspace.task_args(workspace, :test, ["--no-color", "--seed", "0"]) == [
             "test",
             "--no-color",
             "--seed",
             "0"
           ]

    assert MixWorkspace.task_args(workspace, :compile, []) == [
             "compile",
             "--warnings-as-errors"
           ]
  end

  test "builds isolated command env and merges task-specific env" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, "apps/demo")

      workspace =
        workspace_config(root,
          tasks: [
            deps_get: [args: ["deps.get"], preflight?: false],
            test: [
              args: ["test"],
              mix_env: "test",
              color: true,
              env: &test_database_env/1
            ]
          ]
        )

      env = MixWorkspace.command_env(workspace, "apps/demo", :test) |> Map.new()
      project_root = Path.join(root, "apps/demo")

      assert env["MIX_DEPS_PATH"] == Path.join(project_root, "deps")
      assert env["MIX_BUILD_PATH"] == Path.join(project_root, "_build/test")
      assert env["MIX_LOCKFILE"] == Path.join(project_root, "mix.lock")
      assert env["HEX_HOME"] == Path.join(project_root, "_build/hex")
      assert env["HEX_API_KEY"] == nil

      assert env["PGDATABASE"] ==
               MixWorkspace.hashed_project_name("workspace_test", "apps/demo", max_bytes: 63)
    end)
  end

  test "plans preflight deps and task stages with task-specific concurrency" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".", mix_lock?: true)
      create_mix_project!(root, "apps/alpha", mix_lock?: true)
      create_mix_project!(root, "apps/bravo", mix_lock?: true, deps?: true)

      workspace =
        workspace_config(root,
          parallelism: [
            base: [deps_get: 3, test: 2],
            multiplier: 2
          ]
        )

      assert [
               %{task: :deps_get, max_concurrency: 6, commands: dep_commands},
               %{task: :test, max_concurrency: 4, commands: test_commands}
             ] = MixWorkspace.plan(workspace, :test, [])

      assert Enum.map(dep_commands, & &1.id) == [".", "apps/alpha"]
      assert Enum.map(test_commands, & &1.id) == [".", "apps/alpha", "apps/bravo"]
    end)
  end

  test "autodetects a machine-class multiplier from schedulers and memory" do
    assert MixWorkspace.autodetect_multiplier(schedulers_online: 4, memory_bytes: 8 * @gib) == 1
    assert MixWorkspace.autodetect_multiplier(schedulers_online: 16, memory_bytes: 32 * @gib) == 2

    assert MixWorkspace.autodetect_multiplier(schedulers_online: 24, memory_bytes: 160 * @gib) ==
             4

    assert MixWorkspace.autodetect_multiplier(schedulers_online: 32, memory_bytes: 256 * @gib) ==
             6

    assert MixWorkspace.autodetect_multiplier(schedulers_online: 24, memory_bytes: nil) == 4
  end

  test "uses auto multiplier by default when none is configured" do
    workspace =
      workspace_config("/tmp/workspace",
        parallelism: [
          base: [test: 2],
          overrides: []
        ]
      )

    assert MixWorkspace.max_concurrency(workspace, :test) ==
             2 * MixWorkspace.autodetect_multiplier()
  end

  test "falls back to 1 when a task has no configured base count" do
    workspace =
      workspace_config("/tmp/workspace",
        parallelism: [
          base: [test: 2],
          overrides: []
        ]
      )

    assert MixWorkspace.max_concurrency(workspace, :credo) == 1
  end

  test "cli runner override applies to every stage" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".", mix_lock?: true)
      create_mix_project!(root, "apps/alpha", mix_lock?: true)

      workspace = workspace_config(root)

      assert [
               %{max_concurrency: 7},
               %{max_concurrency: 7}
             ] = MixWorkspace.plan(workspace, :test, ["-j", "7"])
    end)
  end

  test "runs mix test across the workspace with prefixed colored output" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".", tests?: true)
      create_mix_project!(root, "apps/alpha", tests?: true)

      workspace =
        workspace_config(root,
          projects: [".", "apps/*"],
          parallelism: [
            base: [deps_get: 1, test: 1],
            multiplier: 1
          ]
        )

      output =
        capture_io(fn ->
          assert :ok = MixWorkspace.run!(workspace, :test, [])
        end)

      assert output =~ "==> .: mix test --color"
      assert output =~ "==> apps/alpha: mix test --color"
      assert output =~ "\e["
    end)
  end

  test "generic mix task can run multiple workspace stages in one process" do
    with_tmp_workspace(fn root ->
      File.mkdir_p!(Path.join(root, "lib"))

      File.write!(
        Path.join(root, ".formatter.exs"),
        "[inputs: [\"{mix,.formatter}.exs\", \"lib/**/*.{ex,exs}\"]]\n"
      )

      File.write!(
        Path.join(root, "mix.exs"),
        """
        defmodule SampleWorkspace.MixProject do
          use Mix.Project

          def project do
            [
              app: :sample_workspace,
              version: "0.1.0",
              elixir: "~> 1.18",
              deps: [{:blitz, path: #{inspect(File.cwd!())}}],
              blitz_workspace: [
                root: __DIR__,
                projects: ["."],
                parallelism: [base: [format: 1, compile: 1], multiplier: 1],
                tasks: [
                  format: [args: ["format"]],
                  compile: [args: ["compile", "--warnings-as-errors"]]
                ]
              ]
            ]
          end
        end
        """
      )

      File.write!(
        Path.join(root, "lib/sample_workspace.ex"),
        """
        defmodule SampleWorkspace do
          def ok?, do: true
        end
        """
      )

      {output, 0} =
        System.cmd(
          "mix",
          [
            "run",
            "-e",
            ~s|Mix.Task.run("blitz.workspace", ["format"]); Mix.Task.run("blitz.workspace", ["compile"])|
          ],
          cd: root,
          stderr_to_stdout: true
        )

      assert output =~ "==> .: mix format"
      assert output =~ "==> .: mix compile --warnings-as-errors"
    end)
  end

  defp workspace_config(root, overrides \\ []) do
    config = [
      root: root,
      projects: [".", "apps/*"],
      parallelism: [
        base: [deps_get: 3, format: 4, compile: 2, test: 2, credo: 2, dialyzer: 1, docs: 1],
        multiplier: 2,
        overrides: []
      ],
      tasks: [
        deps_get: [args: ["deps.get"], preflight?: false],
        format: [args: ["format"]],
        compile: [args: ["compile", "--warnings-as-errors"]],
        test: [args: ["test"], mix_env: "test", color: true],
        credo: [args: ["credo"]],
        dialyzer: [args: ["dialyzer", "--force-check"]],
        docs: [args: ["docs"]]
      ]
    ]

    Keyword.merge(config, overrides)
  end

  defp test_database_env(%{project_path: project_path}) do
    [
      {"PGDATABASE",
       MixWorkspace.hashed_project_name("workspace_test", project_path, max_bytes: 63)}
    ]
  end

  defp with_tmp_workspace(fun) do
    root =
      System.tmp_dir!()
      |> Path.join("blitz_workspace_#{System.unique_integer([:positive])}")

    File.rm_rf!(root)
    File.mkdir_p!(root)

    try do
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end

  defp create_mix_project!(workspace_root, relative_path, opts \\ []) do
    project_root =
      case relative_path do
        "." -> workspace_root
        path -> Path.join(workspace_root, path)
      end

    File.mkdir_p!(Path.join(project_root, "lib"))
    File.write!(Path.join(project_root, "mix.exs"), mix_project_source(relative_path))

    if Keyword.get(opts, :tests?, false) do
      app_slug = app_slug(relative_path)
      module_name = module_name(relative_path)

      File.mkdir_p!(Path.join(project_root, "test"))
      File.write!(Path.join(project_root, "test/test_helper.exs"), "ExUnit.start()\n")

      File.write!(
        Path.join(project_root, "test/#{app_slug}_test.exs"),
        """
        defmodule #{module_name}.WorkspaceTest do
          use ExUnit.Case, async: true

          test "passes" do
            assert 1 + 1 == 2
          end
        end
        """
      )
    end

    if Keyword.get(opts, :mix_lock?, false) do
      File.write!(Path.join(project_root, "mix.lock"), "%{}\n")
    end

    if Keyword.get(opts, :deps?, false) do
      File.mkdir_p!(Path.join(project_root, "deps"))
    end
  end

  defp mix_project_source(relative_path) do
    module_name = module_name(relative_path)
    app_slug = app_slug(relative_path)

    """
    defmodule #{module_name}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{app_slug},
          version: "0.1.0",
          elixir: "~> 1.18",
          deps: []
        ]
      end
    end
    """
  end

  defp module_name(relative_path) do
    relative_path
    |> String.replace(".", "root")
    |> String.split(~r/[^a-zA-Z0-9]+/u, trim: true)
    |> Enum.map_join(&String.capitalize/1)
  end

  defp app_slug(relative_path) do
    relative_path
    |> String.replace(".", "root")
    |> String.replace(~r/[^a-zA-Z0-9]+/u, "_")
    |> String.trim("_")
    |> String.downcase()
  end
end
