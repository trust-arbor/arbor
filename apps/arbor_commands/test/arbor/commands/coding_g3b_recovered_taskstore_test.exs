defmodule Arbor.Commands.CodingG3BRecoveredTaskStoreTest do
  @moduledoc """
  Authentic CodingTaskExecutor + TaskStore restart/finalize recovery.

  Lives in arbor_commands because that library may depend on both arbor_agent
  and arbor_orchestrator. The runner is the production Engine-facing
  `run_file_as/4` seam; TaskStore still owns outer lifecycle and finalization.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Agent.Orchestration.{TaskControlLease, TaskControlRecoveryMemory, TaskStore}
  alias Arbor.Orchestrator.CodingPlan.ArtifactStore
  alias Arbor.Orchestrator.CodingTaskExecutor

  defmodule CapturingRunner do
    @moduledoc false

    @tree String.duplicate("a", 40)
    @head String.duplicate("b", 40)
    @digest String.duplicate("c", 64)
    @other String.duplicate("d", 64)
    @observed "2026-07-22T12:00:00.000Z"

    def run_file_as(_path, _principal, %Arbor.Contracts.Security.SigningAuthority{}, opts) do
      iv = Keyword.get(opts, :initial_values, %{})

      {:ok,
       %{
         run_id: Keyword.get(opts, :run_id),
         context: %{
           "status" => "change_committed",
           "canonical_status" => "change_committed",
           "branch" => "arbor/coding-agent/test",
           "commit_hash" => "abc123def",
           "workspace_id" => "ws_1",
           "worker_session_id" => "worker_1",
           "worker_provider_session_id" => "provider_session_1",
           "coding_plan_validation_program" => Map.get(iv, "coding_plan_validation_program"),
           "validation_candidate_tree_oid" => @tree,
           "validation_observed_at" => @observed,
           "validation" => %{
             "path" => "/owner/worktree",
             "exit_code" => 0,
             "passed" => true,
             "reason" => nil,
             "stdout" => "compile output",
             "stderr" => "",
             "feedback" => %{
               "exit_code" => 0,
               "passed" => true,
               "stdout_excerpt" => "ignored output",
               "stderr_excerpt" => "",
               "stdout_truncated" => false,
               "stderr_truncated" => false,
               "stdout_sha256" => @digest,
               "stderr_sha256" => @other
             },
             "feedback_json" => "ignored raw feedback",
             "validated_tree_oid" => @tree,
             "validated_head" => @head,
             "termination" => nil
           },
           "worker" => %{
             "worker_session_id" => "worker_1",
             "provider" => Map.get(iv, "acp_agent", "codex"),
             "model" => Map.get(iv, "model", "default")
           },
           "worker_status" => %{
             "worker_session_id" => "worker_1",
             "provider" => Map.get(iv, "acp_agent", "codex"),
             "model" => Map.get(iv, "model", "default"),
             "session_id" => "provider_session_1"
           },
           "worker_msg" => %{
             "delivery_status" => "delivered",
             "stop_reason" => "end_turn",
             "session_id" => "provider_session_1"
           }
         },
         completed_nodes: [],
         final_outcome: %{status: :success},
         taint: %{},
         node_durations: %{}
       }}
    end
  end

  defmodule FakeCompiler do
    @moduledoc false
    def compile(plan, opts), do: Arbor.Orchestrator.CodingPlan.Compiler.compile(plan, opts)
  end

  defmodule FakeSecurity do
    @moduledoc false

    def load_signing_key(agent_id),
      do: {:ok, :crypto.hash(:sha256, "g3b-key-" <> agent_id)}

    def signing_key_status(_agent_id), do: {:ok, :available}

    def build_signing_authority_acquisition_proof(agent_id, _key, opts) do
      {:ok, {:g3b_proof, agent_id, Keyword.fetch!(opts, :owner)}}
    end

    def open_signing_authority({:g3b_proof, agent_id, _owner}) do
      Arbor.Contracts.Security.SigningAuthority.new(%{
        token: :crypto.hash(:sha256, agent_id),
        principal_id: agent_id,
        purpose: :coding_task_executor
      })
    end

    def sign_with_authority(%Arbor.Contracts.Security.SigningAuthority{}, _resource),
      do: {:ok, :signed}

    def close_signing_authority(%Arbor.Contracts.Security.SigningAuthority{}), do: :ok
    def close_signing_authority(_), do: {:error, :invalid_signing_authority}
    def authorize(_agent_id, _resource, _action, _opts \\ []), do: {:ok, :authorized}

    def list_capabilities(principal_id, opts \\ []) do
      {:ok,
       [
         %{
           id: "g3b-cap-#{principal_id}",
           principal_id: principal_id,
           resource_uri: "arbor://**",
           expires_at: nil,
           task_id: Keyword.get(opts, :task_id),
           session_id: Keyword.get(opts, :session_id),
           cover_all: true
         }
       ]}
    end

    def capability_authorizes?(capability, resource, opts \\ [])
    def capability_authorizes?(%{cover_all: true}, _resource, _opts), do: true
    def capability_authorizes?(_capability, _resource, _opts), do: false

    def normalize_authorization_resource_uri(resource, _opts), do: {:ok, resource}
  end

  defmodule ReadinessObservers do
    @moduledoc false

    alias Arbor.Contracts.LLM.ProviderObservation

    def security_available?, do: true
    def signing_key_status(_agent_id), do: {:ok, :available}

    def acp_provider_readiness(provider, model) do
      now = DateTime.utc_now()
      observed_at = DateTime.to_iso8601(now, :extended)
      expires_at = DateTime.to_iso8601(DateTime.add(now, 20, :second), :extended)

      {:ok, observation} =
        ProviderObservation.normalize(%{
          provider: provider,
          source: "acp_provider_readiness",
          runtime: "acp",
          observed_at: observed_at,
          expires_at: expires_at,
          availability: "degraded",
          auth_health: "unknown",
          model_catalog_membership: "unknown",
          quota_state: "unknown",
          subscription_capacity_state: "unknown",
          requested_model_id: model,
          launch_bound_model_id: model
        })

      {:ok, digest} = ProviderObservation.digest(observation)
      %{"observation" => observation, "digest" => digest}
    end

    def coding_toolchain_identity, do: toolchain_identity()
    def validation_capacity_observer, do: :available

    def coding_dependency_baseline_admission(_repo_path, _base_ref),
      do: {:ok, %{"matched" => true}}

    def coding_validation_runtime_admission do
      {:ok,
       %{
         "driver" => "podman",
         "state" => "pinned",
         "probe" => "passed",
         "host_os" => "linux"
       }}
    end

    defp toolchain_identity do
      base = %{
        "schema_version" => 1,
        "platform" => "unix:test",
        "architecture" => "test",
        "otp_release" => "28",
        "elixir_version" => "1.19.5",
        "mix_wrapper_path" => "/reviewed/bin/mix",
        "runtime_roots" => %{
          "erlang_root" => "/runtime/erlang",
          "elixir_root" => "/runtime/elixir"
        }
      }

      {:ok, Map.put(base, "identity_digest", sha256(canonical_json(base)))}
    end

    defp canonical_json(value) when is_map(value) do
      value
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, nested} -> [Jason.encode!(key), ":", canonical_json(nested)] end)
      |> then(&["{", Enum.intersperse(&1, ","), "}"])
    end

    defp canonical_json(value) when is_list(value),
      do: ["[", Enum.intersperse(Enum.map(value, &canonical_json/1), ","), "]"]

    defp canonical_json(value), do: Jason.encode!(value)
    defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  defmodule PipelineStatusETS do
    @moduledoc false
    @table :g3b_cmd_pipeline_status

    def ensure! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end
    end

    def put_record(id, record) do
      ensure!()
      :ets.insert(@table, {id, record})
      :ok
    end

    def get_record(id) do
      ensure!()

      case :ets.lookup(@table, id) do
        [{^id, record}] -> record
        _ -> nil
      end
    end

    def get(id), do: get_record(id)
    def mark_abandoned(_id), do: :ok
  end

  defmodule TrackingSecurity do
    @moduledoc false
    @table :g3b_cmd_task_control_security

    def ensure_table! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ok
    end

    def reset! do
      ensure_table!()
      :ets.insert(@table, {:revokes_by_task, []})
      :ets.insert(@table, {:caps, %{}})
      :ok
    end

    def ensure!, do: reset!()

    def grant(opts) do
      ensure_table!()
      task_id = opts[:task_id]
      kind = get_in(opts, [:metadata, :kind]) || "k"
      id = "cap_#{kind}_#{System.unique_integer([:positive])}"
      caps = lookup_caps()
      record = %{id: id, resource_uri: opts[:resource], task_id: task_id}
      :ets.insert(@table, {:caps, Map.put(caps, task_id, [record | Map.get(caps, task_id, [])])})
      {:ok, record}
    end

    def revoke(capability_id) do
      ensure_table!()

      caps =
        Map.new(lookup_caps(), fn {task_id, records} ->
          {task_id, Enum.reject(records, &(&1.id == capability_id))}
        end)

      :ets.insert(@table, {:caps, caps})
      :ok
    end

    def revoke_by_task(task_id) do
      ensure_table!()
      revokes = lookup(:revokes_by_task, [])
      :ets.insert(@table, {:revokes_by_task, [task_id | revokes]})
      caps = lookup_caps()
      :ets.insert(@table, {:caps, Map.put(caps, task_id, [])})
      {:ok, 0}
    end

    def list_capabilities(_principal, opts \\ []) do
      ensure_table!()
      {:ok, Map.get(lookup_caps(), Keyword.get(opts, :task_id), [])}
    end

    def caps_for(task_id), do: Map.get(lookup_caps(), task_id, [])
    def revokes_by_task, do: lookup(:revokes_by_task, [])

    defp lookup_caps do
      case :ets.lookup(@table, :caps) do
        [{:caps, map}] -> map
        _ -> %{}
      end
    end

    defp lookup(key, default) do
      case :ets.lookup(@table, key) do
        [{^key, value}] -> value
        _ -> default
      end
    end
  end

  setup do
    unless Process.whereis(Arbor.Security.UriRegistry) do
      start_supervised!({Arbor.Security.UriRegistry, []})
    end

    originals = %{
      runner: Application.get_env(:arbor_orchestrator, :coding_pipeline_runner),
      compiler: Application.get_env(:arbor_orchestrator, :coding_plan_compiler),
      logs: Application.get_env(:arbor_orchestrator, :coding_pipeline_logs_root),
      repos: Application.get_env(:arbor_orchestrator, :coding_repo_roots),
      worktrees: Application.get_env(:arbor_orchestrator, :coding_worktree_roots),
      security: Application.get_env(:arbor_orchestrator, :security_module),
      available: Application.get_env(:arbor_orchestrator, :security_available_override),
      status: Application.get_env(:arbor_orchestrator, :pipeline_status_module),
      path: Application.get_env(:arbor_orchestrator, :coding_pipeline_path),
      readiness_observer:
        Application.get_env(:arbor_orchestrator, :coding_readiness_observer_module),
      readiness_security:
        Application.get_env(:arbor_orchestrator, :coding_readiness_security_module),
      executors: Application.get_env(:arbor_agent, :task_executors)
    }

    tmp =
      Path.join(System.tmp_dir!(), "g3b-taskstore-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    repo_scope = Path.join(tmp, "repo-scope")
    repo = Path.join(repo_scope, "repo")
    worktrees = Path.join(tmp, "worktrees")
    File.mkdir_p!(repo_scope)
    File.mkdir_p!(worktrees)
    File.mkdir_p!(repo)
    {_out, 0} = System.cmd("git", ["init", "--quiet", repo], stderr_to_stdout: true)
    {:ok, tmp} = Arbor.Common.SafePath.resolve_real(tmp)
    {:ok, repo_scope} = Arbor.Common.SafePath.resolve_real(repo_scope)
    {:ok, worktrees} = Arbor.Common.SafePath.resolve_real(worktrees)
    {:ok, repo} = Arbor.Common.SafePath.resolve_real(repo)

    Application.put_env(:arbor_orchestrator, :coding_pipeline_runner, CapturingRunner)
    Application.put_env(:arbor_orchestrator, :coding_plan_compiler, FakeCompiler)

    Application.put_env(
      :arbor_orchestrator,
      :coding_pipeline_logs_root,
      Path.join(tmp, "artifacts")
    )

    Application.put_env(:arbor_orchestrator, :coding_repo_roots, [repo_scope])
    Application.put_env(:arbor_orchestrator, :coding_worktree_roots, [worktrees])
    Application.put_env(:arbor_orchestrator, :security_module, FakeSecurity)
    Application.put_env(:arbor_orchestrator, :security_available_override, true)
    Application.put_env(:arbor_orchestrator, :pipeline_status_module, PipelineStatusETS)

    Application.put_env(
      :arbor_orchestrator,
      :coding_readiness_observer_module,
      ReadinessObservers
    )

    Application.put_env(:arbor_orchestrator, :coding_readiness_security_module, FakeSecurity)

    graph_path = Arbor.Orchestrator.Config.coding_pipeline_path()

    if is_binary(graph_path) and not File.exists?(graph_path) do
      fallback = Path.join(:code.priv_dir(:arbor_orchestrator), "pipelines/coding-change-v1.dot")
      Application.put_env(:arbor_orchestrator, :coding_pipeline_path, fallback)
    end

    Application.put_env(
      :arbor_agent,
      :task_executors,
      %{"coding_change" => CodingTaskExecutor}
    )

    PipelineStatusETS.ensure!()
    TrackingSecurity.ensure!()
    TaskControlRecoveryMemory.reset!()

    on_exit(fn ->
      restore(:arbor_orchestrator, :coding_pipeline_runner, originals.runner)
      restore(:arbor_orchestrator, :coding_plan_compiler, originals.compiler)
      restore(:arbor_orchestrator, :coding_pipeline_logs_root, originals.logs)
      restore(:arbor_orchestrator, :coding_repo_roots, originals.repos)
      restore(:arbor_orchestrator, :coding_worktree_roots, originals.worktrees)
      restore(:arbor_orchestrator, :security_module, originals.security)
      restore(:arbor_orchestrator, :security_available_override, originals.available)
      restore(:arbor_orchestrator, :pipeline_status_module, originals.status)
      restore(:arbor_orchestrator, :coding_pipeline_path, originals.path)

      restore(
        :arbor_orchestrator,
        :coding_readiness_observer_module,
        originals.readiness_observer
      )

      restore(
        :arbor_orchestrator,
        :coding_readiness_security_module,
        originals.readiness_security
      )

      restore(:arbor_agent, :task_executors, originals.executors)
      File.rm_rf(tmp)
    end)

    suffix = System.unique_integer([:positive, :monotonic])

    {:ok,
     repo: repo,
     tmp: tmp,
     agent: "agent_g3b_taskstore_#{suffix}",
     caller: "caller_g3b_taskstore_#{suffix}",
     task_id: "task_g3b_taskstore_#{suffix}"}
  end

  test "TaskStore restart recovers a real CodingTaskExecutor terminal and finalizes", %{
    repo: repo,
    agent: agent,
    caller: caller,
    task_id: task_id
  } do
    context = %{"task_id" => task_id, "caller_id" => caller}

    task = %{
      "kind" => "coding_change",
      "task" => "add a feature",
      "repo_path" => repo,
      "acp_agent" => "codex"
    }

    assert {:ok, original} = CodingTaskExecutor.run(agent, task, context)
    assert original["status"] == "change_committed"
    root = task_root(task_id)
    {:ok, binding} = ArtifactStore.read_run_binding(root)

    PipelineStatusETS.put_record(task_id, %{
      run_id: task_id,
      execution_principal: agent,
      graph_hash: binding["graph_hash"],
      status: :interrupted
    })

    {:ok, marker} =
      TaskControlLease.marker_new(task_id, DateTime.utc_now(), %{
        agent_id: agent,
        executor_kind: "coding_change",
        control_principal_id: caller,
        cleanup: %{"caller_id" => caller, "principal_id" => agent}
      })

    assert {:ok, _} =
             TaskControlRecoveryMemory.buffered_store_acknowledged_put(
               :arbor_agent_task_control_recovery,
               task_id,
               marker
             )

    for kind <- TaskControlLease.grant_order() do
      {:ok, spec} = TaskControlLease.grant_spec(kind, caller, task_id, DateTime.utc_now())
      assert {:ok, _} = TrackingSecurity.grant(spec)
    end

    supervisor = start_supervised!({Task.Supervisor, name: unique(:sup)})

    store =
      start_supervised!(
        {TaskStore,
         name: unique(:store),
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: false,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_control_security_module: TrackingSecurity,
         runner: CodingTaskExecutor},
        id: unique(:store_id)
      )

    assert wait_until(fn -> TaskStore.recovery_ready?(name: store) end)

    unless wait_until(
             fn ->
               match?({:ok, %{state: :done}}, TaskStore.status(task_id, name: store))
             end,
             1_000
           ) do
      store_state = :sys.get_state(store)
      recovery_pid = get_in(store_state, [:tasks, task_id, :pid])
      finalization_error = get_in(store_state, [:tasks, task_id, :error])
      stack = if is_pid(recovery_pid), do: Process.info(recovery_pid, :current_stacktrace)

      flunk(
        "timeout waiting for recovered terminal; " <>
          "status=#{inspect(TaskStore.status(task_id, name: store))}; " <>
          "result=#{inspect(TaskStore.result(task_id, name: store))}; " <>
          "finalization_error=#{inspect(finalization_error)}; " <>
          "recovery_stack=#{inspect(stack)}"
      )
    end

    assert {:ok, completed} = TaskStore.result(task_id, name: store)
    assert completed.result_type == :coding_change
    recovered = completed.raw
    assert recovered["status"] == "change_committed"
    assert is_map(recovered["verification_report"])
    assert recovered["artifacts"]["graph_hash"] == original["artifacts"]["graph_hash"]
    assert is_map(recovered["artifacts"]["task_evidence"])

    {:ok, task_read_uri} = TaskControlLease.uri(:task_read, task_id)
    {:ok, task_adopt_uri} = TaskControlLease.uri(:task_adopt, task_id)

    assert wait_until(fn ->
             task_id
             |> TrackingSecurity.caps_for()
             |> Enum.map(& &1.resource_uri)
             |> MapSet.new() == MapSet.new([task_read_uri, task_adopt_uri])
           end)

    refute task_id in TrackingSecurity.revokes_by_task()

    assert {:ok, _marker} =
             TaskControlRecoveryMemory.buffered_store_authoritative_get(
               :arbor_agent_task_control_recovery,
               task_id
             )
  end

  defp task_root(task_id) do
    base = Application.fetch_env!(:arbor_orchestrator, :coding_pipeline_logs_root)
    digest = :crypto.hash(:sha256, task_id) |> Base.encode16(case: :lower)
    Path.join(base, "task-" <> digest)
  end

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
