defmodule Blitz.MixWorkspace.Impact do
  @moduledoc """
  Impact-aware execution for `Blitz.MixWorkspace`.

  This layer computes deterministic task state for each planned workspace
  command, skips exact states that already have a passed result, and persists
  command results under `.blitz/test_state_v1`.
  """

  alias Blitz.MixWorkspace.ProjectState
  alias Blitz.TestState.{Git, Hash, Store}

  @closure_tasks [:compile, :test, :dialyzer, :docs, :deps_get]
  @all_known_tasks [:deps_get, :format, :compile, :test, :credo, :dialyzer, :docs]

  @type task_spec :: atom() | {atom(), [String.t()]} | {atom(), [String.t()], keyword()}

  def run!(workspace_config, task, args \\ [], opts \\ []) when is_atom(task) do
    workspace_config
    |> plan(task, args, opts)
    |> then(&execute_plans!([&1], opts))
    |> hd()
  end

  def run_many!(workspace_config, task_specs, opts \\ []) do
    workspace = Blitz.MixWorkspace.load!(workspace_config)
    store = Store.new(workspace.root, opts)
    git = Git.metadata(workspace.root)
    task_specs = Enum.map(task_specs, &normalize_task_spec/1)
    pipeline_hash = pipeline_hash(workspace, task_specs, opts, git)

    if pipeline_fast_skip?(store, pipeline_hash, opts, git) do
      fast_pipeline_summary!(store, pipeline_hash)
    else
      context = build_context(workspace, store, git, opts)

      plans =
        Enum.map(task_specs, fn {task, args, task_opts} ->
          plan_with_context(context, task, args, Keyword.merge(opts, task_opts))
        end)

      summaries = execute_plans!(plans, opts)
      maybe_write_pipeline_manifest!(store, pipeline_hash, plans, summaries, opts, git)
      summaries
    end
  end

  def plan(workspace_config, task, args \\ [], opts \\ []) do
    workspace = Blitz.MixWorkspace.load!(workspace_config)
    store = Store.new(workspace.root, opts)
    git = Git.metadata(workspace.root)
    context = build_context(workspace, store, git, opts)

    plan_with_context(context, task, args, opts)
  end

  defp build_context(workspace, store, git, opts) do
    project_states = ProjectState.snapshot_all(workspace)
    project_paths = Blitz.MixWorkspace.project_paths(workspace)
    graph = ProjectState.local_dependency_graph(project_states)
    impact_policy = Keyword.get(opts, :impact_policy, [])
    impacted = impacted_by_task(workspace, project_paths, graph, impact_policy, opts)
    workspace_state_hash = workspace_state_hash(workspace, impact_policy)
    baseline = latest_clean_baseline(store, workspace_state_hash)

    %{
      workspace: workspace,
      store: store,
      git: git,
      project_states: project_states,
      impacted: impacted,
      workspace_state_hash: workspace_state_hash,
      baseline: baseline,
      graph: graph
    }
  end

  defp latest_clean_baseline(store, workspace_state_hash) do
    case Store.latest_clean_baseline(store, workspace_state_hash) do
      {:ok, baseline} -> baseline
      :error -> nil
    end
  end

  defp plan_with_context(context, task, args, opts) do
    workspace = context.workspace

    stages =
      workspace
      |> Blitz.MixWorkspace.plan(task, args)
      |> Enum.map(fn stage ->
        commands =
          stage.commands
          |> filter_projects(Keyword.get(opts, :only_projects))
          |> Enum.map(&map_command(&1, opts))

        decisions =
          Enum.map(commands, fn command ->
            decision(
              command,
              stage.task,
              context.store,
              context.project_states,
              context.workspace_state_hash,
              context.impacted,
              context.baseline,
              opts
            )
          end)

        stage
        |> Map.put(:commands, commands)
        |> Map.put(:decisions, decisions)
      end)

    %{
      workspace: workspace,
      store: context.store,
      task: task,
      stages: stages,
      workspace_state_hash: context.workspace_state_hash,
      git: context.git,
      graph: context.graph
    }
  end

  defp normalize_task_spec(task) when is_atom(task), do: {task, [], []}

  defp normalize_task_spec({task, args}) when is_atom(task) and is_list(args),
    do: {task, args, []}

  defp normalize_task_spec({task, args, opts})
       when is_atom(task) and is_list(args) and is_list(opts),
       do: {task, args, opts}

  defp filter_projects(commands, nil), do: commands

  defp filter_projects(commands, project_paths) do
    allowed = MapSet.new(project_paths)
    Enum.filter(commands, &MapSet.member?(allowed, &1.id))
  end

  defp map_command(command, opts) do
    case Keyword.get(opts, :command_mapper) do
      nil -> command
      mapper when is_function(mapper, 1) -> mapper.(command)
    end
  end

  defp execute_plans!(plans, opts) do
    if Keyword.get(opts, :dry_run, false) do
      Enum.map(plans, fn plan ->
        print_dry_run!(plan)
        summary(plan)
      end)
    else
      run_selected_plans!(plans)
    end
  end

  defp run_selected_plans!(plans) do
    store = plans |> List.first() |> Map.fetch!(:store)
    Store.ensure_store!(store)

    {stage_inputs, stage_refs} = build_stage_inputs(plans)

    {run_error, grouped_results} =
      case Blitz.run_stages(stage_inputs) do
        {:ok, grouped} -> {nil, grouped}
        {:error, error, grouped} -> {error, grouped}
      end

    executed_by_plan = persist_stage_results!(plans, stage_refs, grouped_results)

    if run_error, do: raise(run_error)

    Store.prune!(store)

    plans
    |> Enum.with_index()
    |> Enum.map(fn {plan, plan_index} ->
      plan
      |> summary()
      |> Map.put(:executed_results, Map.get(executed_by_plan, plan_index, []))
      |> tap(&print_summary!/1)
    end)
  end

  defp build_stage_inputs(plans) do
    plans
    |> Enum.with_index()
    |> Enum.flat_map(fn {plan, plan_index} ->
      Enum.flat_map(plan.stages, fn stage ->
        case Enum.filter(stage.decisions, &(&1.decision in [:run, :force_run])) do
          [] ->
            []

          selected ->
            [
              {%{
                 commands: Enum.map(selected, & &1.command),
                 max_concurrency: stage.max_concurrency
               }, %{plan_index: plan_index, task: stage.task, decisions: selected}}
            ]
        end
      end)
    end)
    |> Enum.unzip()
  end

  defp persist_stage_results!(plans, stage_refs, grouped_results) do
    stage_refs
    |> Enum.zip(grouped_results)
    |> Enum.reduce(%{}, fn {stage_ref, results}, executed_by_plan ->
      plan = Enum.at(plans, stage_ref.plan_index)
      decision_by_id = Map.new(stage_ref.decisions, &{&1.command.id, &1})
      persisted = persist_results!(plan, stage_ref.task, results, decision_by_id)

      Map.update(executed_by_plan, stage_ref.plan_index, persisted, &(&1 ++ persisted))
    end)
  end

  defp decision(
         command,
         task,
         store,
         project_states,
         workspace_state_hash,
         impacted,
         baseline,
         opts
       ) do
    project_state = Map.fetch!(project_states, command.id)
    project_task_hash = ProjectState.task_hash(project_state, task)
    env_hash = Hash.hash("env", Enum.sort(command.env))

    command_hash =
      Hash.hash("command", %{
        command: command.command,
        args: command.args,
        cd: command.cd,
        env_hash: env_hash
      })

    task_state_hash =
      Hash.hash("task_state", %{
        workspace_state_hash: workspace_state_hash,
        project_task_hash: project_task_hash,
        command_hash: command_hash
      })

    covered? = Store.covered?(store, task_state_hash)
    force? = Keyword.get(opts, :force, false)
    impacted? = impacted?(impacted, task, command.id)
    baseline_covered? = baseline_covered?(baseline, command.id, task, task_state_hash)

    {decision, reason, coverage_source} =
      cond do
        force? -> {:force_run, "force requested", :force}
        covered? -> {:skip, "exact passed task state exists", :exact_task_state}
        impacted? -> {:run, impact_reason(impacted, task, command.id), :impacted}
        baseline_covered? -> {:skip, "clean baseline passed; not impacted", :clean_baseline}
        is_nil(baseline) -> {:run, "missing clean baseline coverage", :missing_clean_baseline}
        true -> {:run, "missing clean baseline coverage", :missing_clean_baseline}
      end

    %{
      decision: decision,
      reason: reason,
      command: command,
      task: task,
      task_state_hash: task_state_hash,
      project_task_hash: project_task_hash,
      command_hash: command_hash,
      env_hash: env_hash,
      covered?: covered?,
      impacted?: impacted?,
      baseline_covered?: baseline_covered?,
      baseline_available?: not is_nil(baseline),
      coverage_source: coverage_source
    }
  end

  defp baseline_covered?(nil, _project, _task, _task_state_hash), do: false

  defp baseline_covered?(baseline, project, task, task_state_hash) do
    Store.covered_by_baseline?(baseline, project, task, task_state_hash)
  end

  defp persist_results!(plan, task, results, decision_by_id) do
    Enum.map(results, fn result ->
      decision = Map.fetch!(decision_by_id, result.id)

      record = %{
        repo_commit: plan.git.commit,
        repo_tree: plan.git.tree,
        dirty: plan.git.dirty?,
        workspace_state_hash: plan.workspace_state_hash,
        project_state_hash: decision.project_task_hash,
        task_state_hash: decision.task_state_hash,
        project_path: result.id,
        task: Atom.to_string(task),
        stage: Atom.to_string(task),
        command: result.command,
        args: result.args,
        cwd: result.cd,
        env_hash: decision.env_hash,
        status: result_status(result),
        exit_code: result.exit_code,
        failure_kind: result.failure_kind && Atom.to_string(result.failure_kind),
        failure_reason: result.failure_reason,
        duration_ms: result.duration_ms,
        output_tail: result.output_tail
      }

      Store.append_result!(plan.store, record)
    end)
  end

  defp result_status(%Blitz.Result{failure_kind: nil}), do: "passed"
  defp result_status(_result), do: "failed"

  defp workspace_state_hash(workspace, impact_policy) do
    Hash.hash("workspace_state", %{
      project_paths: Blitz.MixWorkspace.project_paths(workspace),
      tasks: workspace.tasks,
      isolation: workspace.isolation,
      parallelism: workspace.parallelism,
      impact_policy: normalize_impact_policy(impact_policy),
      workspace_invalidators: workspace_invalidator_state(workspace.root, impact_policy),
      elixir: System.version(),
      otp: System.otp_release(),
      blitz: blitz_version(),
      impact_module: module_md5(__MODULE__)
    })
  end

  defp pipeline_hash(workspace, task_specs, opts, git) do
    Hash.hash("pipeline_state", %{
      repo_commit: git.commit,
      repo_tree: git.tree,
      workspace: workspace,
      task_specs: task_specs,
      opts: Keyword.drop(opts, [:dry_run, :force, :store_dir]),
      elixir: System.version(),
      otp: System.otp_release(),
      blitz: blitz_version(),
      impact_module: module_md5(__MODULE__)
    })
  end

  defp blitz_version do
    case Application.spec(:blitz, :vsn) do
      nil -> nil
      vsn -> List.to_string(vsn)
    end
  end

  defp module_md5(module) do
    module.module_info(:md5)
    |> Base.encode16(case: :lower)
  end

  defp pipeline_fast_skip?(store, pipeline_hash, opts, git) do
    clean_pipeline_cache_enabled?(opts, git) and
      match?({:ok, _manifest}, Store.passed_pipeline_manifest(store, pipeline_hash))
  end

  defp clean_pipeline_cache_enabled?(opts, git) do
    git.repo? and git.dirty? == false and not Keyword.get(opts, :dry_run, false) and
      not Keyword.get(opts, :force, false) and not Keyword.has_key?(opts, :base) and
      not Keyword.has_key?(opts, :head) and not Keyword.has_key?(opts, :changed_files)
  end

  defp fast_pipeline_summary!(store, pipeline_hash) do
    {:ok, manifest} = Store.passed_pipeline_manifest(store, pipeline_hash)
    total = manifest.total_commands
    summary = %{selected: 0, skipped: total, total: total, fast_skipped?: true}
    print_summary!(summary)
    [summary]
  end

  defp maybe_write_pipeline_manifest!(store, pipeline_hash, plans, summaries, opts, git) do
    if pipeline_manifest_write_enabled?(opts, git) do
      task_state_hashes = task_state_hashes(plans)

      Store.write_pipeline_manifest!(store, %{
        pipeline_hash: pipeline_hash,
        repo_commit: git.commit,
        repo_tree: git.tree,
        status: "passed",
        total_commands: length(task_state_hashes),
        summaries: Enum.map(summaries, &Map.drop(&1, [:executed_results])),
        task_state_hashes: task_state_hashes
      })

      Store.write_clean_baseline!(store, %{
        pipeline_hash: pipeline_hash,
        repo_commit: git.commit,
        repo_tree: git.tree,
        workspace_state_hash: List.first(plans).workspace_state_hash,
        project_paths: Blitz.MixWorkspace.project_paths(List.first(plans).workspace),
        entries: task_state_entries(plans)
      })

      Store.prune!(store,
        keep_task_state_hashes: task_state_hashes,
        keep_pipeline_hashes: [pipeline_hash]
      )
    end
  end

  defp pipeline_manifest_write_enabled?(opts, git) do
    git.repo? and git.dirty? == false and not Keyword.get(opts, :dry_run, false) and
      not Keyword.has_key?(opts, :base) and not Keyword.has_key?(opts, :head) and
      not Keyword.has_key?(opts, :changed_files)
  end

  defp task_state_hashes(plans) do
    plans
    |> task_state_entries()
    |> Enum.map(& &1.task_state_hash)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp task_state_entries(plans) do
    plans
    |> Enum.flat_map(& &1.stages)
    |> Enum.flat_map(& &1.decisions)
    |> Enum.map(fn decision ->
      %{
        project_path: decision.command.id,
        task: Atom.to_string(decision.task),
        task_state_hash: decision.task_state_hash,
        project_task_hash: decision.project_task_hash,
        command_hash: decision.command_hash,
        env_hash: decision.env_hash
      }
    end)
    |> Enum.uniq_by(&{&1.project_path, &1.task, &1.task_state_hash})
    |> Enum.sort_by(&{&1.project_path, &1.task, &1.task_state_hash})
  end

  defp impacted_by_task(workspace, project_paths, graph, impact_policy, opts) do
    case changed_files(workspace.root, opts) do
      :unknown ->
        all_projects_all_tasks(project_paths, "git state unknown")

      {:ok, []} ->
        %{}

      {:ok, files} ->
        if Enum.any?(files, &workspace_invalidator?(&1, impact_policy)) do
          all_projects_all_tasks(project_paths, "workspace configuration changed")
        else
          build_impacted(files, project_paths, graph, impact_policy)
        end
    end
  end

  defp changed_files(root, opts) do
    result =
      case Keyword.fetch(opts, :changed_files) do
        {:ok, files} -> {:ok, files}
        :error -> Git.changed_files(root, opts)
      end

    case result do
      {:ok, files} -> {:ok, normalize_changed_files(files)}
      :unknown -> :unknown
    end
  end

  defp normalize_changed_files(files) do
    files
    |> Enum.reject(&blitz_store_path?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp blitz_store_path?(path) do
    path == ".blitz" or String.starts_with?(path, ".blitz/")
  end

  defp build_impacted(files, project_paths, graph, impact_policy) do
    Enum.reduce(files, %{}, &put_file_impacts(&2, &1, project_paths, graph, impact_policy))
  end

  defp put_file_impacts(impacted, file, project_paths, graph, impact_policy) do
    project = owning_project(project_paths, file)

    Enum.reduce(tasks_for_file(file, impact_policy), impacted, fn task, acc ->
      projects = impacted_projects(task, file, project, graph, impact_policy)
      put_task_impacts(acc, task, file, projects)
    end)
  end

  defp put_task_impacts(impacted, task, file, projects) do
    Enum.reduce(projects, impacted, fn project, acc ->
      put_impact(acc, task, project, "changed #{file}")
    end)
  end

  defp impacted_projects(task, file, project, graph, impact_policy) do
    projects =
      if closure_task?(task) and dependency_affecting_file?(file) do
        reverse_closure(graph, [project])
      else
        [project]
      end

    projects
    |> add_aggregate_docs_projects(task, file, impact_policy)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp all_projects_all_tasks(project_paths, reason) do
    Enum.reduce(@all_known_tasks, %{}, fn task, impacted ->
      Enum.reduce(project_paths, impacted, &put_impact(&2, task, &1, reason))
    end)
  end

  defp put_impact(impacted, task, project, reason) do
    Map.update(impacted, task, %{project => reason}, &Map.put(&1, project, reason))
  end

  defp impacted?(impacted, task, project) do
    impacted
    |> Map.get(task, %{})
    |> Map.has_key?(project)
  end

  defp impact_reason(impacted, task, project) do
    impacted
    |> Map.get(task, %{})
    |> Map.get(project, "impacted by change")
  end

  defp add_aggregate_docs_projects(projects, :docs, file, impact_policy) do
    if docs_related_file?(file) do
      projects ++ Keyword.get(impact_policy, :aggregate_docs_projects, [])
    else
      projects
    end
  end

  defp add_aggregate_docs_projects(projects, _task, _file, _impact_policy), do: projects

  defp workspace_invalidator?(file, impact_policy) do
    file in workspace_invalidator_files(impact_policy)
  end

  defp workspace_invalidator_files(impact_policy) do
    [
      "mix.exs",
      "build_support/dependency_resolver.exs",
      "build_support/workspace_contract.exs"
    ]
    |> Kernel.++(Keyword.get(impact_policy, :workspace_invalidators, []))
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp workspace_invalidator_state(root, impact_policy) do
    impact_policy
    |> workspace_invalidator_files()
    |> Enum.map(fn file ->
      path = Path.join(root, file)

      case File.read(path) do
        {:ok, contents} -> %{path: file, status: "present", hash: Hash.hash("file", contents)}
        {:error, :enoent} -> %{path: file, status: "missing"}
        {:error, reason} -> %{path: file, status: "error", reason: inspect(reason)}
      end
    end)
  end

  defp normalize_impact_policy(impact_policy) do
    impact_policy
    |> Keyword.update(:workspace_invalidators, [], fn files ->
      files
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
      |> Enum.sort()
    end)
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp owning_project(project_paths, file) do
    project_paths
    |> Enum.reject(&(&1 == "."))
    |> Enum.sort_by(&byte_size/1, :desc)
    |> Enum.find(".", fn project ->
      file == project or String.starts_with?(file, project <> "/")
    end)
  end

  defp tasks_for_file(file, impact_policy) do
    dependency_tasks_for_file(file, impact_policy) ||
      local_tasks_for_file(file) ||
      @all_known_tasks
  end

  defp dependency_tasks_for_file(file, impact_policy) do
    cond do
      mix_exs_file?(file) -> @all_known_tasks
      mix_lock_file?(file) -> mix_lock_tasks(impact_policy)
      true -> nil
    end
  end

  defp mix_lock_tasks(impact_policy) do
    if Keyword.get(impact_policy, :deps_get_lockfile_self_invalidation, false) do
      [:deps_get, :compile, :test, :dialyzer, :docs]
    else
      [:compile, :test, :dialyzer, :docs]
    end
  end

  defp local_tasks_for_file(file) do
    cond do
      docs_related_file?(file) -> [:docs]
      format_config_file?(file) -> [:format]
      credo_config_file?(file) -> [:credo]
      test_file?(file) -> [:format, :test, :credo]
      elixir_source_file?(file) -> [:format, :compile, :test, :credo, :dialyzer, :docs]
      true -> nil
    end
  end

  defp mix_exs_file?(file), do: String.ends_with?(file, "mix.exs")
  defp mix_lock_file?(file), do: String.ends_with?(file, "mix.lock")

  defp docs_related_file?(file) do
    String.ends_with?(file, ".md") or String.contains?(file, "/docs/") or
      String.contains?(file, "/guides/")
  end

  defp format_config_file?(file), do: String.ends_with?(file, ".formatter.exs")
  defp credo_config_file?(file), do: String.ends_with?(file, ".credo.exs")
  defp test_file?(file), do: String.contains?(file, "/test/")
  defp elixir_source_file?(file), do: String.ends_with?(file, [".ex", ".exs"])

  defp dependency_affecting_file?(file) do
    String.ends_with?(file, ["mix.exs", "mix.lock", ".ex", ".exs"]) or
      String.contains?(file, "/lib/") or String.contains?(file, "/src/") or
      String.contains?(file, "/priv/") or String.contains?(file, "/config/")
  end

  defp closure_task?(task), do: task in @closure_tasks

  defp reverse_closure(graph, projects) do
    reverse =
      Enum.reduce(graph, %{}, fn {project, deps}, acc ->
        Enum.reduce(deps, acc, fn dep, dep_acc ->
          Map.update(dep_acc, dep, [project], &[project | &1])
        end)
      end)

    do_reverse_closure(reverse, projects, %{})
    |> Map.keys()
    |> Enum.sort()
  end

  defp do_reverse_closure(_reverse, [], seen), do: seen

  defp do_reverse_closure(reverse, [project | rest], seen) do
    if Map.has_key?(seen, project) do
      do_reverse_closure(reverse, rest, seen)
    else
      dependents = Map.get(reverse, project, [])
      do_reverse_closure(reverse, rest ++ dependents, Map.put(seen, project, true))
    end
  end

  defp print_dry_run!(plan) do
    IO.puts("Blitz impact dry-run")

    plan.stages
    |> Enum.flat_map(& &1.decisions)
    |> Enum.each(fn decision ->
      IO.puts(
        "#{decision.decision} #{decision.task} #{decision.command.id} #{Hash.short(decision.task_state_hash)} source=#{decision.coverage_source} baseline=#{decision.baseline_available?} #{decision.reason}"
      )
    end)

    plan
    |> summary()
    |> print_summary!()
  end

  defp summary(%{stages: stages}) do
    decisions = Enum.flat_map(stages, & &1.decisions)

    %{
      selected: Enum.count(decisions, &(&1.decision in [:run, :force_run])),
      skipped: Enum.count(decisions, &(&1.decision == :skip)),
      total: length(decisions)
    }
  end

  defp print_summary!(summary) do
    IO.puts(
      "Blitz impact summary: selected=#{summary.selected} skipped=#{summary.skipped} total=#{summary.total}"
    )

    summary
  end
end
