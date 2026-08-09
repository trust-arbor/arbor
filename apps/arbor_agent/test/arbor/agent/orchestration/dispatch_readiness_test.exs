defmodule Arbor.Agent.Orchestration.DispatchReadinessTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Agent.ExactTemplatePolicy
  alias Arbor.Agent.Orchestration.DispatchReadiness
  alias Arbor.Agent.Orchestration.DispatchReadinessCore
  alias Arbor.Agent.Profile

  defmodule EffectsObserver do
    @moduledoc false
    @table :dispatch_readiness_effects

    # Create table once; reset only via reset!/0 so reads never erase events.
    def ensure! do
      case :ets.whereis(@table) do
        :undefined ->
          _ = :ets.new(@table, [:named_table, :public, :set])
          :ets.insert(@table, {:events, []})
          :ok

        _ ->
          :ok
      end
    end

    def reset! do
      ensure!()
      :ets.insert(@table, {:events, []})
      :ok
    end

    def record(event) do
      ensure!()

      case :ets.lookup(@table, :events) do
        [{:events, events}] ->
          :ets.insert(@table, {:events, [event | events]})

        _ ->
          :ets.insert(@table, {:events, [event]})
      end

      :ok
    end

    def events do
      ensure!()

      case :ets.lookup(@table, :events) do
        [{:events, events}] -> Enum.reverse(events)
        _ -> []
      end
    end
  end

  defmodule FakeSecurity do
    @moduledoc false
    def healthy?, do: Process.get({__MODULE__, :healthy?}, true)

    def list_capabilities(principal_id, opts \\ []) do
      EffectsObserver.record({:list_capabilities, principal_id, opts})

      case Process.get({__MODULE__, :list_result}) do
        {:error, reason} ->
          {:error, reason}

        _ ->
          include_expired? = Keyword.get(opts, :include_expired, false)
          active = Process.get({__MODULE__, :active_caps}, [])
          expired = Process.get({__MODULE__, :expired_caps}, [])
          caps = if include_expired?, do: active ++ expired, else: active
          {:ok, caps}
      end
    end

    def stats do
      case Process.get({__MODULE__, :stats_override}) do
        nil ->
          Process.get({__MODULE__, :stats}, %{
            capabilities: %{
              restore_scanned: 1,
              restore_active: 1,
              restore_expired: 0,
              restore_superseded: 0,
              restore_rejected: 0,
              active_capabilities: Process.get({__MODULE__, :active_capabilities}, 0),
              quota_max_global: Process.get({__MODULE__, :max_global}, 1000),
              quota_max_per_agent: Process.get({__MODULE__, :max_per}, 20),
              quota_enforcement_enabled: Process.get({__MODULE__, :enforcement?}, true)
            },
            healthy: true
          })

        other ->
          other
      end
    end

    def grant(opts) do
      EffectsObserver.record({:grant, opts})
      flunk("readiness must not grant")
    end

    def revoke(id) do
      EffectsObserver.record({:revoke, id})
      flunk("readiness must not revoke")
    end
  end

  defmodule FakeLifecycle do
    def get_host(_agent_id) do
      case Process.get({__MODULE__, :host}, :__unset__) do
        {:ok, pid} = ok when is_pid(pid) -> ok
        :absent -> {:error, :no_host}
        :raise -> raise "lifecycle boom"
        :throw -> throw(:lifecycle_throw)
        :exit -> exit(:lifecycle_exit)
        :malformed -> :not_a_host_result
        # Process.put(key, nil) deletes the key; use a sentinel for bare nil returns.
        :return_nil -> nil
        :__unset__ -> {:error, :no_host}
        # Preserve bare :error / error tuples so shell classification is tested.
        other -> other
      end
    end
  end

  defmodule FakeTaskStore do
    def recovery_ready? do
      case Process.get({__MODULE__, :recovery_ready?}, true) do
        :raise -> raise "recovery boom"
        :malformed -> :not_a_boolean
        other -> other
      end
    end

    def reserve(opts) do
      EffectsObserver.record({:reserve, opts})
      flunk("readiness must not reserve")
    end

    def dispatch(a, t, o) do
      EffectsObserver.record({:dispatch, a, t, o})
      flunk("readiness must not dispatch")
    end

    def activate(a, t, id, tok, o) do
      EffectsObserver.record({:activate, a, t, id, tok, o})
      flunk("readiness must not activate")
    end
  end

  defmodule FakeProfileStore do
    def load_profile_readonly(agent_id) do
      case Process.get({__MODULE__, :profile}) do
        %Profile{} = p -> {:ok, p}
        {:error, _} = err -> err
        nil -> {:error, :not_found}
        other -> other
      end
      |> tap(fn _ -> EffectsObserver.record({:load_profile_readonly, agent_id}) end)
    end

    def store_profile(profile) do
      EffectsObserver.record({:store_profile, profile})
      flunk("readiness must not store profiles")
    end

    def load_profile(agent_id) do
      EffectsObserver.record({:load_profile_migrating, agent_id})
      flunk("readiness must use load_profile_readonly")
    end
  end

  defmodule FakeTemplateStore do
    def get_current(name) do
      EffectsObserver.record({:get_current, name})

      case Process.get({__MODULE__, :template}) do
        {:ok, data} -> {:ok, data}
        {:error, _} = err -> err
        data when is_map(data) -> {:ok, data}
        nil -> {:error, :not_found}
      end
    end

    def get(name) do
      EffectsObserver.record({:get_cache_write, name})
      flunk("readiness must use get_current")
    end

    def put(name, data) do
      EffectsObserver.record({:put, name, data})
      flunk("readiness must not put templates")
    end

    def reconcile(name) do
      EffectsObserver.record({:reconcile, name})
      flunk("readiness must not reconcile templates")
    end
  end

  defmodule FakeConfig do
    def task_executor(_kind) do
      case Process.get({__MODULE__, :executor}, {:ok, ReadyExecutor}) do
        {:ok, mod} when is_atom(mod) -> {:ok, mod}
        {:error, _} = err -> err
        mod when is_atom(mod) -> {:ok, mod}
        other -> other
      end
    end

    def normalize_kind(kind) when is_binary(kind) and kind != "", do: {:ok, kind}
    def normalize_kind(kind) when is_atom(kind), do: {:ok, Atom.to_string(kind)}
    def normalize_kind(_), do: {:error, :invalid_task_kind}

    def executor_callback_timeout_ms, do: 250
  end

  defmodule ReadyExecutor do
    def run(_a, _t, _c), do: {:ok, %{}}

    def project_dispatch_readiness(agent_id, task, context) do
      EffectsObserver.record({:project_dispatch_readiness, agent_id, task, context})

      {:ok,
       %{
         "version" => 1,
         "kind" => "coding_dispatch_readiness",
         "status" => "ready",
         "agent_id" => agent_id
       }}
    end
  end

  defmodule MissingCallbackExecutor do
    def run(_a, _t, _c), do: {:ok, %{}}
  end

  defmodule NonJsonExecutor do
    def run(_a, _t, _c), do: {:ok, %{}}
    def project_dispatch_readiness(_a, _t, _c), do: {:ok, %{:atom_key => self()}}
  end

  defmodule RaisingExecutor do
    def run(_a, _t, _c), do: {:ok, %{}}
    def project_dispatch_readiness(_a, _t, _c), do: raise("executor boom")
  end

  defmodule ThrowingExecutor do
    def run(_a, _t, _c), do: {:ok, %{}}
    def project_dispatch_readiness(_a, _t, _c), do: throw(:executor_throw)
  end

  defmodule ExitingExecutor do
    def run(_a, _t, _c), do: {:ok, %{}}
    def project_dispatch_readiness(_a, _t, _c), do: exit(:executor_exit)
  end

  defmodule HangingExecutor do
    def run(_a, _t, _c), do: {:ok, %{}}

    def project_dispatch_readiness(_a, _t, _c) do
      Process.sleep(60_000)
      {:ok, %{"status" => "ready"}}
    end
  end

  defmodule MutatingOnlyProfileStore do
    def load_profile(agent_id) do
      EffectsObserver.record({:load_profile_migrating, agent_id})
      flunk("must not fall back to load_profile")
    end
  end

  defmodule MutatingOnlyTemplateStore do
    def get(name) do
      EffectsObserver.record({:get_cache_write, name})
      flunk("must not fall back to get/1")
    end
  end

  defmodule FakeExactPolicy do
    def from_metadata(metadata) do
      case Process.get({__MODULE__, :from_metadata}) do
        nil -> ExactTemplatePolicy.from_metadata(metadata)
        fun when is_function(fun, 1) -> fun.(metadata)
        other -> other
      end
    end

    def digest(envelope), do: ExactTemplatePolicy.digest(envelope)
    def snapshot(envelope), do: ExactTemplatePolicy.snapshot(envelope)

    def build(name, data, opts) do
      case Process.get({__MODULE__, :build}) do
        nil -> ExactTemplatePolicy.build(name, data, opts)
        fun when is_function(fun, 3) -> fun.(name, data, opts)
        other -> other
      end
    end
  end

  setup do
    EffectsObserver.reset!()
    ensure_task_supervisor!()

    Process.put({FakeSecurity, :healthy?}, true)
    Process.put({FakeSecurity, :enforcement?}, true)
    Process.put({FakeSecurity, :max_per}, 20)
    Process.put({FakeSecurity, :max_global}, 1000)
    Process.put({FakeSecurity, :active_capabilities}, 0)
    Process.put({FakeSecurity, :active_caps}, [])
    Process.put({FakeSecurity, :expired_caps}, [])
    Process.delete({FakeSecurity, :list_result})
    Process.delete({FakeSecurity, :stats_override})
    Process.put({FakeLifecycle, :host}, {:ok, self()})
    Process.put({FakeTaskStore, :recovery_ready?}, true)
    Process.put({FakeConfig, :executor}, {:ok, ReadyExecutor})

    Process.put(
      {FakeProfileStore, :profile},
      %Profile{
        agent_id: "agent_target1",
        character: Arbor.Agent.Character.new(name: "T"),
        template: "pipeline_architect",
        metadata: %{},
        created_at: DateTime.utc_now()
      }
    )

    Process.put({FakeTemplateStore, :template}, {:error, :not_found})
    Process.put({FakeExactPolicy, :from_metadata}, :not_marked)

    :ok
  end

  defp ensure_task_supervisor! do
    case Process.whereis(Arbor.Agent.Orchestration.TaskSupervisor) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        {:ok, _pid} =
          Task.Supervisor.start_link(name: Arbor.Agent.Orchestration.TaskSupervisor)

        :ok
    end
  end

  # Injected invoke_executor for pure collaborator tests.
  defp deps(extra \\ %{}) do
    Map.merge(
      %{
        security: FakeSecurity,
        lifecycle: FakeLifecycle,
        profile_store: FakeProfileStore,
        template_store: FakeTemplateStore,
        task_store: FakeTaskStore,
        config: FakeConfig,
        exact_policy: FakeExactPolicy,
        clock: fn -> ~U[2026-08-09 00:00:00Z] end,
        callback_timeout_ms: 250,
        invoke_executor: fn module, agent_id, task, context, _timeout_ms ->
          module.project_dispatch_readiness(agent_id, task, context)
        end
      },
      extra
    )
  end

  # Production-default callback path: no invoke_executor override.
  defp production_callback_deps(extra) do
    base = deps(extra)
    Map.delete(base, :invoke_executor)
  end

  defp coding_task, do: %{"kind" => "coding_change", "goal" => "ship"}

  test "unmarked legacy template is explicitly unmanaged/degraded without writes" do
    assert {:ok, report} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert report["planes"]["exact_template"]["status"] == "degraded"
    assert report["planes"]["exact_template"]["details"]["template_state"] == "unmanaged"
    assert report["status"] in ["degraded", "blocked", "ready"]

    events = EffectsObserver.events()
    refute Enum.any?(events, &match?({:store_profile, _}, &1))
    refute Enum.any?(events, &match?({:put, _, _}, &1))
    refute Enum.any?(events, &match?({:load_profile_migrating, _}, &1))
  end

  test "managed exact template current requires closed source provenance" do
    envelope = %{
      "version" => 1,
      "snapshot" => %{
        "version" => 1,
        "template" => "pipeline_architect",
        "metadata" => %{},
        "repo_root" => nil,
        "sandbox_level" => "strict",
        "capabilities" => [],
        "trust_preset" => %{"baseline" => "ask", "rules" => %{}}
      },
      "digest" => String.duplicate("a", 64)
    }

    Process.put({FakeExactPolicy, :from_metadata}, fn _ -> {:ok, envelope} end)

    Process.put({FakeExactPolicy, :build}, fn _n, _d, _o ->
      {:ok, %{envelope | "digest" => String.duplicate("a", 64)}}
    end)

    for layer <- ["user", "shipped", "legacy_json"] do
      Process.put(
        {FakeTemplateStore, :template},
        %{
          "name" => "pipeline_architect",
          "template_source" => %{"layer" => layer, "name" => "pipeline_architect", "path" => "/t"}
        }
      )

      assert {:ok, current_report} =
               DispatchReadiness.project_with_deps(
                 "agent_target1",
                 coding_task(),
                 [caller_id: "human_caller1"],
                 deps()
               )

      assert current_report["planes"]["exact_template"]["details"]["template_state"] == "current"
      assert current_report["planes"]["exact_template"]["details"]["source_layer"] == layer
    end

    # Missing provenance cannot be current.
    Process.put({FakeTemplateStore, :template}, %{"name" => "pipeline_architect"})

    assert {:ok, missing_source} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert missing_source["planes"]["exact_template"]["details"]["template_state"] == "invalid"
    refute missing_source["planes"]["exact_template"]["details"]["template_state"] == "current"
    assert missing_source["planes"]["exact_template"]["status"] == "blocked"

    # Unknown provenance cannot be current.
    Process.put(
      {FakeTemplateStore, :template},
      %{
        "name" => "pipeline_architect",
        "template_source" => %{"layer" => "mystery", "name" => "pipeline_architect"}
      }
    )

    assert {:ok, unknown_source} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert unknown_source["planes"]["exact_template"]["details"]["template_state"] == "invalid"
    refute unknown_source["planes"]["exact_template"]["details"]["template_state"] == "current"

    # Drift still blocks.
    Process.put(
      {FakeTemplateStore, :template},
      %{
        "name" => "pipeline_architect",
        "template_source" => %{"layer" => "shipped", "name" => "pipeline_architect"}
      }
    )

    Process.put({FakeExactPolicy, :build}, fn _n, _d, _o ->
      {:ok, %{envelope | "digest" => String.duplicate("b", 64)}}
    end)

    assert {:ok, drifted_report} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert drifted_report["planes"]["exact_template"]["details"]["template_state"] == "drifted"
    assert drifted_report["planes"]["exact_template"]["status"] == "blocked"
    assert drifted_report["status"] == "blocked"
  end

  test "security unhealthy and recovery-not-ready block; healthy quota reports six members" do
    Process.put({FakeSecurity, :healthy?}, false)

    assert {:ok, unhealthy} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert unhealthy["planes"]["security"]["status"] == "blocked"
    assert unhealthy["status"] == "blocked"

    Process.put({FakeSecurity, :healthy?}, true)
    Process.put({FakeTaskStore, :recovery_ready?}, false)

    assert {:ok, recovery} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert recovery["planes"]["task_control"]["status"] == "blocked"
    assert recovery["planes"]["task_control"]["details"]["recovery_ready"] == false

    Process.put({FakeTaskStore, :recovery_ready?}, true)
    Process.put({FakeSecurity, :active_caps}, List.duplicate(%{id: "x"}, 2))
    Process.put({FakeSecurity, :expired_caps}, [])
    Process.put({FakeSecurity, :max_per}, 20)
    Process.put({FakeSecurity, :active_capabilities}, 2)

    assert {:ok, ready} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    members = ready["planes"]["task_control"]["details"]["members"]
    assert map_size(members) == 6

    for {_role, member} <- members do
      assert member["provisionable"] == true
      refute Map.has_key?(member, "id")
      refute Map.has_key?(member, "capability_id")
    end

    # No capability ids escape the report
    refute inspect(ready) =~ "cap_"
  end

  test "coordinator absent blocks; infrastructure failure and raise are error" do
    Process.put({FakeLifecycle, :host}, :absent)

    assert {:ok, absent} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert absent["planes"]["coordinator"]["status"] == "blocked"
    assert absent["planes"]["coordinator"]["code"] == "coordinator_absent"
    assert absent["planes"]["coordinator"]["details"]["host_state"] == "absent"

    # Only {:error, :no_host} is ordinary absence; other error tuples are error.
    Process.put({FakeLifecycle, :host}, {:error, :registry_down})

    assert {:ok, registry_down} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert registry_down["planes"]["coordinator"]["status"] == "error"
    assert registry_down["planes"]["coordinator"]["code"] == "coordinator_projection_failed"
    assert registry_down["planes"]["coordinator"]["details"]["host_state"] == "error"
    assert registry_down["status"] == "error"

    Process.put({FakeLifecycle, :host}, :error)

    assert {:ok, bare_error} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert bare_error["planes"]["coordinator"]["status"] == "error"

    Process.put({FakeLifecycle, :host}, :return_nil)

    assert {:ok, nil_host} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert nil_host["planes"]["coordinator"]["status"] == "error"

    Process.put({FakeLifecycle, :host}, :raise)

    assert {:ok, raised} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert raised["planes"]["coordinator"]["status"] == "error"
    assert raised["status"] == "error"
    refute inspect(raised) =~ "lifecycle boom"
    assert Process.alive?(self())

    Process.put({FakeLifecycle, :host}, :throw)

    assert {:ok, thrown} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert thrown["planes"]["coordinator"]["status"] == "error"
    assert Process.alive?(self())

    Process.put({FakeLifecycle, :host}, :exit)

    assert {:ok, exited} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert exited["planes"]["coordinator"]["status"] == "error"
    assert Process.alive?(self())

    Process.put({FakeLifecycle, :host}, :malformed)

    assert {:ok, malformed} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert malformed["planes"]["coordinator"]["status"] == "error"
  end

  test "recovery not-ready blocks; raising/malformed recovery is error" do
    Process.put({FakeTaskStore, :recovery_ready?}, false)

    assert {:ok, blocked} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert blocked["planes"]["task_control"]["status"] == "blocked"

    Process.put({FakeTaskStore, :recovery_ready?}, :raise)

    assert {:ok, raised} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert raised["planes"]["task_control"]["status"] == "error"
    assert raised["status"] == "error"
    refute inspect(raised) =~ "recovery boom"

    Process.put({FakeTaskStore, :recovery_ready?}, :malformed)

    assert {:ok, malformed} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert malformed["planes"]["task_control"]["status"] == "error"
  end

  test "include_expired principal count blocks when active-only would fit" do
    # max_per=10; active-only count=3 would fit (3+6<=10) but indexed/include_expired=5 does not (5+6>10)
    Process.put({FakeSecurity, :max_per}, 10)
    Process.put({FakeSecurity, :active_capabilities}, 0)
    Process.put({FakeSecurity, :active_caps}, List.duplicate(%{id: "active"}, 3))
    Process.put({FakeSecurity, :expired_caps}, List.duplicate(%{id: "expired"}, 2))

    assert {:ok, report} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert report["planes"]["task_control"]["status"] == "blocked"
    assert report["planes"]["task_control"]["details"]["quota"]["sufficient_for_lease"] == false
    assert report["planes"]["task_control"]["code"] == "quota_insufficient_principal"

    assert Enum.any?(EffectsObserver.events(), fn
             {:list_capabilities, "human_caller1", opts} ->
               Keyword.get(opts, :include_expired) == true

             _ ->
               false
           end)

    # active-only path would have been sufficient — prove counterfactual via core
    active_only =
      DispatchReadinessCore.project_task_control(%{
        facts_available?: true,
        recovery_ready?: true,
        quota_enforcement_enabled?: true,
        principal_indexed_count: 3,
        active_capabilities: 0,
        max_per_principal: 10,
        max_global: 1000
      })

    assert active_only["status"] == "ready"
  end

  test "list_capabilities error and missing quota enforcement fail closed" do
    Process.put({FakeSecurity, :list_result}, {:error, :store_down})

    assert {:ok, report} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert report["planes"]["security"]["status"] == "blocked"
    assert report["planes"]["security"]["code"] == "security_facts_unavailable"
    assert report["planes"]["task_control"]["status"] == "blocked"
    assert report["planes"]["task_control"]["code"] == "quota_facts_unavailable"

    Process.put({FakeSecurity, :list_result}, nil)

    Process.put(
      {FakeSecurity, :stats_override},
      %{
        capabilities: %{
          restore_scanned: 1,
          restore_active: 1,
          restore_expired: 0,
          restore_superseded: 0,
          restore_rejected: 0,
          active_capabilities: 0,
          quota_max_global: 1000,
          quota_max_per_agent: 20
          # quota_enforcement_enabled intentionally absent
        }
      }
    )

    assert {:ok, missing_enforcement} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert missing_enforcement["planes"]["security"]["status"] == "blocked"
    assert missing_enforcement["planes"]["task_control"]["status"] == "blocked"
  end

  test "executor callback receives exact task plus caller_id/timeout and no task_id" do
    task = coding_task()

    assert {:ok, _report} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               task,
               [caller_id: "human_caller1", timeout: 12_000],
               deps()
             )

    assert Enum.any?(EffectsObserver.events(), fn
             {:project_dispatch_readiness, "agent_target1", ^task, context} ->
               context == %{"caller_id" => "human_caller1", "timeout" => 12_000} and
                 not Map.has_key?(context, "task_id")

             _ ->
               false
           end)
  end

  test "missing callback, non-json, and raise fail closed with bounded diagnostics" do
    Process.put({FakeConfig, :executor}, {:ok, MissingCallbackExecutor})

    assert {:ok, missing} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert missing["planes"]["executor"]["status"] == "blocked"
    assert missing["planes"]["executor"]["code"] == "executor_callback_missing"

    Process.put({FakeConfig, :executor}, {:ok, NonJsonExecutor})

    assert {:ok, non_json} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert non_json["planes"]["executor"]["status"] == "error"
    assert non_json["planes"]["executor"]["code"] == "executor_non_json"
    assert non_json["planes"]["executor"]["details"]["projection"] == nil

    Process.put({FakeConfig, :executor}, {:ok, ReadyExecutor})

    assert {:ok, missing_status} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps(%{
                 invoke_executor: fn _m, _a, _t, _c, _timeout ->
                   {:ok, %{"kind" => "coding_dispatch_readiness"}}
                 end
               })
             )

    assert missing_status["planes"]["executor"]["status"] == "error"
    assert missing_status["planes"]["executor"]["code"] == "executor_status_missing"

    assert {:ok, raised} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps(%{
                 invoke_executor: fn _m, _a, _t, _c, _timeout -> raise "nope" end
               })
             )

    assert raised["status"] in ["blocked", "error"]
    refute inspect(raised) =~ "nope"
  end

  test "production-default callback ready/raise/throw/exit/timeout are bounded and leak-free" do
    caller = self()
    Process.flag(:trap_exit, true)

    # Ready via production default_invoke_executor (no inject).
    Process.put({FakeConfig, :executor}, {:ok, ReadyExecutor})

    assert {:ok, ready} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               production_callback_deps(%{callback_timeout_ms: 500})
             )

    assert ready["planes"]["executor"]["status"] == "ready"
    assert {:ok, _} = DispatchReadinessCore.assert_report(ready)
    assert Process.alive?(caller)

    # Raise
    Process.put({FakeConfig, :executor}, {:ok, RaisingExecutor})

    assert {:ok, raised} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               production_callback_deps(%{callback_timeout_ms: 500})
             )

    assert raised["planes"]["executor"]["status"] == "error"
    assert raised["planes"]["executor"]["code"] == "executor_callback_exception"
    refute inspect(raised) =~ "executor boom"
    assert Process.alive?(caller)

    # Throw
    Process.put({FakeConfig, :executor}, {:ok, ThrowingExecutor})

    assert {:ok, thrown} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               production_callback_deps(%{callback_timeout_ms: 500})
             )

    assert thrown["planes"]["executor"]["status"] == "error"
    assert Process.alive?(caller)

    # Exit
    Process.put({FakeConfig, :executor}, {:ok, ExitingExecutor})

    assert {:ok, exited} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               production_callback_deps(%{callback_timeout_ms: 500})
             )

    assert exited["planes"]["executor"]["status"] == "error"

    assert exited["planes"]["executor"]["code"] in [
             "executor_callback_exit",
             "executor_projection_error"
           ]

    assert Process.alive?(caller)

    # Timeout / hang — child must be gone after brutal kill.
    Process.put({FakeConfig, :executor}, {:ok, HangingExecutor})
    before_children = Task.Supervisor.children(Arbor.Agent.Orchestration.TaskSupervisor)

    assert {:ok, timed_out} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               production_callback_deps(%{callback_timeout_ms: 50})
             )

    assert timed_out["planes"]["executor"]["status"] == "error"
    assert timed_out["planes"]["executor"]["code"] == "executor_callback_timeout"
    assert Process.alive?(caller)

    # Give the supervisor a moment to reap the brutally killed child.
    Process.sleep(20)
    after_children = Task.Supervisor.children(Arbor.Agent.Orchestration.TaskSupervisor)
    refute length(after_children) > length(before_children)

    # No leaked EXIT killed the test process.
    refute_received {:EXIT, _, _}
  end

  test "missing readonly collaborators never call mutating load_profile/get" do
    assert {:ok, report} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps(%{
                 profile_store: MutatingOnlyProfileStore,
                 template_store: MutatingOnlyTemplateStore
               })
             )

    assert report["planes"]["exact_template"]["status"] == "blocked"
    assert report["planes"]["exact_template"]["details"]["template_state"] == "unavailable"

    events = EffectsObserver.events()
    refute Enum.any?(events, &match?({:load_profile_migrating, _}, &1))
    refute Enum.any?(events, &match?({:get_cache_write, _}, &1))
  end

  test "raising clock still returns bounded error report" do
    assert {:ok, report} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps(%{clock: fn -> raise "bad clock" end})
             )

    assert report["status"] == "error"
    assert report["error"]["code"] == "projection_failed"
    assert {:ok, _} = DispatchReadinessCore.assert_report(report)
    refute inspect(report) =~ "bad clock"
  end

  test "callback_timeout_ms dependency is forwarded to invoke_executor" do
    parent = self()

    assert {:ok, _} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps(%{
                 callback_timeout_ms: 321,
                 invoke_executor: fn module, agent_id, task, context, timeout_ms ->
                   send(parent, {:timeout_ms, timeout_ms})
                   module.project_dispatch_readiness(agent_id, task, context)
                 end
               })
             )

    assert_received {:timeout_ms, 321}
  end

  test "no-effects observers: records reads and proves prohibited mutations empty" do
    assert {:ok, report} =
             DispatchReadiness.project_with_deps(
               "agent_target1",
               coding_task(),
               [caller_id: "human_caller1"],
               deps()
             )

    assert {:ok, _} = DispatchReadinessCore.assert_report(report)

    events = EffectsObserver.events()

    # Expected read-side observations must be present (proves observer works).
    assert Enum.any?(events, &match?({:list_capabilities, _, _}, &1))
    assert Enum.any?(events, &match?({:load_profile_readonly, _}, &1))
    assert Enum.any?(events, &match?({:project_dispatch_readiness, _, _, _}, &1))

    # Prohibited mutation set stays empty.
    refute Enum.any?(events, &match?({:reserve, _}, &1))
    refute Enum.any?(events, &match?({:activate, _, _, _, _, _}, &1))
    refute Enum.any?(events, &match?({:dispatch, _, _, _}, &1))
    refute Enum.any?(events, &match?({:grant, _}, &1))
    refute Enum.any?(events, &match?({:revoke, _}, &1))
    refute Enum.any?(events, &match?({:store_profile, _}, &1))
    refute Enum.any?(events, &match?({:put, _, _}, &1))
    refute Enum.any?(events, &match?({:load_profile_migrating, _}, &1))
    refute Enum.any?(events, &match?({:get_cache_write, _}, &1))
    refute Enum.any?(events, &match?({:reconcile, _}, &1))
  end
end
