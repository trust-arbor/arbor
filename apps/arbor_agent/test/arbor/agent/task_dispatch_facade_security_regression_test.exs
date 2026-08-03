defmodule Arbor.Agent.TaskDispatchFacadeSecurityRegressionTest do
  @moduledoc """
  VP-05C security regression: public Arbor.Agent.dispatch_task/4 credential
  boundary. Distinctive human proof reaches only Security authorize opts and
  never TaskStore / grants / audit / retained state.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Agent.DispatchFacade

  @distinctive_token "vp05c-dispatch-security-token-9e4b1c7a"

  defmodule CaptureSecurity do
    @moduledoc false
    @table :arbor_agent_dispatch_facade_security_capture

    def ensure! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ok
    end

    def reset do
      ensure!()
      :ets.insert(@table, {:authorize_calls, []})
      :ets.insert(@table, {:grant_calls, []})
      :ets.insert(@table, {:result, {:ok, :authorized}})
      :ok
    end

    def set_result(result) do
      ensure!()
      :ets.insert(@table, {:result, result})
      :ok
    end

    def authorize_calls do
      ensure!()

      case :ets.lookup(@table, :authorize_calls) do
        [{:authorize_calls, list}] -> list
        _ -> []
      end
    end

    def grant_calls do
      ensure!()

      case :ets.lookup(@table, :grant_calls) do
        [{:grant_calls, list}] -> list
        _ -> []
      end
    end

    def authorize(actor, resource_uri, action, opts) do
      ensure!()
      entry = %{actor: actor, resource_uri: resource_uri, action: action, opts: opts}

      case :ets.lookup(@table, :authorize_calls) do
        [{:authorize_calls, list}] -> :ets.insert(@table, {:authorize_calls, list ++ [entry]})
        _ -> :ets.insert(@table, {:authorize_calls, [entry]})
      end

      case :ets.lookup(@table, :result) do
        [{:result, result}] -> result
        _ -> {:ok, :authorized}
      end
    end

    def grant(opts) do
      ensure!()

      case :ets.lookup(@table, :grant_calls) do
        [{:grant_calls, list}] -> :ets.insert(@table, {:grant_calls, list ++ [opts]})
        _ -> :ets.insert(@table, {:grant_calls, [opts]})
      end

      id = "cap_dispatch_" <> Integer.to_string(System.unique_integer([:positive]))
      {:ok, %{id: id}}
    end

    def revoke(_id), do: :ok
  end

  defmodule CaptureTaskStore do
    @moduledoc false
    @table :arbor_agent_dispatch_facade_task_store_capture

    def ensure! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ok
    end

    def reset do
      ensure!()
      :ets.insert(@table, {:dispatches, []})
      :ok
    end

    def dispatches do
      ensure!()

      case :ets.lookup(@table, :dispatches) do
        [{:dispatches, list}] -> list
        _ -> []
      end
    end

    def dispatch(agent_id, task, opts) do
      ensure!()
      entry = %{agent_id: agent_id, task: task, opts: opts}

      case :ets.lookup(@table, :dispatches) do
        [{:dispatches, list}] -> :ets.insert(@table, {:dispatches, list ++ [entry]})
        _ -> :ets.insert(@table, {:dispatches, [entry]})
      end

      task_id =
        case Keyword.get(opts, :task_id) do
          id when is_binary(id) and id != "" -> id
          _ -> "task_dispatch_" <> Integer.to_string(System.unique_integer([:positive]))
        end

      {:ok, task_id}
    end
  end

  defmodule CaptureAudit do
    @moduledoc false
    @table :arbor_agent_dispatch_facade_audit_capture

    def ensure! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ok
    end

    def reset do
      ensure!()
      :ets.insert(@table, {:records, []})
      :ok
    end

    def records do
      ensure!()

      case :ets.lookup(@table, :records) do
        [{:records, list}] -> list
        _ -> []
      end
    end

    def record_orchestration_task_dispatched(caller_id, task_id, agent_id, data) do
      ensure!()
      entry = %{caller_id: caller_id, task_id: task_id, agent_id: agent_id, data: data}

      case :ets.lookup(@table, :records) do
        [{:records, list}] -> :ets.insert(@table, {:records, list ++ [entry]})
        _ -> :ets.insert(@table, {:records, [entry]})
      end

      :ok
    end
  end

  setup do
    CaptureSecurity.ensure!()
    CaptureSecurity.reset()
    CaptureTaskStore.ensure!()
    CaptureTaskStore.reset()
    CaptureAudit.ensure!()
    CaptureAudit.reset()
    :ok
  end

  defp unique_ids do
    n = System.unique_integer([:positive])
    {"human_dispatch_#{n}", "agent_dispatch_#{n}"}
  end

  defp sample_task do
    %{"kind" => "coding_change", "plan" => %{"version" => 2, "task" => "fix task"}}
  end

  describe "security regression: session_token credential boundary" do
    test "security regression: valid proof + exact dispatch cap authorizes once and strips token" do
      {caller, target} = unique_ids()
      task = sample_task()

      assert {:ok, task_id} =
               Arbor.Agent.Orchestration.dispatch(target, task,
                 caller_id: caller,
                 session_token: @distinctive_token,
                 security_module: CaptureSecurity,
                 task_store: CaptureTaskStore,
                 audit_module: CaptureAudit
               )

      assert is_binary(task_id)
      assert [auth | _] = CaptureSecurity.authorize_calls()
      assert auth.actor == caller
      assert auth.action == :execute
      assert auth.resource_uri in ["arbor://agent/dispatch/#{target}", "arbor://agent/dispatch"]
      assert Keyword.get(auth.opts, :verify_identity) == false
      assert Keyword.get(auth.opts, :session_token) == @distinctive_token

      assert [dispatch] = CaptureTaskStore.dispatches()
      refute Keyword.has_key?(dispatch.opts, :session_token)
      refute Keyword.has_key?(dispatch.opts, "session_token")
      refute inspect(dispatch) =~ @distinctive_token
      assert dispatch.task == task

      for grant <- CaptureSecurity.grant_calls() do
        refute inspect(grant) =~ @distinctive_token
      end

      for record <- CaptureAudit.records() do
        refute inspect(record) =~ @distinctive_token
      end
    end

    test "security regression: missing capability never dispatches" do
      {caller, target} = unique_ids()
      CaptureSecurity.set_result({:error, :no_capability})

      assert {:error, {:unauthorized, _}} =
               Arbor.Agent.Orchestration.dispatch(target, sample_task(),
                 caller_id: caller,
                 session_token: @distinctive_token,
                 security_module: CaptureSecurity,
                 task_store: CaptureTaskStore,
                 audit_module: CaptureAudit
               )

      assert CaptureTaskStore.dispatches() == []
      assert CaptureSecurity.grant_calls() == []
    end

    test "security regression: wrong-scope capability never dispatches" do
      {caller, target} = unique_ids()

      # Only authorize unrelated URI — dispatch scoped URIs denied.
      CaptureSecurity.set_result({:error, :no_capability})

      assert {:error, {:unauthorized, _}} =
               Arbor.Agent.Orchestration.dispatch(target, sample_task(),
                 caller_id: caller,
                 session_token: @distinctive_token,
                 security_module: CaptureSecurity,
                 task_store: CaptureTaskStore
               )

      assert CaptureTaskStore.dispatches() == []
    end

    test "security regression: malformed and alias-duplicate proofs deny before dispatch" do
      {caller, target} = unique_ids()

      for bad_opts <- [
            [caller_id: caller, session_token: nil],
            [caller_id: caller, session_token: ""],
            [caller_id: caller, session_token: :atom],
            [caller_id: caller, session_token: String.duplicate("x", 4097)],
            [caller_id: caller, session_token: "a", session_token: "b"],
            [caller_id: caller, session_token: "a", {"session_token", "b"}],
            [caller_id: caller, {"session_token", nil}]
          ] do
        CaptureTaskStore.reset()
        CaptureSecurity.reset()

        opts =
          bad_opts ++
            [security_module: CaptureSecurity, task_store: CaptureTaskStore]

        assert {:error, {:unauthorized, _}} =
                 Arbor.Agent.Orchestration.dispatch(target, sample_task(), opts)

        assert CaptureTaskStore.dispatches() == []
        assert CaptureSecurity.grant_calls() == []
      end
    end

    test "security regression: string-keyed session_token is accepted once and stripped" do
      {caller, target} = unique_ids()

      assert {:ok, _task_id} =
               Arbor.Agent.Orchestration.dispatch(
                 target,
                 sample_task(),
                 [
                   {:caller_id, caller},
                   {"session_token", @distinctive_token},
                   {:security_module, CaptureSecurity},
                   {:task_store, CaptureTaskStore},
                   {:audit_module, CaptureAudit}
                 ]
               )

      assert [auth | _] = CaptureSecurity.authorize_calls()
      assert Keyword.get(auth.opts, :session_token) == @distinctive_token

      assert [dispatch] = CaptureTaskStore.dispatches()
      refute Keyword.has_key?(dispatch.opts, :session_token)
      refute Keyword.has_key?(dispatch.opts, "session_token")
    end

    test "security regression: absent proof uses verify_identity false without token key" do
      {caller, target} = unique_ids()

      assert {:ok, _task_id} =
               Arbor.Agent.Orchestration.dispatch(target, sample_task(),
                 caller_id: caller,
                 security_module: CaptureSecurity,
                 task_store: CaptureTaskStore
               )

      assert [auth | _] = CaptureSecurity.authorize_calls()
      assert auth.opts == [verify_identity: false]
      refute Keyword.has_key?(auth.opts, :session_token)
    end
  end

  describe "security regression: public DispatchFacade closed surface" do
    test "security regression: public path validates ids/task/opts before dispatch fun" do
      {caller, target} = unique_ids()
      parent = self()

      dispatch_fun = fn agent_id, task, opts ->
        send(parent, {:dispatched, agent_id, task, opts})
        {:ok, "task_ok_1"}
      end

      assert {:ok, "task_ok_1"} =
               DispatchFacade.dispatch(caller, target, sample_task(), [], dispatch_fun)

      assert_receive {:dispatched, ^target, task, opts}
      assert task == sample_task()
      assert opts == [caller_id: caller]
      refute Keyword.has_key?(opts, :session_token)

      assert {:ok, "task_ok_1"} =
               DispatchFacade.dispatch(
                 caller,
                 target,
                 sample_task(),
                 [session_token: @distinctive_token],
                 dispatch_fun
               )

      assert_receive {:dispatched, ^target, _task, opts2}
      assert Keyword.get(opts2, :session_token) == @distinctive_token
      assert Keyword.get(opts2, :caller_id) == caller

      assert {:error, :invalid_opts} =
               DispatchFacade.dispatch(caller, target, sample_task(), [session_token: nil], fn _, _, _ ->
                 flunk("must not dispatch")
               end)

      assert {:error, :invalid_opts} =
               DispatchFacade.dispatch(
                 caller,
                 target,
                 sample_task(),
                 [session_token: "", unknown: true],
                 fn _, _, _ -> flunk("must not dispatch") end
               )

      assert {:error, :invalid_caller_id} =
               DispatchFacade.dispatch("not_a_principal", target, sample_task(), [], fn _, _, _ ->
                 flunk("must not dispatch")
               end)

      assert {:error, :invalid_task} =
               DispatchFacade.dispatch(caller, target, "string-task", [], fn _, _, _ ->
                 flunk("must not dispatch")
               end)

      assert {:error, :invalid_task} =
               DispatchFacade.dispatch(
                 caller,
                 target,
                 %{__struct__: FakeStruct, x: 1},
                 [],
                 fn _, _, _ -> flunk("must not dispatch") end
               )

      assert {:error, :unauthorized} =
               DispatchFacade.dispatch(caller, target, sample_task(), [], fn _, _, _ ->
                 {:error, {:unauthorized, :agent_dispatch_required}}
               end)

      assert {:error, :dispatch_failed} =
               DispatchFacade.dispatch(caller, target, sample_task(), [], fn _, _, _ ->
                 {:error, :boom}
               end)

      refute_receive {:dispatched, _, _, _}, 20
    end

    test "security regression: Arbor.Agent.dispatch_task/4 is exported" do
      exports = Arbor.Agent.module_info(:exports)
      assert {:dispatch_task, 3} in exports or {:dispatch_task, 4} in exports
      assert {:dispatch_task, 4} in exports
    end

    test "security regression: public Arbor.Agent.dispatch_task wires fixed Orchestration collaborator" do
      # Without a grant (or with an unusable proof), the closed facade denies
      # before returning any credential material.
      {caller, target} = unique_ids()

      assert {:error, reason} =
               Arbor.Agent.dispatch_task(caller, target, sample_task(),
                 session_token: @distinctive_token
               )

      assert reason in [:unauthorized, :dispatch_failed]
      refute inspect({:error, reason}) =~ @distinctive_token
    end
  end
end
