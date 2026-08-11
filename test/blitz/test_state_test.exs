defmodule Blitz.TestStateTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Blitz.Command
  alias Blitz.MixWorkspace.Impact
  alias Blitz.TestState.{Git, Hash, Store}

  test "hashing is deterministic for map key order" do
    assert Hash.hash("sample", %{b: 2, a: 1}) == Hash.hash("sample", %{a: 1, b: 2})
    refute Hash.hash("sample", [1, 2]) == Hash.hash("sample", [2, 1])
  end

  test "store coverage only follows latest passed result for exact task state" do
    with_tmp_workspace(fn root ->
      store = Store.new(root)
      task_state_hash = Hash.hash("task", %{project: "apps/demo", task: "test"})

      refute Store.covered?(store, task_state_hash)

      Store.append_result!(store, %{
        task_state_hash: task_state_hash,
        project_path: "apps/demo",
        task: "test",
        status: "passed"
      })

      assert Store.covered?(store, task_state_hash)

      Store.append_result!(store, %{
        task_state_hash: task_state_hash,
        project_path: "apps/demo",
        task: "test",
        status: "failed"
      })

      refute Store.covered?(store, task_state_hash)
    end)
  end

  test "compact store retention keeps only indexes and prunes stale artifacts" do
    with_tmp_workspace(fn root ->
      store = Store.new(root)
      kept_hash = Hash.hash("task", %{project: "apps/demo", task: "test"})
      stale_hash = Hash.hash("task", %{project: "apps/old", task: "test"})

      File.mkdir_p!(Path.join([store.root, "commits"]))
      File.mkdir_p!(Path.join([store.root, "output"]))
      File.mkdir_p!(Path.join([store.root, "indexes", "by_project"]))
      File.write!(Path.join(store.root, "results.ndjson"), "stale\n")

      Store.append_result!(store, %{
        repo_commit: "abc123",
        task_state_hash: kept_hash,
        project_path: "apps/demo",
        task: "test",
        status: "passed",
        output_tail: String.duplicate("x", 4_096)
      })

      Store.append_result!(store, %{
        task_state_hash: stale_hash,
        project_path: "apps/old",
        task: "test",
        status: "passed"
      })

      Store.prune!(store, keep_task_state_hashes: [kept_hash])

      assert Store.covered?(store, kept_hash)
      refute Store.covered?(store, stale_hash)
      refute File.exists?(Path.join(store.root, "results.ndjson"))
      refute File.exists?(Path.join(store.root, "commits"))
      refute File.exists?(Path.join(store.root, "output"))
      refute File.exists?(Path.join([store.root, "indexes", "by_project"]))
    end)
  end

  test "audit store retention keeps append streams when explicitly requested" do
    with_tmp_workspace(fn root ->
      store = Store.new(root, retention: :audit)
      task_state_hash = Hash.hash("task", %{project: "apps/demo", task: "test"})

      Store.append_result!(store, %{
        repo_commit: "abc123",
        task_state_hash: task_state_hash,
        project_path: "apps/demo",
        task: "test",
        status: "passed"
      })

      assert File.exists?(Path.join(store.root, "results.ndjson"))
      assert File.exists?(Path.join([store.root, "commits", "abc123.ndjson"]))
      assert Store.covered?(store, task_state_hash)
    end)
  end

  test "store defaults ignore process env and use explicit options" do
    with_tmp_workspace(fn root ->
      store = Store.new(root)

      audit_store =
        Store.new(root, store_dir: Path.join(root, "custom_state"), retention: "audit")

      assert store.root == Path.join(root, ".blitz/test_state_v1")
      assert store.retention == :compact
      assert audit_store.root == Path.join(root, "custom_state")
      assert audit_store.retention == :audit
    end)
  end

  test "git metadata and file discovery ignore the blitz store" do
    with_tmp_workspace(fn root ->
      git!(root, ["init"])
      git!(root, ["config", "user.email", "test@example.com"])
      git!(root, ["config", "user.name", "Test User"])

      File.write!(Path.join(root, "mix.exs"), "defmodule Demo.MixProject do\nend\n")
      git!(root, ["add", "mix.exs"])
      git!(root, ["commit", "-m", "initial"])

      File.mkdir_p!(Path.join([root, ".blitz", "test_state_v1"]))
      File.write!(Path.join([root, ".blitz", "test_state_v1", "results.ndjson"]), "{}\n")

      refute Git.metadata(root).dirty?
      assert {:ok, []} = Git.changed_files(root)
      assert {:ok, files} = Git.repo_files(root)
      refute Enum.any?(files, &String.starts_with?(&1, ".blitz/"))
    end)
  end

  test "task-specific hashes skip compile for docs-only changes" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/demo")
      workspace = workspace_config(root)
      store = Store.new(root)

      compile_hash = task_state_hash(workspace, :compile, "apps/demo")
      docs_hash = task_state_hash(workspace, :docs, "apps/demo")

      Store.append_result!(store, passed_record(compile_hash, "apps/demo", :compile))
      Store.append_result!(store, passed_record(docs_hash, "apps/demo", :docs))

      File.write!(Path.join(root, "apps/demo/README.md"), "# Demo\n\n")

      compile_decision =
        decision(workspace, :compile, "apps/demo", changed_files: ["apps/demo/README.md"])

      docs_decision =
        decision(workspace, :docs, "apps/demo", changed_files: ["apps/demo/README.md"])

      assert compile_decision.decision == :skip
      assert docs_decision.decision == :run
      assert docs_decision.reason =~ "README.md"

      Store.append_result!(
        store,
        passed_record(docs_decision.task_state_hash, "apps/demo", :docs)
      )

      covered_docs_decision =
        decision(workspace, :docs, "apps/demo", changed_files: ["apps/demo/README.md"])

      assert covered_docs_decision.decision == :skip
      assert covered_docs_decision.reason == "exact passed task state exists"
    end)
  end

  test "deps_get hash ignores lockfile output while compile keeps it" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/demo")
      workspace = workspace_config(root)

      deps_get_before = task_state_hash(workspace, :deps_get, "apps/demo")
      compile_before = task_state_hash(workspace, :compile, "apps/demo")

      File.write!(Path.join(root, "apps/demo/mix.lock"), "%{\"jason\": :updated}\n")

      assert task_state_hash(workspace, :deps_get, "apps/demo") == deps_get_before
      refute task_state_hash(workspace, :compile, "apps/demo") == compile_before
    end)
  end

  test "deps_get hash ignores local dependency source while compile keeps it" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/alpha")
      create_mix_project!(root, "apps/bravo", deps: ~s([{:apps_alpha, path: "../alpha"}]))
      workspace = workspace_config(root)

      deps_get_before = task_state_hash(workspace, :deps_get, "apps/bravo")
      compile_before = task_state_hash(workspace, :compile, "apps/bravo")

      File.write!(Path.join(root, "apps/alpha/lib/apps_alpha.ex"), """
      defmodule AppsAlpha do
        def ok?, do: :changed
      end
      """)

      assert task_state_hash(workspace, :deps_get, "apps/bravo") == deps_get_before
      refute task_state_hash(workspace, :compile, "apps/bravo") == compile_before
    end)
  end

  test "child project docs hash changes when existing child README content changes" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/demo")
      File.write!(Path.join(root, "apps/demo/README.md"), "# Demo\n\nFirst\n")

      workspace = workspace_config(root)
      docs_before = task_state_hash(workspace, :docs, "apps/demo")

      File.write!(Path.join(root, "apps/demo/README.md"), "# Demo\n\nSecond\n")

      refute task_state_hash(workspace, :docs, "apps/demo") == docs_before
    end)
  end

  test "sibling repository source changes alter external project task hashes" do
    with_tmp_workspace(fn root ->
      sibling_root = root <> "_sibling"

      try do
        create_mix_project!(root, ".")
        create_mix_project!(sibling_root, ".")
        init_git!(root)
        init_git!(sibling_root)

        workspace =
          root
          |> workspace_config()
          |> Keyword.put(:projects, [".", sibling_root])

        compile_before = task_state_hash(workspace, :compile, sibling_root)

        File.write!(Path.join(sibling_root, "lib/root.ex"), """
        defmodule Root do
          def ok?, do: :changed
        end
        """)

        refute task_state_hash(workspace, :compile, sibling_root) == compile_before
      after
        File.rm_rf!(sibling_root)
      end
    end)
  end

  test "run_many writes a clean commit manifest and skips the next identical clean pipeline before mapping commands" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      git!(root, ["init"])
      git!(root, ["config", "user.email", "test@example.com"])
      git!(root, ["config", "user.name", "Test User"])
      git!(root, ["add", "."])
      git!(root, ["commit", "-m", "initial"])

      workspace = workspace_config(root)
      parent = self()

      mapper = fn %Command{} = command ->
        send(parent, {:mapped, command.id})
        %Command{command | command: "sh", args: ["-c", "true"]}
      end

      assert [%{selected: 1, skipped: 0, total: 1}] =
               Impact.run_many!(workspace, [{:compile, []}], command_mapper: mapper)

      assert_receive {:mapped, "."}

      assert [%{selected: 0, skipped: 1, total: 1, fast_skipped?: true}] =
               Impact.run_many!(workspace, [{:compile, []}], command_mapper: mapper)

      refute_receive {:mapped, _}
    end)
  end

  test "run_many overlaps task families across projects while keeping per-project order" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/alpha")
      init_git!(root)

      stamp_dir =
        Path.join(System.tmp_dir!(), "blitz_overlap_#{System.unique_integer([:positive])}")

      File.rm_rf!(stamp_dir)
      File.mkdir_p!(stamp_dir)

      workspace =
        root
        |> workspace_config()
        |> Keyword.put(:parallelism, multiplier: 1, overrides: [compile: 2, test: 2, deps_get: 2])

      mapper = fn %Command{} = command ->
        task = task_name_from_args(command.args)
        slug = task <> "_" <> String.replace(command.id, ~r/[^a-zA-Z0-9]+/, "_")
        sleep = if task == "compile" and command.id == ".", do: "1", else: "0"

        script =
          "date +%s%N > #{stamp_dir}/#{slug}.start; sleep #{sleep}; " <>
            "date +%s%N > #{stamp_dir}/#{slug}.end"

        %Command{command | command: "bash", args: ["-c", script]}
      end

      try do
        assert [%{selected: 2}, %{selected: 2}] =
                 Impact.run_many!(workspace, [{:compile, []}, {:test, []}],
                   command_mapper: mapper
                 )

        assert read_stamp(stamp_dir, "test_apps_alpha", :start) <
                 read_stamp(stamp_dir, "compile__", :end)

        assert read_stamp(stamp_dir, "test_apps_alpha", :start) >=
                 read_stamp(stamp_dir, "compile_apps_alpha", :end)
      after
        File.rm_rf!(stamp_dir)
      end
    end)
  end

  test "clean run writes a baseline ledger with project task entries" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/demo", readme: "# Demo\n")
      init_git!(root)

      workspace = workspace_config(root)

      seed_clean_baseline!(workspace)

      baseline_path = Path.join([Store.new(root).root, "baselines", "current.json"])
      assert File.exists?(baseline_path)

      baseline = File.read!(baseline_path)
      assert baseline =~ ~s("schema":"blitz-clean-baseline-v1")
      assert baseline =~ ~s("project_path":"apps/demo")
      assert baseline =~ ~s("task":"compile")
      assert baseline =~ ~s("task_state_hash":)
    end)
  end

  test "dirty README with only baseline coverage skips non-doc tasks" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/demo", readme: "# Demo\n\nBefore\n")
      init_git!(root)

      workspace = workspace_config(root)
      seed_clean_baseline!(workspace)
      remove_compact_task_state_index!(root)

      File.write!(Path.join(root, "apps/demo/README.md"), "# Demo\n\nAfter\n")

      for task <- [:deps_get, :format, :compile, :test, :credo, :dialyzer] do
        task_decision = baseline_decision(workspace, task, "apps/demo")
        assert task_decision.decision == :skip
        assert task_decision.reason =~ "baseline"
      end

      docs_decision = baseline_decision(workspace, :docs, "apps/demo")
      assert docs_decision.decision == :run
      assert docs_decision.reason =~ "README.md"
    end)
  end

  test "first dirty README execution from clean baseline runs only owner docs" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/demo", readme: "# Demo\n\nBefore\n")
      create_mix_project!(root, "apps/other", readme: "# Other\n")
      init_git!(root)

      workspace = workspace_config(root)
      log_path = Path.join(root, "executed.log")
      mapper = recording_command_mapper(log_path)
      task_specs = ci_task_specs_with_root_test_split()

      seed_clean_baseline!(workspace, task_specs, command_mapper: mapper)
      File.rm!(log_path)
      remove_compact_task_state_index!(root)

      File.write!(Path.join(root, "apps/demo/README.md"), "# Demo\n\nAfter\n")

      Impact.run_many!(workspace, task_specs, command_mapper: mapper)

      assert read_executions(log_path) == [%{task: "docs", project: "apps/demo"}]

      File.rm!(log_path)
      Impact.run_many!(workspace, task_specs, command_mapper: mapper)

      assert read_executions(log_path) == []
    end)
  end

  test "first dirty child README execution skips root tasks even when root depends on child" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".", deps: ~s([{:apps_demo, path: "apps/demo"}]))
      create_mix_project!(root, "apps/demo", readme: "# Demo\n\nBefore\n")
      create_mix_project!(root, "apps/other", readme: "# Other\n")
      init_git!(root)

      workspace = workspace_config(root)
      log_path = Path.join(root, "executed.log")
      mapper = recording_command_mapper(log_path)
      task_specs = ci_task_specs_with_root_test_split()

      seed_clean_baseline!(workspace, task_specs, command_mapper: mapper)
      File.rm!(log_path)
      remove_compact_task_state_index!(root)

      File.write!(Path.join(root, "apps/demo/README.md"), "# Demo\n\nAfter\n")

      Impact.run_many!(workspace, task_specs, command_mapper: mapper)

      assert read_executions(log_path) == [%{task: "docs", project: "apps/demo"}]
    end)
  end

  test "decisions expose exact, clean baseline, impacted, and missing baseline sources" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/demo", readme: "# Demo\n\nBefore\n")
      init_git!(root)

      workspace = workspace_config(root)
      seed_clean_baseline!(workspace)
      remove_compact_task_state_index!(root)

      File.write!(Path.join(root, "apps/demo/README.md"), "# Demo\n\nAfter\n")

      compile_decision = baseline_decision(workspace, :compile, "apps/demo")
      assert compile_decision.decision == :skip
      assert compile_decision.coverage_source == :clean_baseline
      assert compile_decision.reason == "clean baseline passed; not impacted"

      docs_decision = baseline_decision(workspace, :docs, "apps/demo")
      assert docs_decision.decision == :run
      assert docs_decision.coverage_source == :impacted
      assert docs_decision.reason =~ "apps/demo/README.md"
    end)

    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/demo", readme: "# Demo\n")
      init_git!(root)

      workspace = workspace_config(root)
      File.write!(Path.join(root, "apps/demo/README.md"), "# Demo\n\nChanged\n")

      compile_decision = baseline_decision(workspace, :compile, "apps/demo")
      assert compile_decision.decision == :run
      assert compile_decision.coverage_source == :missing_clean_baseline
      assert compile_decision.reason == "missing clean baseline coverage"
    end)
  end

  test "dirty source file selects owner and reverse dependents but skips unrelated baseline projects" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/alpha")
      create_mix_project!(root, "apps/bravo", deps: ~s([{:apps_alpha, path: "../alpha"}]))
      create_mix_project!(root, "apps/charlie")
      init_git!(root)

      workspace = workspace_config(root)
      seed_clean_baseline!(workspace)
      remove_compact_task_state_index!(root)

      File.write!(Path.join(root, "apps/alpha/lib/apps_alpha.ex"), """
      defmodule AppsAlpha do
        def ok?, do: :changed
      end
      """)

      assert baseline_decision(workspace, :compile, "apps/alpha").decision == :run
      assert baseline_decision(workspace, :compile, "apps/bravo").decision == :run

      for project <- ["apps/alpha", "apps/bravo", "apps/charlie"] do
        deps_get_decision = baseline_decision(workspace, :deps_get, project)
        assert deps_get_decision.decision == :skip
        assert deps_get_decision.reason =~ "baseline"
      end

      charlie_decision = baseline_decision(workspace, :compile, "apps/charlie")
      assert charlie_decision.decision == :skip
      assert charlie_decision.reason =~ "baseline"
    end)
  end

  test "first dirty source execution cascades dependency-sensitive tasks only" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/alpha")
      create_mix_project!(root, "apps/bravo", deps: ~s([{:apps_alpha, path: "../alpha"}]))
      create_mix_project!(root, "apps/charlie")
      init_git!(root)

      workspace = workspace_config(root)
      log_path = Path.join(root, "executed.log")
      mapper = recording_command_mapper(log_path)
      task_specs = ci_task_specs_with_root_test_split()

      seed_clean_baseline!(workspace, task_specs, command_mapper: mapper)
      File.rm!(log_path)
      remove_compact_task_state_index!(root)

      File.write!(Path.join(root, "apps/alpha/lib/apps_alpha.ex"), """
      defmodule AppsAlpha do
        def ok?, do: :changed
      end
      """)

      Impact.run_many!(workspace, task_specs, command_mapper: mapper)

      executions = read_executions(log_path)

      assert projects_for(executions, "deps_get") == []
      assert projects_for(executions, "format") == ["apps/alpha"]
      assert projects_for(executions, "credo") == ["apps/alpha"]

      for task <- ["compile", "test", "dialyzer", "docs"] do
        assert projects_for(executions, task) == ["apps/alpha", "apps/bravo"]
      end

      refute Enum.any?(executions, &(&1.project == "apps/charlie"))
      refute Enum.any?(executions, &(&1.project == "."))

      for task <- [:compile, :test, :dialyzer, :docs],
          project <- ["apps/alpha", "apps/bravo"] do
        decision = baseline_decision(workspace, task, project)
        assert decision.reason =~ "apps/alpha/lib/apps_alpha.ex"
      end
    end)
  end

  test "dirty test file selects only owner test surface with baseline coverage" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/demo")
      create_test_file!(root, "apps/demo", "assert true\n")
      init_git!(root)

      workspace = workspace_config(root)
      seed_clean_baseline!(workspace)
      remove_compact_task_state_index!(root)

      create_test_file!(root, "apps/demo", "assert 1 == 1\n")

      assert baseline_decision(workspace, :format, "apps/demo").decision == :run
      assert baseline_decision(workspace, :test, "apps/demo").decision == :run
      assert baseline_decision(workspace, :credo, "apps/demo").decision == :run

      for task <- [:deps_get, :compile, :dialyzer, :docs] do
        task_decision = baseline_decision(workspace, task, "apps/demo")
        assert task_decision.decision == :skip
        assert task_decision.reason =~ "baseline"
      end
    end)
  end

  test "dirty mix.exs recomputes graph and selects owner plus reverse dependents" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/alpha")
      create_mix_project!(root, "apps/bravo", deps: ~s([{:apps_alpha, path: "../alpha"}]))
      create_mix_project!(root, "apps/charlie")
      init_git!(root)

      workspace = workspace_config(root)
      seed_clean_baseline!(workspace)
      remove_compact_task_state_index!(root)

      File.write!(
        Path.join(root, "apps/alpha/mix.exs"),
        mix_project_source("apps/alpha", "[]", "0.1.1")
      )

      assert baseline_decision(workspace, :compile, "apps/alpha").decision == :run
      assert baseline_decision(workspace, :compile, "apps/bravo").decision == :run

      charlie_decision = baseline_decision(workspace, :compile, "apps/charlie")
      assert charlie_decision.decision == :skip
      assert charlie_decision.reason =~ "baseline"
    end)
  end

  test "first dirty mix.exs execution cascades dependency-sensitive tasks only" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/alpha")
      create_mix_project!(root, "apps/bravo", deps: ~s([{:apps_alpha, path: "../alpha"}]))
      create_mix_project!(root, "apps/charlie")
      init_git!(root)

      workspace = workspace_config(root)
      log_path = Path.join(root, "executed.log")
      mapper = recording_command_mapper(log_path)
      task_specs = ci_task_specs_with_root_test_split()

      seed_clean_baseline!(workspace, task_specs, command_mapper: mapper)
      File.rm!(log_path)
      remove_compact_task_state_index!(root)

      File.write!(
        Path.join(root, "apps/alpha/mix.exs"),
        mix_project_source("apps/alpha", "[]", "0.1.1")
      )

      Impact.run_many!(workspace, task_specs, command_mapper: mapper)

      executions = read_executions(log_path)

      assert projects_for(executions, "deps_get") == ["apps/alpha", "apps/bravo"]
      assert projects_for(executions, "format") == ["apps/alpha"]
      assert projects_for(executions, "credo") == ["apps/alpha"]

      for task <- ["compile", "test", "dialyzer", "docs"] do
        assert projects_for(executions, task) == ["apps/alpha", "apps/bravo"]
      end

      refute Enum.any?(executions, &(&1.project == "apps/charlie"))
      refute Enum.any?(executions, &(&1.project == "."))
    end)
  end

  test "dirty mix.lock selects dependency-sensitive tasks but not deps_get lock output churn" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/demo")
      init_git!(root)

      workspace = workspace_config(root)
      seed_clean_baseline!(workspace)
      remove_compact_task_state_index!(root)

      File.write!(Path.join(root, "apps/demo/mix.lock"), "%{\"jason\": {:hex, :jason}}\n")

      deps_get_decision = baseline_decision(workspace, :deps_get, "apps/demo")
      assert deps_get_decision.decision == :skip
      assert deps_get_decision.reason =~ "baseline"

      assert baseline_decision(workspace, :compile, "apps/demo").decision == :run
      assert baseline_decision(workspace, :test, "apps/demo").decision == :run
      assert baseline_decision(workspace, :dialyzer, "apps/demo").decision == :run
      assert baseline_decision(workspace, :docs, "apps/demo").decision == :run
    end)
  end

  test "hex and git lock entry changes alter dependency-sensitive task hashes" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/demo")
      workspace = workspace_config(root)

      compile_before = task_state_hash(workspace, :compile, "apps/demo")
      test_before = task_state_hash(workspace, :test, "apps/demo")
      dialyzer_before = task_state_hash(workspace, :dialyzer, "apps/demo")
      docs_before = task_state_hash(workspace, :docs, "apps/demo")

      File.write!(
        Path.join(root, "apps/demo/mix.lock"),
        ~s(%{"jason": {:hex, :jason, "1.4.4", "abc", [], [], "hexpm", "checksum-a"}}\n)
      )

      compile_hex = task_state_hash(workspace, :compile, "apps/demo")
      test_hex = task_state_hash(workspace, :test, "apps/demo")
      dialyzer_hex = task_state_hash(workspace, :dialyzer, "apps/demo")
      docs_hex = task_state_hash(workspace, :docs, "apps/demo")

      refute compile_hex == compile_before
      refute test_hex == test_before
      refute dialyzer_hex == dialyzer_before
      refute docs_hex == docs_before

      File.write!(
        Path.join(root, "apps/demo/mix.lock"),
        ~s(%{"jason": {:git, "https://example.invalid/jason.git", "0123456789abcdef", []}}\n)
      )

      refute task_state_hash(workspace, :compile, "apps/demo") == compile_hex
      refute task_state_hash(workspace, :test, "apps/demo") == test_hex
      refute task_state_hash(workspace, :dialyzer, "apps/demo") == dialyzer_hex
      refute task_state_hash(workspace, :docs, "apps/demo") == docs_hex
    end)
  end

  test "unlocked git dependencies do not receive deterministic skip evidence" do
    with_tmp_workspace(fn root ->
      create_mix_project!(
        root,
        ".",
        deps: ~s([{:jason, git: "https://example.invalid/jason.git", branch: "main"}])
      )

      init_git!(root)
      workspace = workspace_config(root)

      seed_clean_baseline!(workspace, [{:deps_get, []}, {:compile, []}])

      refute task_state_hash(workspace, :deps_get, ".") ==
               task_state_hash(workspace, :deps_get, ".")

      refute task_state_hash(workspace, :compile, ".") ==
               task_state_hash(workspace, :compile, ".")

      compile_decision = baseline_decision(workspace, :compile, ".")
      assert compile_decision.decision == :run
      assert compile_decision.coverage_source == :missing_clean_baseline
      assert compile_decision.baseline_available?
    end)
  end

  test "workspace invalidator selects every project with explicit reason" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/alpha")
      create_mix_project!(root, "apps/bravo")
      File.mkdir_p!(Path.join(root, "build_support"))
      File.write!(Path.join(root, "build_support/dependency_resolver.exs"), "# resolver\n")
      init_git!(root)

      workspace = workspace_config(root)
      seed_clean_baseline!(workspace)

      File.write!(Path.join(root, "build_support/dependency_resolver.exs"), "# changed\n")

      for task <- [:deps_get, :format, :compile, :test, :credo, :dialyzer, :docs],
          project <- [".", "apps/alpha", "apps/bravo"] do
        decision = baseline_decision(workspace, task, project)
        assert decision.decision == :run
        assert decision.reason == "workspace configuration changed"
      end
    end)
  end

  test "workspace contract invalidator selects every project with exact entries present" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/alpha")
      create_mix_project!(root, "apps/bravo")
      File.mkdir_p!(Path.join(root, "build_support"))
      File.write!(Path.join(root, "build_support/workspace_contract.exs"), "# contract\n")
      init_git!(root)

      workspace = workspace_config(root)
      seed_clean_baseline!(workspace)

      File.write!(Path.join(root, "build_support/workspace_contract.exs"), "# changed\n")

      for task <- [:deps_get, :format, :compile, :test, :credo, :dialyzer, :docs],
          project <- [".", "apps/alpha", "apps/bravo"] do
        decision = baseline_decision(workspace, task, project)
        assert decision.decision == :run
        assert decision.coverage_source == :impacted
        assert decision.reason == "workspace configuration changed"
      end
    end)
  end

  test "root mix.exs invalidator selects every project with explicit reason" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/alpha")
      create_mix_project!(root, "apps/bravo")
      init_git!(root)

      workspace = workspace_config(root)
      seed_clean_baseline!(workspace)

      File.write!(
        Path.join(root, "mix.exs"),
        mix_project_source(".", "[]", "0.1.1")
      )

      for task <- [:deps_get, :format, :compile, :test, :credo, :dialyzer, :docs],
          project <- [".", "apps/alpha", "apps/bravo"] do
        decision = baseline_decision(workspace, task, project)
        assert decision.decision == :run
        assert decision.reason == "workspace configuration changed"
      end
    end)
  end

  test "dry-run output exposes coverage source and missing baseline diagnostics" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/demo", readme: "# Demo\n\nBefore\n")
      init_git!(root)

      workspace = workspace_config(root)
      seed_clean_baseline!(workspace)
      remove_compact_task_state_index!(root)

      File.write!(Path.join(root, "apps/demo/README.md"), "# Demo\n\nAfter\n")

      output =
        capture_io(fn ->
          Impact.run!(workspace, :compile, [], dry_run: true, command_mapper: &noop_command/1)
        end)

      assert output =~ "source=clean_baseline"
      assert output =~ "baseline=true"
      assert output =~ "clean baseline passed; not impacted"
    end)

    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/demo", readme: "# Demo\n")
      init_git!(root)

      workspace = workspace_config(root)
      File.write!(Path.join(root, "apps/demo/README.md"), "# Demo\n\nChanged\n")

      output =
        capture_io(fn ->
          Impact.run!(workspace, :compile, [], dry_run: true, command_mapper: &noop_command/1)
        end)

      assert output =~ "source=missing_clean_baseline"
      assert output =~ "baseline=false"
      assert output =~ "missing clean baseline coverage"
    end)
  end

  test "dirty workspace without baseline runs with missing clean baseline coverage reason" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/demo", readme: "# Demo\n")
      init_git!(root)

      workspace = workspace_config(root)
      File.write!(Path.join(root, "apps/demo/README.md"), "# Demo\n\nChanged\n")

      compile_decision = baseline_decision(workspace, :compile, "apps/demo")
      assert compile_decision.decision == :run
      assert compile_decision.reason == "missing clean baseline coverage"
      assert compile_decision.coverage_source == :missing_clean_baseline
    end)
  end

  test "compact pruning keeps current baseline and removes stale audit artifacts" do
    with_tmp_workspace(fn root ->
      create_mix_project!(root, ".")
      create_mix_project!(root, "apps/demo")
      init_git!(root)

      workspace = workspace_config(root)
      seed_clean_baseline!(workspace)

      store = Store.new(root)
      File.mkdir_p!(Path.join([store.root, "commits"]))
      File.mkdir_p!(Path.join([store.root, "output"]))
      File.write!(Path.join(store.root, "results.ndjson"), "stale\n")

      Store.prune!(store)

      assert File.exists?(Path.join([store.root, "baselines", "current.json"]))
      refute File.exists?(Path.join(store.root, "results.ndjson"))
      refute File.exists?(Path.join(store.root, "commits"))
      refute File.exists?(Path.join(store.root, "output"))
    end)
  end

  defp task_state_hash(workspace, task, project_path) do
    workspace
    |> Impact.plan(task, [])
    |> decision_for(task, project_path)
    |> Map.fetch!(:task_state_hash)
  end

  defp decision(workspace, task, project_path, opts) do
    workspace
    |> Impact.plan(task, [], opts)
    |> decision_for(task, project_path)
  end

  defp baseline_decision(workspace, task, project_path, opts \\ []) do
    decision(
      workspace,
      task,
      project_path,
      Keyword.put_new(opts, :command_mapper, &noop_command/1)
    )
  end

  defp decision_for(plan, task, project_path) do
    plan.stages
    |> Enum.find(&(&1.task == task))
    |> Map.fetch!(:decisions)
    |> Enum.find(&(&1.command.id == project_path))
  end

  defp passed_record(task_state_hash, project_path, task) do
    %{
      task_state_hash: task_state_hash,
      project_path: project_path,
      task: Atom.to_string(task),
      status: "passed"
    }
  end

  defp workspace_config(root) do
    [
      root: root,
      projects: [".", "apps/*"],
      parallelism: [
        base: [deps_get: 1, format: 1, compile: 1, test: 1, credo: 1, dialyzer: 1, docs: 1],
        multiplier: 1
      ],
      tasks: [
        deps_get: [args: ["deps.get"]],
        format: [args: ["format"]],
        compile: [args: ["compile"]],
        test: [args: ["test"]],
        credo: [args: ["credo"]],
        dialyzer: [args: ["dialyzer"]],
        docs: [args: ["docs"]]
      ]
    ]
  end

  defp with_tmp_workspace(fun) do
    root =
      System.tmp_dir!()
      |> Path.join("blitz_test_state_#{System.unique_integer([:positive])}")

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

    deps = Keyword.get(opts, :deps, "[]")
    version = Keyword.get(opts, :version, "0.1.0")

    File.write!(
      Path.join(project_root, "mix.exs"),
      mix_project_source(relative_path, deps, version)
    )

    if readme = Keyword.get(opts, :readme) do
      File.write!(Path.join(project_root, "README.md"), readme)
    end

    File.write!(Path.join(project_root, "lib/#{app_slug(relative_path)}.ex"), """
    defmodule #{module_name(relative_path)} do
      def ok?, do: true
    end
    """)
  end

  defp mix_project_source(relative_path, deps, version) do
    """
    defmodule #{module_name(relative_path)}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{app_slug(relative_path)},
          version: "#{version}",
          elixir: "~> 1.18",
          deps: #{deps}
        ]
      end
    end
    """
  end

  defp create_test_file!(workspace_root, relative_path, assertion) do
    project_root = Path.join(workspace_root, relative_path)
    File.mkdir_p!(Path.join(project_root, "test"))

    File.write!(Path.join(project_root, "test/#{app_slug(relative_path)}_test.exs"), """
    defmodule #{module_name(relative_path)}Test do
      use ExUnit.Case

      test "sample" do
        #{assertion}
      end
    end
    """)
  end

  defp seed_clean_baseline!(workspace, task_specs \\ ci_task_specs(), opts \\ []) do
    opts = Keyword.put_new(opts, :command_mapper, &noop_command/1)
    Impact.run_many!(workspace, task_specs, opts)
  end

  defp ci_task_specs do
    [
      {:deps_get, []},
      {:format, []},
      {:compile, []},
      {:test, []},
      {:credo, []},
      {:dialyzer, []},
      {:docs, []}
    ]
  end

  defp ci_task_specs_with_root_test_split do
    [
      {:deps_get, []},
      {:format, []},
      {:compile, []},
      {:test, [],
       [only_projects: ["apps/alpha", "apps/bravo", "apps/charlie", "apps/demo", "apps/other"]]},
      {:test, [], [only_projects: ["."]]},
      {:credo, []},
      {:dialyzer, []},
      {:docs, []}
    ]
  end

  defp noop_command(%Command{} = command),
    do: %Command{command | command: "sh", args: ["-c", "true"]}

  defp recording_command_mapper(log_path) do
    fn %Command{} = command ->
      task = task_name_from_args(command.args)

      %Command{
        command
        | command: "sh",
          args: [
            "-c",
            "printf '%s\\t%s\\n' \"$1\" \"$2\" >> \"$3\"",
            "record",
            task,
            command.id,
            log_path
          ]
      }
    end
  end

  defp task_name_from_args(["deps.get" | _rest]), do: "deps_get"
  defp task_name_from_args([task | _rest]), do: task
  defp task_name_from_args([]), do: "unknown"

  defp read_stamp(dir, name, kind) do
    dir
    |> Path.join("#{name}.#{kind}")
    |> File.read!()
    |> String.trim()
    |> String.to_integer()
  end

  defp read_executions(log_path) do
    if File.exists?(log_path) do
      log_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        [task, project] = String.split(line, "\t", parts: 2)
        %{task: task, project: project}
      end)
      |> Enum.sort_by(&{&1.task, &1.project})
    else
      []
    end
  end

  defp projects_for(executions, task) do
    executions
    |> Enum.filter(&(&1.task == task))
    |> Enum.map(& &1.project)
    |> Enum.sort()
  end

  defp remove_compact_task_state_index!(root) do
    root
    |> Store.new()
    |> Map.fetch!(:root)
    |> Path.join("indexes/task_states.ndjson")
    |> File.rm()
  end

  defp init_git!(root) do
    git!(root, ["init"])
    git!(root, ["config", "user.email", "test@example.com"])
    git!(root, ["config", "user.name", "Test User"])
    git!(root, ["add", "."])
    git!(root, ["commit", "-m", "initial"])
  end

  defp git!(root, args) do
    {output, status} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    assert status == 0, output
    output
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
