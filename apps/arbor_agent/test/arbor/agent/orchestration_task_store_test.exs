defmodule Arbor.Agent.OrchestrationTaskStoreTest do
  # async: false because kind-routing cases mutate shared Application env.
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Agent.Orchestration.TaskStore
  alias Arbor.Contracts.Coding.TaskOutcome

  defmodule ControlledRunner do
    def run(agent_id, task, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:runner_started, self(), agent_id, task, opts})

      receive do
        {:finish, result} -> result
      after
        1_000 -> {:error, :test_timeout}
      end
    end
  end

  defmodule PendingRunner do
    def run(_agent_id, _task, _opts) do
      {:ok, :pending_approval, "approval_1"}
    end
  end

  defmodule PendingErrorRunner do
    def run(_agent_id, _task, _opts) do
      {:error, {:pending_approval, "approval_err_1"}}
    end
  end

  defmodule CrashRunner do
    def run(agent_id, task, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:runner_started, self(), agent_id, task, opts})

      receive do
        :crash -> exit(:abnormal_crash)
      after
        1_000 -> exit(:test_timeout)
      end
    end
  end

  defmodule LifecycleCleanupProbe do
    def cleanup(task_id, opts) do
      # Notify via Application env — descriptors are closed scalars (no PIDs).
      if pid = Application.get_env(:arbor_agent, :task_store_test_pid) do
        send(pid, {:lifecycle_cleanup, task_id, opts})
      end

      case Application.get_env(:arbor_agent, :lifecycle_cleanup_behavior, :ok) do
        :ok ->
          :ok

        :raise ->
          raise "lifecycle cleanup boom"

        :block ->
          # Releasable block so tests can prove terminal results are not delayed
          # without stalling teardown on Process.sleep.
          if pid = Application.get_env(:arbor_agent, :task_store_test_pid) do
            send(pid, {:lifecycle_cleanup_blocked, task_id, self()})
          end

          receive do
            :release_cleanup -> :ok
          after
            30_000 -> :ok
          end
      end
    end
  end

  defmodule EvilCleanup do
    def cleanup(task_id, opts) do
      if pid = Application.get_env(:arbor_agent, :task_store_test_pid) do
        send(pid, {:evil_cleanup, task_id, opts})
      end

      :ok
    end
  end

  defmodule EvilConsensus do
    def list_pending, do: []

    def cancel(id) do
      if pid = Application.get_env(:arbor_agent, :task_store_test_pid) do
        send(pid, {:evil_consensus_cancel, id})
      end

      :ok
    end
  end

  defmodule EvilAudit do
    def record_approval_answered(caller_id, approval_id, source, decision, data) do
      if pid = Application.get_env(:arbor_agent, :task_store_test_pid) do
        send(pid, {:evil_audit, caller_id, approval_id, source, decision, data})
      end

      :ok
    end
  end

  defmodule CodingChangeExecutor do
    def run(agent_id, task, context) do
      test_pid = recording_pid()
      send(test_pid, {:configured_executor, self(), agent_id, task, context})

      receive do
        {:finish, result} -> result
      after
        1_000 -> {:error, :test_timeout}
      end
    end

    def task_status(agent_id, context) do
      test_pid = recording_pid()
      send(test_pid, {:task_status_called, agent_id, context, self()})

      case Application.get_env(:arbor_agent, :task_store_test_progress) do
        progress when is_map(progress) ->
          {:ok, progress}

        {:error, reason} ->
          {:error, reason}

        :raise ->
          raise "task_status boom"

        :exit ->
          exit(:task_status_exit)

        :hang ->
          receive do
          after
            30_000 -> {:ok, %{}}
          end

        _ ->
          {:ok, %{}}
      end
    end

    def cancel_task(agent_id, context) do
      test_pid = recording_pid()
      send(test_pid, {:cancel_task_called, agent_id, context, self()})

      case Application.get_env(:arbor_agent, :task_store_test_cancel) do
        :error ->
          {:error, :cancel_failed}

        :raise ->
          raise "cancel_task boom"

        :exit ->
          exit(:cancel_task_exit)

        :hang ->
          receive do
          after
            30_000 -> :ok
          end

        _ ->
          :ok
      end
    end

    defp recording_pid do
      Application.fetch_env!(:arbor_agent, :task_store_test_pid)
    end
  end

  # Map-context recording executor for the configured default path (JSON-clean).
  defmodule DefaultRecordingExecutor do
    def run(agent_id, task, context) do
      send(recording_pid(), {:default_executor, self(), agent_id, task, context})

      receive do
        {:finish, result} -> result
      after
        1_000 -> {:error, :test_timeout}
      end
    end

    defp recording_pid do
      Application.fetch_env!(:arbor_agent, :task_store_test_pid)
    end
  end

  defmodule StatusOnlyExecutor do
    def run(agent_id, task, context) do
      send(recording_pid(), {:configured_executor, self(), agent_id, task, context})

      receive do
        {:finish, result} -> result
      after
        1_000 -> {:error, :test_timeout}
      end
    end

    def task_status(_agent_id, _context) do
      {:ok, %{"current_step" => "reviewing", "waiting_on" => "human"}}
    end

    defp recording_pid do
      Application.fetch_env!(:arbor_agent, :task_store_test_pid)
    end
  end

  defmodule RunOnlyExecutor do
    def run(agent_id, task, context) do
      send(recording_pid(), {:configured_executor, self(), agent_id, task, context})

      receive do
        {:finish, result} -> result
      after
        1_000 -> {:error, :test_timeout}
      end
    end

    defp recording_pid do
      Application.fetch_env!(:arbor_agent, :task_store_test_pid)
    end
  end

  defmodule SteeringExecutor do
    def run(agent_id, task, context) do
      send(recording_pid(), {:steering_executor_started, self(), agent_id, task, context})

      receive do
        {:finish, result} -> result
      after
        1_000 -> {:error, :test_timeout}
      end
    end

    def steer_task(agent_id, control, context) do
      call_count = steer_call_count(control["control_id"])

      send(
        recording_pid(),
        {:steer_task_called, agent_id, control, context, self()}
      )

      case Application.get_env(:arbor_agent, :task_store_test_steer, :deliver) do
        :deliver ->
          {:ok, :native_tool_loop}

        :queued ->
          {:ok, :queued, :next_stage}

        :unsupported ->
          {:error, :unsupported}

        :defer ->
          {:error, :transport_down}

        {:defer_until, ready_at_ms} ->
          if System.monotonic_time(:millisecond) >= ready_at_ms do
            {:ok, :native_tool_loop}
          else
            {:error, :transport_down}
          end

        :not_delivered ->
          {:error, :not_delivered}

        :delivery_unknown ->
          {:error, :delivery_unknown}

        :cancelled ->
          {:error, :cancelled}

        {:steer_fn, fun} when is_function(fun, 2) ->
          fun.(control, call_count)

        {:steer_fn, fun} when is_function(fun, 1) ->
          fun.(call_count)
      end
    end

    defp steer_call_count(control_id) do
      try do
        :ets.update_counter(:steer_call_counter, control_id, {2, 1}, {control_id, 0})
      catch
        :error, :badarg -> 0
      end
    end

    defp recording_pid do
      Application.fetch_env!(:arbor_agent, :task_store_test_pid)
    end
  end

  defmodule FinalizingExecutor do
    def run(agent_id, task, context) do
      send(recording_pid(), {:finalizing_executor_started, self(), agent_id, task, context})

      receive do
        {:finish, result} -> result
      after
        1_000 -> {:error, :test_timeout}
      end
    end

    def steer_task(agent_id, control, context) do
      send(recording_pid(), {:finalizing_steer_called, agent_id, control, context, self()})
      {:ok, :queued, :next_stage}
    end

    def finalize_task(agent_id, result, controls, context) do
      send(recording_pid(), {:finalize_task_called, agent_id, result, controls, context, self()})

      case Application.get_env(:arbor_agent, :task_store_test_finalize, :success) do
        :success ->
          {:ok, Map.put(result, "finalized", true)}

        {:error, reason} ->
          {:error, reason}

        :raise ->
          raise "finalize_task boom"

        :exit ->
          exit(:finalize_task_exit)

        :hang ->
          receive do
          after
            30_000 -> {:error, :late_finalization}
          end

        :invalid ->
          :ok

        :non_json ->
          {:ok, Map.put(result, "owner", self())}
      end
    end

    def adopt_task(agent_id, result, request, context) do
      send(recording_pid(), {:adopt_task_called, agent_id, result, request, context, self()})

      case Application.get_env(:arbor_agent, :task_store_test_adopt, :success) do
        :success ->
          {:ok, Map.put(result, "adopted", request["destination_ref"])}

        {:error, reason} ->
          {:error, reason}

        :raise ->
          raise "adopt_task boom"

        :exit ->
          exit(:adopt_task_exit)

        :hang ->
          receive do
          after
            30_000 -> {:error, :late_adoption}
          end

        :invalid ->
          :ok

        :non_json ->
          {:ok, Map.put(result, "owner", self())}
      end
    end

    defp recording_pid do
      Application.fetch_env!(:arbor_agent, :task_store_test_pid)
    end
  end

  defmodule AllTerminalExecutor do
    def run(agent_id, task, context) do
      send(recording_pid(), {:all_terminal_executor_started, self(), agent_id, task, context})

      receive do
        {:finish, result} -> result
        {:crash, reason} -> exit(reason)
      after
        1_000 -> {:error, :test_timeout}
      end
    end

    def finalize_terminal_task(agent_id, envelope, controls, context) do
      send(
        recording_pid(),
        {:finalize_terminal_task_called, agent_id, envelope, controls, context, self()}
      )

      case Application.get_env(:arbor_agent, :task_store_test_terminal_finalize, :success) do
        :success ->
          :ok

        {:error, reason} ->
          {:error, reason}

        :raise ->
          raise "finalize_terminal_task boom"

        :exit ->
          exit(:finalize_terminal_task_exit)

        :hang ->
          receive do
          after
            30_000 -> :ok
          end

        :invalid ->
          {:ok, envelope}
      end
    end

    defp recording_pid do
      Application.fetch_env!(:arbor_agent, :task_store_test_pid)
    end
  end

  defmodule DualFinalizingExecutor do
    def run(agent_id, task, context) do
      send(recording_pid(), {:dual_executor_started, self(), agent_id, task, context})

      receive do
        {:finish, result} -> result
      after
        1_000 -> {:error, :test_timeout}
      end
    end

    def finalize_task(agent_id, result, controls, context) do
      send(recording_pid(), {:dual_finalize_task_called, agent_id, result, controls, context})

      case Application.get_env(:arbor_agent, :task_store_test_finalize, :success) do
        :success ->
          task_id = context["task_id"]

          descriptor = %{
            "path" => "/tmp/#{task_id}-evidence.json",
            "sha256" => String.duplicate("a", 64),
            "byte_size" => 128,
            "schema_version" => 1,
            "task_id" => task_id
          }

          artifacts =
            result
            |> Map.get("artifacts", %{})
            |> Map.put("task_evidence", descriptor)

          {:ok, result |> Map.put("artifacts", artifacts) |> Map.put("finalized", true)}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def finalize_terminal_task(agent_id, envelope, controls, context) do
      send(
        recording_pid(),
        {:dual_finalize_terminal_called, agent_id, envelope, controls, context}
      )

      case Application.get_env(:arbor_agent, :task_store_test_terminal_finalize, :success) do
        :success -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    def adopt_task(agent_id, result, request, context) do
      send(recording_pid(), {:dual_adopt_called, agent_id, result, request, context})

      case get_in(result, ["artifacts", "task_evidence"]) do
        %{} -> {:ok, Map.put(result, "adopted", request["destination_ref"])}
        _missing -> {:error, :task_evidence_missing}
      end
    end

    defp recording_pid do
      Application.fetch_env!(:arbor_agent, :task_store_test_pid)
    end
  end

  defmodule NoRunModule do
    def other, do: :ok
  end

  setup do
    unique = System.unique_integer([:positive])
    supervisor = Module.concat(__MODULE__, :"TaskSupervisor#{unique}")
    store = Module.concat(__MODULE__, :"Store#{unique}")

    start_supervised!({Task.Supervisor, name: supervisor})

    start_supervised!({
      TaskStore,
      # Internal store-start probe only — never selected via dispatch/descriptor.
      name: store,
      task_supervisor: supervisor,
      runner: ControlledRunner,
      approval_cleanup_mfa: {LifecycleCleanupProbe, :cleanup, 2}
    })

    original_executors = Application.get_env(:arbor_agent, :task_executors)
    original_default = Application.get_env(:arbor_agent, :default_task_executor)
    original_test_pid = Application.get_env(:arbor_agent, :task_store_test_pid)
    original_progress = Application.get_env(:arbor_agent, :task_store_test_progress)
    original_cancel = Application.get_env(:arbor_agent, :task_store_test_cancel)
    original_steer = Application.get_env(:arbor_agent, :task_store_test_steer)
    original_finalize = Application.get_env(:arbor_agent, :task_store_test_finalize)

    original_terminal_finalize =
      Application.get_env(:arbor_agent, :task_store_test_terminal_finalize)

    original_adopt = Application.get_env(:arbor_agent, :task_store_test_adopt)
    original_cleanup_behavior = Application.get_env(:arbor_agent, :lifecycle_cleanup_behavior)

    Application.put_env(:arbor_agent, :task_store_test_pid, self())
    Application.put_env(:arbor_agent, :lifecycle_cleanup_behavior, :ok)

    on_exit(fn ->
      restore_env(:task_executors, original_executors)
      restore_env(:default_task_executor, original_default)
      restore_env(:task_store_test_pid, original_test_pid)
      restore_env(:task_store_test_progress, original_progress)
      restore_env(:task_store_test_cancel, original_cancel)
      restore_env(:task_store_test_steer, original_steer)
      restore_env(:task_store_test_finalize, original_finalize)
      restore_env(:task_store_test_terminal_finalize, original_terminal_finalize)
      restore_env(:task_store_test_adopt, original_adopt)
      restore_env(:lifecycle_cleanup_behavior, original_cleanup_behavior)
    end)

    {:ok, store: store, supervisor: supervisor}
  end

  test "architecture regression: cleanup defaults to the Arbor.Comms facade", %{store: store} do
    state = :sys.get_state(store)

    assert state.approval_cleanup_interaction_router == Module.concat([:Arbor, :Comms])

    refute state.approval_cleanup_interaction_router ==
             Module.concat([:Arbor, :Comms, :InteractionRouter])
  end

  test "dispatch returns before the runner completes, then stores the structured result", %{
    store: store
  } do
    assert {:ok, task_id} =
             TaskStore.dispatch("agent_1", "do work",
               name: store,
               test_pid: self(),
               metadata: %{ticket: "A-1"},
               approval_answer_cap_id: "cap_task_1",
               approval_answer_revoke: revoke_to(self()),
               steer_cap_id: "cap_task_steer_1",
               steer_capability_revoke: revoke_steer_to(self()),
               adoption_cap_id: "cap_task_adopt_1",
               adoption_capability_revoke: revoke_adoption_to(self())
             )

    assert_receive {:runner_started, runner_pid, "agent_1", "do work", _opts}

    assert {:ok, status} = TaskStore.status(task_id, name: store)
    assert status.state == :running
    assert status.current_step == "running"
    assert status.metadata == %{ticket: "A-1"}
    refute Map.has_key?(status, :outcome)

    assert {:error, :not_ready} = TaskStore.result(task_id, name: store)

    send(
      runner_pid,
      {:finish, {:ok, %{result_type: :test, payload: %{ok: true}, raw: "done"}}}
    )

    assert_eventually(fn ->
      assert {:ok, status} = TaskStore.status(task_id, name: store)
      assert status.state == :done
      assert status.current_step == "done"

      assert {:ok, result} = TaskStore.result(task_id, name: store)
      assert result.result_type == :test
      assert result.payload.ok == true
      refute Map.has_key?(status, :outcome)
    end)

    assert_receive {:revoke_approval_answer_capability, "cap_task_1"}
    assert_receive {:revoke_steer_capability, "cap_task_steer_1"}
    assert_receive {:revoke_adoption_capability, "cap_task_adopt_1"}
  end

  test "done status projects the exact outcome from the normalized coding result", %{store: store} do
    outcome = task_outcome()

    assert {:ok, task_id} =
             TaskStore.dispatch("agent_1", "do coding work",
               name: store,
               test_pid: self()
             )

    assert_receive {:runner_started, runner_pid, "agent_1", "do coding work", _opts}

    raw = %{
      "status" => "change_committed",
      "branch" => "agent/change",
      "worktree_path" => "/tmp/ws",
      "outcome" => outcome
    }

    send(runner_pid, {:finish, {:ok, raw}})

    assert_eventually(fn ->
      assert {:ok, status} = TaskStore.status(task_id, name: store)
      assert status.state == :done
      assert status.outcome === outcome

      assert {:ok, result} = TaskStore.result(task_id, name: store)
      assert result.payload.outcome === outcome
      assert result.payload.report.outcome === outcome
      assert result.raw === raw
    end)
  end

  test "failed pipeline error status extracts outcome without changing the error tuple", %{
    store: store
  } do
    outcome = task_outcome()
    detail = %{"status" => "pipeline_error", "error" => "worker_failed", "outcome" => outcome}

    assert {:ok, task_id} =
             TaskStore.dispatch("agent_1", "do coding work",
               name: store,
               test_pid: self()
             )

    assert_receive {:runner_started, runner_pid, "agent_1", "do coding work", _opts}
    send(runner_pid, {:finish, {:error, {:pipeline_error, detail}}})

    assert_eventually(fn ->
      assert {:ok, status} = TaskStore.status(task_id, name: store)
      assert status.state == :failed
      assert status.outcome === outcome

      assert {:error, {:failed, {:pipeline_error, ^detail}}} =
               TaskStore.result(task_id, name: store)
    end)
  end

  test "steering mailbox preserves order and delivers configured controls once", %{
    supervisor: supervisor
  } do
    store = start_configured_steering_store(supervisor)
    Application.put_env(:arbor_agent, :task_store_test_steer, :deliver)

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", %{"task_id" => ^task_id}}

    assert {:ok, first} =
             TaskStore.steer(task_id, "check tests", name: store, sender_id: "human_1")

    assert {:ok, second} =
             TaskStore.steer(task_id, "also review docs", name: store, sender_id: "human_1")

    assert first["sequence"] == 1
    assert second["sequence"] == 2
    assert first["status"] == "delivered"
    assert second["status"] == "delivered"
    assert first["delivery_mode"] == "native_tool_loop"

    assert_receive {:steer_task_called, "agent_1", delivered_first, %{"task_id" => ^task_id}, _}
    assert_receive {:steer_task_called, "agent_1", delivered_second, %{"task_id" => ^task_id}, _}
    assert delivered_first["control_id"] == first["control_id"]
    assert delivered_second["control_id"] == second["control_id"]
  end

  test "accepted queued controls are not retried", %{supervisor: supervisor} do
    store = start_configured_steering_store(supervisor, steer_retry_delay_ms: 10)
    Application.put_env(:arbor_agent, :task_store_test_steer, :queued)

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", _}

    assert {:ok, control} = TaskStore.steer(task_id, "queue this", name: store)
    assert control["status"] == "queued"
    assert control["delivery_mode"] == "next_stage"
    assert_receive {:steer_task_called, "agent_1", delivered, _, _}
    assert delivered["control_id"] == control["control_id"]
    refute_receive {:steer_task_called, _, _, _, _}, 50
  end

  test "successful completion reconciles accepted queued controls exactly once", %{
    supervisor: supervisor
  } do
    store = start_configured_steering_store(supervisor, steer_retry_delay_ms: 10)
    Application.put_env(:arbor_agent, :task_store_test_steer, :queued)

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, runner_pid, "agent_1", "work", _}

    task_ref = :sys.get_state(store).tasks[task_id].ref
    result = {:ok, %{result_type: :test, payload: %{ok: true}, raw: "done"}}

    assert {:ok, control} = TaskStore.steer(task_id, "queue this", name: store)
    assert control["status"] == "queued"
    assert control["delivered_at"] == nil
    assert_receive {:steer_task_called, "agent_1", delivered, _, _}
    assert delivered["control_id"] == control["control_id"]

    subscribe_to_task_steering_transitions(task_id)
    send(runner_pid, {:finish, result})

    status =
      assert_eventually(fn ->
        assert {:ok, status} = TaskStore.status(task_id, name: store)
        assert status.state == :done
        status
      end)

    completed_at = DateTime.to_iso8601(status.completed_at)
    assert status.steering["counts"] == %{"delivery_unconfirmed" => 1}
    assert status.steering["last"]["control_id"] == control["control_id"]
    assert status.steering["last"]["status"] == "delivery_unconfirmed"
    assert status.steering["last"]["delivered_at"] == nil

    assert status.steering["last"]["error"] ==
             "delivery_unconfirmed_task_succeeded"

    refute Map.has_key?(status.steering["last"], "message")
    refute Map.has_key?(status.steering["last"], "sender_id")

    assert_receive {:task_steering_transition,
                    %{
                      task_id: ^task_id,
                      control_id: control_id,
                      status: "delivery_unconfirmed",
                      delivered_at: nil,
                      error: "delivery_unconfirmed_task_succeeded"
                    }},
                   1_000

    assert control_id == control["control_id"]
    refute_receive {:steer_task_called, _, _, _, _}, 50

    send(store, {task_ref, result})
    send(store, {:DOWN, task_ref, :process, runner_pid, :late_down})

    assert {:ok, replayed_status} = TaskStore.status(task_id, name: store)
    assert replayed_status.steering["last"]["delivered_at"] == nil

    refute_receive {:task_steering_transition,
                    %{task_id: ^task_id, status: "delivery_unconfirmed"}},
                   100
  end

  test "terminal finalization receives reconciled controls before success is published", %{
    supervisor: supervisor
  } do
    store = start_finalizing_store(supervisor)
    outcome = task_outcome()

    assert {:ok, task_id} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "retain evidence"},
               name: store,
               task_id: "task_finalize_success"
             )

    assert_receive {:finalizing_executor_started, runner_pid, "agent_1", _task,
                    %{"task_id" => ^task_id}}

    assert {:ok, control} =
             TaskStore.steer(task_id, "preserve this correction", name: store)

    assert control["status"] == "queued"
    assert_receive {:finalizing_steer_called, "agent_1", queued_control, _, _}
    assert queued_control["control_id"] == control["control_id"]

    send(
      runner_pid,
      {:finish,
       {:ok,
        %{
          "status" => "no_changes",
          "branch" => "test/x",
          "outcome" => outcome
        }}}
    )

    assert_receive {:finalize_task_called, "agent_1", original_result, [final_control], context,
                    _callback_pid},
                   1_000

    assert original_result == %{
             "status" => "no_changes",
             "branch" => "test/x",
             "outcome" => outcome
           }

    assert context == %{"task_id" => task_id}
    assert final_control["control_id"] == control["control_id"]
    assert final_control["status"] == "delivery_unconfirmed"
    assert final_control["delivered_at"] == nil

    assert final_control["error"] == "delivery_unconfirmed_task_succeeded"

    assert final_control["message"] == "preserve this correction"

    assert_eventually(fn ->
      assert {:ok, status} = TaskStore.status(task_id, name: store)
      assert status.state == :done
      assert status.steering["counts"] == %{"delivery_unconfirmed" => 1}

      assert {:ok, result} = TaskStore.result(task_id, name: store)
      assert result.result_type == :coding_change
      assert result.raw["finalized"] == true
      assert result.raw["outcome"] === outcome
      assert result.payload.outcome === outcome
    end)
  end

  test "adoption receives the finalized raw result and revokes only its retained capability", %{
    supervisor: supervisor
  } do
    store = start_finalizing_store(supervisor)
    outcome = task_outcome()

    assert {:ok, task_id} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "adopt change"},
               name: store,
               task_id: "task_adopt_success",
               adoption_cap_id: "cap_adoption",
               adoption_capability_revoke: revoke_adoption_to(self())
             )

    assert_receive {:finalizing_executor_started, runner_pid, "agent_1", _task, _context}

    send(
      runner_pid,
      {:finish,
       {:ok,
        %{
          "status" => "no_changes",
          "branch" => "test/x",
          "outcome" => outcome
        }}}
    )

    assert_eventually(fn -> assert {:ok, _} = TaskStore.result(task_id, name: store) end)
    refute_receive {:revoke_adoption_capability, "cap_adoption"}

    assert {:ok, adopted_result} = TaskStore.adopt(task_id, " refs/heads/reviewed ", name: store)
    assert adopted_result.raw["finalized"] == true
    assert adopted_result.raw["adopted"] == "refs/heads/reviewed"
    assert adopted_result.raw["outcome"] === outcome
    assert adopted_result.payload.outcome === outcome

    assert_receive {:adopt_task_called, "agent_1", raw_result,
                    %{"destination_ref" => "refs/heads/reviewed"}, %{"task_id" => ^task_id},
                    _callback_pid}

    assert raw_result["finalized"] == true
    assert_receive {:revoke_adoption_capability, "cap_adoption"}
    assert :sys.get_state(store).tasks[task_id].adoption_cap_id == nil
  end

  test "adoption callback errors preserve the prior result for retry", %{supervisor: supervisor} do
    Application.put_env(:arbor_agent, :task_store_test_adopt, {:error, :destination_busy})
    store = start_finalizing_store(supervisor, executor_finalization_timeout_ms: 40)

    assert {:ok, task_id} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "retry adoption"},
               name: store,
               task_id: "task_adopt_retry",
               adoption_cap_id: "cap_adoption_retry",
               adoption_capability_revoke: revoke_adoption_to(self())
             )

    assert_receive {:finalizing_executor_started, runner_pid, "agent_1", _task, _context}
    send(runner_pid, {:finish, {:ok, %{"status" => "no_changes"}}})
    assert_eventually(fn -> assert {:ok, _} = TaskStore.result(task_id, name: store) end)

    assert {:error, {:task_adoption_failed, ":destination_busy"}} =
             TaskStore.adopt(task_id, "refs/heads/reviewed", name: store)

    assert {:ok, prior_result} = TaskStore.result(task_id, name: store)
    assert prior_result.raw["finalized"] == true
    assert :sys.get_state(store).tasks[task_id].adoption_cap_id == "cap_adoption_retry"
    refute_receive {:revoke_adoption_capability, _}
  end

  test "pruning a terminal adoptable task revokes its retained capability", %{
    supervisor: supervisor
  } do
    store = start_finalizing_store(supervisor, max_tasks: 1)

    assert {:ok, first_task_id} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "retain adoption authority"},
               name: store,
               task_id: "task_adoption_prune_first",
               adoption_cap_id: "cap_adoption_prune",
               adoption_capability_revoke: revoke_adoption_to(self())
             )

    assert_receive {:finalizing_executor_started, first_runner, "agent_1", _task, _context}
    send(first_runner, {:finish, {:ok, %{"status" => "no_changes"}}})
    assert_eventually(fn -> assert {:ok, _} = TaskStore.result(first_task_id, name: store) end)
    refute_receive {:revoke_adoption_capability, "cap_adoption_prune"}

    assert {:ok, _second_task_id} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "trigger pruning"},
               name: store,
               task_id: "task_adoption_prune_second"
             )

    assert_receive {:revoke_adoption_capability, "cap_adoption_prune"}
    assert {:error, :not_found} = TaskStore.status(first_task_id, name: store)
  end

  test "opted-in terminal finalization failures and timeouts fail the outer task", %{
    supervisor: supervisor
  } do
    cases = [
      {{:error, :disk_full}, ":disk_full"},
      {:raise, ":executor_callback_exception"},
      {:exit, ":executor_callback_exit"},
      {:invalid, ":invalid_finalization_result"},
      {:non_json, ":non_json_finalization_result"},
      {:hang, ":executor_callback_timeout"}
    ]

    for {mode, expected_reason} <- cases do
      Application.put_env(:arbor_agent, :task_store_test_finalize, mode)

      store =
        start_finalizing_store(supervisor,
          executor_finalization_timeout_ms: 40
        )

      task_id = "task_finalize_#{System.unique_integer([:positive])}"
      adoption_cap_id = "cap_adoption_#{task_id}"

      assert {:ok, ^task_id} =
               TaskStore.dispatch(
                 "agent_1",
                 %{"kind" => "coding_change", "input" => "fail finalization"},
                 name: store,
                 task_id: task_id,
                 adoption_cap_id: adoption_cap_id,
                 adoption_capability_revoke: revoke_adoption_to(self())
               )

      assert_receive {:finalizing_executor_started, runner_pid, "agent_1", _task, _context}
      send(runner_pid, {:finish, {:ok, %{"status" => "no_changes", "branch" => "test/x"}}})

      assert_eventually(fn ->
        assert {:ok, status} = TaskStore.status(task_id, name: store)
        assert status.state == :failed

        assert {:error, {:failed, {:task_finalization_failed, ^expected_reason}}} =
                 TaskStore.result(task_id, name: store)
      end)

      assert_receive {:revoke_adoption_capability, ^adoption_cap_id}
    end
  end

  test "terminal finalization is not called for executor failure or explicit runner overrides", %{
    supervisor: supervisor
  } do
    store = start_finalizing_store(supervisor)

    assert {:ok, failed_task_id} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "runner fails"},
               name: store
             )

    assert_receive {:finalizing_executor_started, failed_runner, "agent_1", _task, _context}
    send(failed_runner, {:finish, {:error, :runner_failed}})

    assert_eventually(fn ->
      assert {:error, {:failed, :runner_failed}} =
               TaskStore.result(failed_task_id, name: store)
    end)

    refute_receive {:finalize_task_called, _, _, _, _, _}, 50

    override_store =
      Module.concat(__MODULE__, :"FinalizerOverride#{System.unique_integer([:positive])}")

    start_supervised!(
      {TaskStore, name: override_store, task_supervisor: supervisor},
      id: override_store
    )

    assert {:ok, override_task_id} =
             TaskStore.dispatch("agent_1", "override",
               name: override_store,
               runner: FinalizingExecutor,
               task_id: "task_finalize_override"
             )

    assert_receive {:finalizing_executor_started, override_runner, "agent_1", "override", _opts}
    send(override_runner, {:finish, {:ok, %{"content" => "done"}}})

    assert_eventually(fn ->
      assert {:ok, _result} = TaskStore.result(override_task_id, name: override_store)
    end)

    refute_receive {:finalize_task_called, _, _, _, _, _}, 50
  end

  test "all-terminal success preserves the canonical outcome and legacy done result", %{
    supervisor: supervisor
  } do
    store = start_all_terminal_store(supervisor)
    outcome = registered_outcome("no_changes")

    assert {:ok, task_id} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "complete normally"},
               name: store,
               task_id: "task_all_terminal_success"
             )

    assert_receive {:all_terminal_executor_started, runner_pid, "agent_1", _task, context}

    result = %{
      "status" => "no_changes",
      "branch" => "test/success",
      "outcome" => outcome,
      "evidence" => %{"summary" => "done"}
    }

    send(runner_pid, {:finish, {:ok, result}})

    assert_receive {:finalize_terminal_task_called, "agent_1", envelope, [], ^context,
                    _callback_pid}

    assert envelope["terminal_state"] == "done"
    assert envelope["outcome"] == outcome
    assert envelope["evidence"]["kind"] == "executor_result"
    assert envelope["evidence"]["result"] == result

    assert_eventually(fn ->
      assert {:ok, status} = TaskStore.status(task_id, name: store)
      assert status.state == :done
      assert status.outcome == outcome

      assert {:ok, completed} = TaskStore.result(task_id, name: store)
      assert completed.result_type == :coding_change
      assert completed.payload.outcome == outcome
      assert completed.raw == result
    end)

    refute_receive {:finalize_terminal_task_called, "agent_1", _, _, _, _}, 100
  end

  test "all-terminal pipeline failure preserves its canonical outcome in result and status", %{
    supervisor: supervisor
  } do
    store = start_all_terminal_store(supervisor)
    outcome = registered_outcome("worker_turn_no_progress")

    assert {:ok, task_id} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "pipeline failure"},
               name: store
             )

    assert_receive {:all_terminal_executor_started, runner_pid, "agent_1", _task, _context}

    detail = %{
      "status" => "pipeline_error",
      "error" => "worker_turn_no_progress",
      "outcome" => outcome
    }

    send(runner_pid, {:finish, {:error, {:pipeline_error, detail}}})

    assert_receive {:finalize_terminal_task_called, "agent_1", callback_envelope, [], _, _}
    assert callback_envelope["outcome"] == outcome
    assert callback_envelope["evidence"]["kind"] == "pipeline_failure"

    assert_eventually(fn ->
      assert {:ok, envelope} = TaskStore.result(task_id, name: store)
      assert envelope == callback_envelope

      assert {:ok, status} = TaskStore.status(task_id, name: store)
      assert status.state == :failed
      assert status.outcome == envelope["outcome"]
    end)
  end

  test "lifecycle regression: all-terminal cancellation publishes task_cancelled", %{
    supervisor: supervisor
  } do
    store = start_all_terminal_store(supervisor)

    assert {:ok, task_id} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "cancel"},
               name: store
             )

    assert_receive {:all_terminal_executor_started, runner_pid, "agent_1", _task, context}
    runner_ref = Process.monitor(runner_pid)

    assert {:ok, cancelled} = TaskStore.cancel(task_id, name: store)
    assert cancelled.state == :cancelled
    assert cancelled.outcome["code"] == "task_cancelled"

    assert_receive {:finalize_terminal_task_called, "agent_1", envelope, [], ^context, _}
    assert envelope["terminal_state"] == "cancelled"
    assert envelope["evidence"] == %{"kind" => "task_cancelled"}
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, :killed}

    assert {:ok, ^envelope} = TaskStore.result(task_id, name: store)
    assert {:ok, %{outcome: outcome}} = TaskStore.status(task_id, name: store)
    assert outcome == envelope["outcome"]
  end

  test "lifecycle regression: abnormal owner DOWN is canonical and drops raw reason", %{
    supervisor: supervisor
  } do
    store = start_all_terminal_store(supervisor)

    assert {:ok, task_id} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "crash"},
               name: store
             )

    assert_receive {:all_terminal_executor_started, runner_pid, "agent_1", _task, _context}
    raw_reason = {:secret_owner_reason, self(), AllTerminalExecutor}
    send(runner_pid, {:crash, raw_reason})

    assert_receive {:finalize_terminal_task_called, "agent_1", envelope, [], _, _}
    assert envelope["outcome"]["code"] == "task_owner_died"
    assert envelope["evidence"] == %{"kind" => "task_owner_died"}
    refute Jason.encode!(envelope) =~ "secret_owner_reason"
    refute Jason.encode!(envelope) =~ inspect(self())

    assert_eventually(fn ->
      assert {:ok, ^envelope} = TaskStore.result(task_id, name: store)
      assert {:ok, %{state: :failed, outcome: outcome}} = TaskStore.status(task_id, name: store)
      assert outcome == envelope["outcome"]
    end)
  end

  test "ownerless approval and generic runner errors receive distinct canonical outcomes", %{
    supervisor: supervisor
  } do
    store = start_all_terminal_store(supervisor)

    cases = [
      {{:ok, :pending_approval, "approval_terminal_1"}, "approval_owner_terminated"},
      {{:error, {:raw_runner_error, self(), AllTerminalExecutor}}, "task_runner_failed"}
    ]

    for {runner_result, expected_code} <- cases do
      task_id = "task_terminal_#{expected_code}"

      assert {:ok, ^task_id} =
               TaskStore.dispatch(
                 "agent_1",
                 %{"kind" => "coding_change", "input" => expected_code},
                 name: store,
                 task_id: task_id
               )

      assert_receive {:all_terminal_executor_started, runner_pid, "agent_1", _task, _context}
      send(runner_pid, {:finish, runner_result})

      assert_receive {:finalize_terminal_task_called, "agent_1", envelope, [], _, _}
      assert envelope["outcome"]["code"] == expected_code

      if expected_code == "approval_owner_terminated" do
        assert envelope["evidence"]["approval_id"] == "approval_terminal_1"
      else
        encoded = Jason.encode!(envelope)
        refute encoded =~ "raw_runner_error"
        refute encoded =~ inspect(self())
      end

      assert_eventually(fn ->
        assert {:ok, ^envelope} = TaskStore.result(task_id, name: store)
        assert {:ok, %{outcome: outcome}} = TaskStore.status(task_id, name: store)
        assert outcome == envelope["outcome"]
      end)
    end
  end

  test "lifecycle regression: missing and forged outcomes publish a failed terminal envelope", %{
    supervisor: supervisor
  } do
    store = start_all_terminal_store(supervisor)

    forged = registered_outcome("no_changes") |> Map.put("disposition", "failed")

    for {suffix, result} <- [
          {"missing", %{"status" => "no_changes", "branch" => "test/missing"}},
          {"forged", %{"status" => "no_changes", "branch" => "test/forged", "outcome" => forged}}
        ] do
      task_id = "task_invalid_terminal_#{suffix}"

      assert {:ok, ^task_id} =
               TaskStore.dispatch(
                 "agent_1",
                 %{"kind" => "coding_change", "input" => suffix},
                 name: store,
                 task_id: task_id
               )

      assert_receive {:all_terminal_executor_started, runner_pid, "agent_1", _task, _context}
      send(runner_pid, {:finish, {:ok, result}})

      assert_receive {:finalize_terminal_task_called, "agent_1", envelope, [], _, _}
      assert envelope["outcome"]["code"] == "invalid_terminal_evidence"
      assert envelope["terminal_state"] == "failed"

      assert_eventually(fn ->
        assert {:ok, ^envelope} = TaskStore.result(task_id, name: store)

        assert {:ok, %{state: :failed, outcome: outcome}} =
                 TaskStore.status(task_id, name: store)

        assert outcome == envelope["outcome"]
      end)
    end
  end

  test "dual finalizers retain evidence before constructing and acknowledging success", %{
    supervisor: supervisor
  } do
    store = start_dual_finalizing_store(supervisor)
    task_id = "task_dual_finalize_success"
    outcome = registered_outcome("no_changes")

    assert {:ok, ^task_id} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "retain then acknowledge"},
               name: store,
               task_id: task_id
             )

    assert_receive {:dual_executor_started, runner_pid, "agent_1", _task, context}

    original_result = %{
      "status" => "no_changes",
      "canonical_status" => "no_changes",
      "branch" => "test/dual-finalizer",
      "outcome" => outcome,
      "artifacts" => coding_artifacts()
    }

    send(runner_pid, {:finish, {:ok, original_result}})

    assert_receive {:dual_finalize_task_called, "agent_1", ^original_result, [], ^context}

    assert_receive {:dual_finalize_terminal_called, "agent_1", envelope, [], ^context}
    finalized_result = envelope["evidence"]["result"]
    descriptor = get_in(finalized_result, ["artifacts", "task_evidence"])

    assert envelope["terminal_state"] == "done"
    assert envelope["outcome"] == outcome
    assert finalized_result["finalized"] == true
    assert descriptor["task_id"] == task_id
    assert descriptor["sha256"] == String.duplicate("a", 64)

    assert_eventually(fn ->
      assert {:ok, completed} = TaskStore.result(task_id, name: store)
      assert completed.raw == finalized_result
      assert completed.payload.outcome == outcome
      assert completed.payload.artifacts["task_evidence"] == descriptor

      assert {:ok, %{state: :done, outcome: status_outcome}} =
               TaskStore.status(task_id, name: store)

      assert status_outcome == envelope["outcome"]
    end)

    assert {:ok, adopted} = TaskStore.adopt(task_id, "refs/heads/reviewed", name: store)
    assert adopted.raw["adopted"] == "refs/heads/reviewed"
    assert get_in(adopted.raw, ["artifacts", "task_evidence"]) == descriptor

    assert_receive {:dual_adopt_called, "agent_1", adopt_input,
                    %{"destination_ref" => "refs/heads/reviewed"}, ^context}

    assert get_in(adopt_input, ["artifacts", "task_evidence"]) == descriptor
    refute_receive {:dual_finalize_task_called, _, _, _, _}, 100
    refute_receive {:dual_finalize_terminal_called, _, _, _, _}, 100
  end

  test "dual legacy finalizer failure is acknowledged as task_finalization_failed once", %{
    supervisor: supervisor
  } do
    Application.put_env(:arbor_agent, :task_store_test_finalize, {:error, :archive_failed})
    store = start_dual_finalizing_store(supervisor)
    task_id = "task_dual_finalize_failure"
    outcome = registered_outcome("no_changes")

    assert {:ok, ^task_id} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "archive failure"},
               name: store,
               task_id: task_id
             )

    assert_receive {:dual_executor_started, runner_pid, "agent_1", _task, context}

    original_result = %{
      "status" => "no_changes",
      "canonical_status" => "no_changes",
      "branch" => "test/dual-finalizer-failure",
      "outcome" => outcome,
      "artifacts" => coding_artifacts()
    }

    send(runner_pid, {:finish, {:ok, original_result}})

    assert_receive {:dual_finalize_task_called, "agent_1", ^original_result, [], ^context}
    assert_receive {:dual_finalize_terminal_called, "agent_1", envelope, [], ^context}

    assert envelope["terminal_state"] == "failed"
    assert envelope["outcome"]["code"] == "task_finalization_failed"
    assert envelope["prior_outcome"] == outcome
    assert envelope["evidence"]["result"] == original_result
    refute get_in(envelope, ["evidence", "result", "artifacts", "task_evidence"])

    assert_eventually(fn ->
      assert {:ok, ^envelope} = TaskStore.result(task_id, name: store)

      assert {:ok, %{state: :failed, outcome: status_outcome}} =
               TaskStore.status(task_id, name: store)

      assert status_outcome == envelope["outcome"]
    end)

    refute_receive {:dual_finalize_task_called, _, _, _, _}, 100
    refute_receive {:dual_finalize_terminal_called, _, _, _, _}, 100
  end

  test "all-terminal finalizer failure and timeout retain prior outcome and evidence once", %{
    supervisor: supervisor
  } do
    for mode <- [{:error, {:raw_finalizer_error, self()}}, :hang, :invalid] do
      Application.put_env(:arbor_agent, :task_store_test_terminal_finalize, mode)
      store = start_all_terminal_store(supervisor, executor_finalization_timeout_ms: 40)
      task_id = "task_terminal_finalizer_#{System.unique_integer([:positive])}"
      outcome = registered_outcome("no_changes")

      assert {:ok, ^task_id} =
               TaskStore.dispatch(
                 "agent_1",
                 %{"kind" => "coding_change", "input" => "finalizer failure"},
                 name: store,
                 task_id: task_id
               )

      assert_receive {:all_terminal_executor_started, runner_pid, "agent_1", _task, _context}

      original_result = %{
        "status" => "no_changes",
        "branch" => "test/finalizer",
        "outcome" => outcome,
        "evidence" => %{"retained" => true}
      }

      send(runner_pid, {:finish, {:ok, original_result}})

      assert_receive {:finalize_terminal_task_called, "agent_1", callback_envelope, [], _, _},
                     1_000

      assert_eventually(fn ->
        assert {:ok, envelope} = TaskStore.result(task_id, name: store)
        assert envelope["outcome"]["code"] == "task_finalization_failed"
        assert envelope["prior_outcome"] == outcome
        assert envelope["evidence"] == callback_envelope["evidence"]
        assert envelope["evidence"]["result"] == original_result

        encoded = Jason.encode!(envelope)
        refute encoded =~ "raw_finalizer_error"
        refute encoded =~ inspect(self())

        assert {:ok, %{state: :failed, outcome: status_outcome}} =
                 TaskStore.status(task_id, name: store)

        assert status_outcome == envelope["outcome"]
      end)

      refute_receive {:finalize_terminal_task_called, "agent_1", _, _, _, _}, 100
    end
  end

  test "configured executors without all-terminal opt-in retain historical errors", %{
    supervisor: supervisor
  } do
    Application.put_env(:arbor_agent, :default_task_executor, DefaultRecordingExecutor)
    store = Module.concat(__MODULE__, :GenericCompatibilityStore)
    start_supervised!({TaskStore, name: store, task_supervisor: supervisor}, id: store)

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "generic task", name: store)
    assert_receive {:default_executor, runner_pid, "agent_1", "generic task", _context}
    send(runner_pid, {:finish, {:error, :historical_runner_error}})

    assert_eventually(fn ->
      assert {:error, {:failed, :historical_runner_error}} =
               TaskStore.result(task_id, name: store)

      assert {:ok, status} = TaskStore.status(task_id, name: store)
      refute Map.has_key?(status, :outcome)
    end)

    refute_receive {:finalize_terminal_task_called, _, _, _, _, _}, 50

    assert {:ok, override_task_id} =
             TaskStore.dispatch("agent_1", "explicit override",
               name: store,
               runner: AllTerminalExecutor
             )

    assert_receive {:all_terminal_executor_started, override_pid, "agent_1", "explicit override",
                    override_context}

    assert is_list(override_context)
    send(override_pid, {:finish, {:error, :override_historical_error}})

    assert_eventually(fn ->
      assert {:error, {:failed, :override_historical_error}} =
               TaskStore.result(override_task_id, name: store)
    end)

    refute_receive {:finalize_terminal_task_called, _, _, _, _, _}, 50
  end

  test "failed completion keeps accepted queued controls explicitly unconfirmed", %{
    supervisor: supervisor
  } do
    store = start_configured_steering_store(supervisor)
    Application.put_env(:arbor_agent, :task_store_test_steer, :queued)

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, runner_pid, "agent_1", "work", _}
    assert {:ok, control} = TaskStore.steer(task_id, "queue this", name: store)
    assert control["status"] == "queued"
    assert_receive {:steer_task_called, "agent_1", _, _, _}

    subscribe_to_task_steering_transitions(task_id)
    send(runner_pid, {:finish, {:error, :runner_failed}})

    assert_eventually(fn ->
      assert {:ok, status} = TaskStore.status(task_id, name: store)
      assert status.state == :failed
      assert status.steering["counts"] == %{"delivery_unconfirmed" => 1}
      assert status.steering["last"]["control_id"] == control["control_id"]
      assert status.steering["last"]["status"] == "delivery_unconfirmed"
      assert status.steering["last"]["delivered_at"] == nil

      assert status.steering["last"]["error"] ==
               "delivery_unconfirmed_task_failed"

      refute Map.has_key?(status.steering["last"], "message")
      refute Map.has_key?(status.steering["last"], "sender_id")
    end)

    assert_receive {:task_steering_transition,
                    %{
                      task_id: ^task_id,
                      status: "delivery_unconfirmed",
                      error: "delivery_unconfirmed_task_failed"
                    }},
                   1_000
  end

  test "cancellation keeps accepted queued controls explicitly unconfirmed", %{
    supervisor: supervisor
  } do
    store = start_configured_steering_store(supervisor)
    Application.put_env(:arbor_agent, :task_store_test_steer, :queued)

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _runner_pid, "agent_1", "work", _}
    assert {:ok, control} = TaskStore.steer(task_id, "queue this", name: store)
    assert control["status"] == "queued"
    assert_receive {:steer_task_called, "agent_1", _, _, _}

    subscribe_to_task_steering_transitions(task_id)

    assert {:ok, status} = TaskStore.cancel(task_id, name: store)
    assert status.state == :cancelled
    assert status.steering["counts"] == %{"delivery_unconfirmed" => 1}
    assert status.steering["last"]["control_id"] == control["control_id"]
    assert status.steering["last"]["status"] == "delivery_unconfirmed"
    assert status.steering["last"]["delivered_at"] == nil

    assert status.steering["last"]["error"] ==
             "delivery_unconfirmed_task_cancelled"

    refute Map.has_key?(status.steering["last"], "message")
    refute Map.has_key?(status.steering["last"], "sender_id")

    assert_receive {:task_steering_transition,
                    %{
                      task_id: ^task_id,
                      status: "delivery_unconfirmed",
                      error: "delivery_unconfirmed_task_cancelled"
                    }},
                   1_000
  end

  test "successful task completion keeps accepted queued controls explicitly unconfirmed", %{
    supervisor: supervisor
  } do
    store = start_configured_steering_store(supervisor)
    Application.put_env(:arbor_agent, :task_store_test_steer, :queued)

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, runner_pid, "agent_1", "work", _}
    assert {:ok, control} = TaskStore.steer(task_id, "queue this", name: store)
    assert control["status"] == "queued"
    assert_receive {:steer_task_called, "agent_1", _, _, _}

    subscribe_to_task_steering_transitions(task_id)
    send(runner_pid, {:finish, {:ok, %{}}})

    assert_eventually(fn ->
      assert {:ok, status} = TaskStore.status(task_id, name: store)
      assert status.state == :done
      assert status.steering["counts"] == %{"delivery_unconfirmed" => 1}
      assert status.steering["last"]["control_id"] == control["control_id"]
      assert status.steering["last"]["status"] == "delivery_unconfirmed"
      assert status.steering["last"]["delivered_at"] == nil

      assert status.steering["last"]["error"] ==
               "delivery_unconfirmed_task_succeeded"

      refute Map.has_key?(status.steering["last"], "message")
      refute Map.has_key?(status.steering["last"], "sender_id")
    end)

    assert_receive {:task_steering_transition,
                    %{
                      task_id: ^task_id,
                      status: "delivery_unconfirmed",
                      error: "delivery_unconfirmed_task_succeeded"
                    }},
                   1_000
  end

  test "explicit delivery before successful task completion marks control delivered", %{
    supervisor: supervisor
  } do
    store = start_configured_steering_store(supervisor)
    Application.put_env(:arbor_agent, :task_store_test_steer, :deliver)

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, runner_pid, "agent_1", "work", _}
    assert {:ok, control} = TaskStore.steer(task_id, "deliver this", name: store)
    assert control["status"] == "delivered"
    assert_receive {:steer_task_called, "agent_1", _, _, _}

    send(runner_pid, {:finish, {:ok, %{}}})

    assert_eventually(fn ->
      assert {:ok, status} = TaskStore.status(task_id, name: store)
      assert status.state == :done
      assert status.steering["counts"] == %{"delivered" => 1}
      assert status.steering["last"]["control_id"] == control["control_id"]
      assert status.steering["last"]["status"] == "delivered"
    end)
  end

  test "deferred controls remain retryable past the old retry window and keep the same id", %{
    supervisor: supervisor
  } do
    store =
      start_configured_steering_store(supervisor,
        steer_retry_delay_ms: 100,
        max_steer_retry_delay_ms: 100
      )

    Application.put_env(
      :arbor_agent,
      :task_store_test_steer,
      {:defer_until, System.monotonic_time(:millisecond) + 350}
    )

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", _}
    assert {:ok, control} = TaskStore.steer(task_id, "retry this", name: store)
    assert control["status"] == "deferred"

    assert_receive {:steer_task_called, "agent_1", first, _, _}
    assert_receive {:steer_task_called, "agent_1", second, _, _}, 150
    assert first["control_id"] == control["control_id"]
    assert second["control_id"] == control["control_id"]

    assert_eventually(
      fn ->
        assert {:ok, status} = TaskStore.status(task_id, name: store)
        assert status.steering["counts"] == %{"delivered" => 1}
        assert status.steering["last"]["control_id"] == control["control_id"]
      end,
      60
    )
  end

  test "deferred controls gate later controls until the earliest control is accepted", %{
    supervisor: supervisor
  } do
    store = start_configured_steering_store(supervisor, steer_retry_delay_ms: 30)
    Application.put_env(:arbor_agent, :task_store_test_steer, :defer)

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", _}
    assert {:ok, first} = TaskStore.steer(task_id, "first", name: store)
    assert_receive {:steer_task_called, "agent_1", first_attempt, _, _}
    assert first_attempt["control_id"] == first["control_id"]

    assert {:ok, second} = TaskStore.steer(task_id, "second", name: store)
    assert second["status"] == "queued"
    refute_receive {:steer_task_called, _, _, _, _}, 20

    Application.put_env(:arbor_agent, :task_store_test_steer, :deliver)

    assert_receive {:steer_task_called, "agent_1", delivered_first, _, _}, 100
    assert_receive {:steer_task_called, "agent_1", delivered_second, _, _}, 100
    assert delivered_first["control_id"] == first["control_id"]
    assert delivered_second["control_id"] == second["control_id"]

    assert_eventually(fn ->
      assert {:ok, status} = TaskStore.status(task_id, name: store)
      assert status.steering["counts"] == %{"delivered" => 2}
      assert status.steering["last"]["sequence"] == 2
      refute Map.has_key?(status.steering["last"], "message")
      refute Map.has_key?(status.steering["last"], "sender_id")
    end)
  end

  test "steering controls are bounded and use opaque ids", %{supervisor: supervisor} do
    store = start_configured_steering_store(supervisor, max_controls_per_task: 1)
    Application.put_env(:arbor_agent, :task_store_test_steer, :deliver)

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", _}
    assert {:ok, control} = TaskStore.steer(task_id, "one", name: store)
    assert control["control_id"] =~ ~r/^control_[A-Za-z0-9_-]{24}$/
    assert {:error, :too_many_steering_controls} = TaskStore.steer(task_id, "two", name: store)
  end

  test "steering rejects invalid UTF-8 before string processing", %{store: store} do
    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store, test_pid: self())
    assert_receive {:runner_started, _pid, "agent_1", "work", _}
    assert {:error, :invalid_steering_message} = TaskStore.steer(task_id, <<0xFF>>, name: store)
  end

  test "runner overrides and executors without steering report unsupported", %{store: store} do
    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store, test_pid: self())
    assert_receive {:runner_started, _pid, "agent_1", "work", _}

    assert {:ok, control} = TaskStore.steer(task_id, "redirect", name: store)
    assert control["status"] == "unsupported"
    assert control["error"] == "executor_unsupported"
  end

  test "cancellation terminalizes deferred controls without retrying the runner", %{
    supervisor: supervisor
  } do
    store = start_configured_steering_store(supervisor, steer_retry_delay_ms: 100)
    Application.put_env(:arbor_agent, :task_store_test_steer, :defer)

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", _}
    assert {:ok, control} = TaskStore.steer(task_id, "stop after this", name: store)
    assert control["status"] == "deferred"
    assert_receive {:steer_task_called, _, _, _, _}
    assert {:ok, %{state: :cancelled}} = TaskStore.cancel(task_id, name: store)
    refute_receive {:steer_task_called, _, _, _, _}, 150

    assert {:ok, terminal_control} = TaskStore.steer(task_id, "too late", name: store)
    assert terminal_control["status"] == "unsupported"
    assert terminal_control["error"] == "task_terminal"
  end

  test "terminalization marks queued controls blocked behind a deferred control unsupported", %{
    supervisor: supervisor
  } do
    store = start_configured_steering_store(supervisor, steer_retry_delay_ms: 100)
    Application.put_env(:arbor_agent, :task_store_test_steer, :defer)

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", _}
    assert {:ok, first} = TaskStore.steer(task_id, "first", name: store)
    assert_receive {:steer_task_called, "agent_1", first_attempt, _, _}
    assert first_attempt["control_id"] == first["control_id"]

    assert {:ok, second} = TaskStore.steer(task_id, "second", name: store)
    assert second["status"] == "queued"
    refute_receive {:steer_task_called, _, _, _, _}, 20

    assert {:ok, %{state: :cancelled}} = TaskStore.cancel(task_id, name: store)
    assert {:ok, status} = TaskStore.status(task_id, name: store)
    assert status.steering["counts"] == %{"unsupported" => 2}
    assert status.steering["last"]["control_id"] == second["control_id"]
    assert status.steering["last"]["status"] == "unsupported"
    assert status.steering["last"]["error"] == "task_terminal"
    assert status.steering["last"]["delivered_at"] == nil
  end

  # ---------------------------------------------------------------------------
  # Queued-confirmation lifecycle
  # ---------------------------------------------------------------------------

  test "queued control is confirmed delivered by another executor call", %{
    supervisor: supervisor
  } do
    fresh_steer_call_counter()

    Application.put_env(
      :arbor_agent,
      :task_store_test_steer,
      {:steer_fn,
       fn
         1 -> {:ok, :queued, :next_stage}
         _ -> {:ok, :next_stage}
       end}
    )

    store = start_configured_steering_store(supervisor, steer_confirmation_delay_ms: 20)

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", _}

    assert {:ok, control} = TaskStore.steer(task_id, "queue then confirm", name: store)
    assert control["status"] == "queued"
    assert control["delivered_at"] == nil

    # Initial delivery call (count=1: queued), then confirmation call (count=2: delivered)
    assert_receive {:steer_task_called, "agent_1", initial, _, _}
    assert initial["control_id"] == control["control_id"]
    assert_receive {:steer_task_called, "agent_1", confirmed, _, _}, 200
    assert confirmed["control_id"] == control["control_id"]

    assert_eventually(fn ->
      updated = get_control(store, task_id, control["control_id"])
      assert updated["status"] == "delivered"
      assert updated["delivered_at"] != nil
      assert updated["error"] == nil
    end)

    assert steer_call_count_for(control["control_id"]) >= 2
  end

  test "positive not_delivered during confirmation clears ownership and replays same id", %{
    supervisor: supervisor
  } do
    fresh_steer_call_counter()

    Application.put_env(
      :arbor_agent,
      :task_store_test_steer,
      {:steer_fn,
       fn
         1 -> {:ok, :queued, :next_stage}
         2 -> {:error, :not_delivered}
         3 -> {:ok, :queued, :next_stage}
         _ -> {:ok, :next_stage}
       end}
    )

    store = start_configured_steering_store(supervisor, steer_confirmation_delay_ms: 20)

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", _}

    assert {:ok, control} = TaskStore.steer(task_id, "replay me", name: store)

    assert_eventually(fn ->
      updated = get_control(store, task_id, control["control_id"])

      # After replay cycle (initial→accept→confirm not_delivered→replay→accept→confirm delivered)
      assert updated["status"] == "delivered"
      assert updated["delivered_at"] != nil
    end)

    count = steer_call_count_for(control["control_id"])
    # call 1: initial accept, call 2: confirm not_delivered,
    # call 3: replay accept, call 4: confirm delivered
    assert count >= 4
  end

  test "delivery_unknown during confirmation terminalizes without replay", %{
    supervisor: supervisor
  } do
    fresh_steer_call_counter()

    Application.put_env(
      :arbor_agent,
      :task_store_test_steer,
      {:steer_fn,
       fn
         1 -> {:ok, :queued, :next_stage}
         _ -> {:error, :delivery_unknown}
       end}
    )

    store = start_configured_steering_store(supervisor, steer_confirmation_delay_ms: 20)

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", _}

    assert {:ok, control} = TaskStore.steer(task_id, "unknown delivery", name: store)
    assert control["status"] == "queued"

    assert_eventually(fn ->
      updated = get_control(store, task_id, control["control_id"])
      assert updated["status"] == "delivery_unconfirmed"
      assert updated["delivered_at"] == nil
      assert updated["error"] == "delivery_unknown"
    end)

    # No further calls after terminalization
    count_after_terminal = steer_call_count_for(control["control_id"])
    Process.sleep(80)
    assert steer_call_count_for(control["control_id"]) == count_after_terminal
  end

  test "cancelled during confirmation terminalizes with a distinct error", %{
    supervisor: supervisor
  } do
    fresh_steer_call_counter()

    Application.put_env(
      :arbor_agent,
      :task_store_test_steer,
      {:steer_fn,
       fn
         1 -> {:ok, :queued, :next_stage}
         _ -> {:error, :cancelled}
       end}
    )

    store = start_configured_steering_store(supervisor, steer_confirmation_delay_ms: 20)

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", _}

    assert {:ok, control} = TaskStore.steer(task_id, "cancelled confirm", name: store)

    assert_eventually(fn ->
      updated = get_control(store, task_id, control["control_id"])
      assert updated["status"] == "delivery_unconfirmed"
      assert updated["error"] == "cancelled"
      refute updated["error"] == "delivery_unknown"
    end)
  end

  test "confirmation retries are bounded and exhaustion terminalizes delivery_unconfirmed", %{
    supervisor: supervisor
  } do
    fresh_steer_call_counter()

    Application.put_env(
      :arbor_agent,
      :task_store_test_steer,
      {:steer_fn, fn _ -> {:ok, :queued, :next_stage} end}
    )

    store =
      start_configured_steering_store(supervisor,
        steer_confirmation_delay_ms: 10,
        max_steering_confirmations: 3
      )

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", _}

    assert {:ok, control} = TaskStore.steer(task_id, "never confirms", name: store)

    assert_eventually(fn ->
      updated = get_control(store, task_id, control["control_id"])
      assert updated["status"] == "delivery_unconfirmed"
      assert updated["error"] == "confirmation_retries_exhausted"
      assert updated["delivered_at"] == nil
    end)

    # 1 initial + 3 confirmations = 4 total calls; no more after exhaustion
    count = steer_call_count_for(control["control_id"])
    assert count == 4
  end

  test "positive-nondelivery replays are bounded and exhaustion terminalizes delivery_unconfirmed",
       %{
         supervisor: supervisor
       } do
    fresh_steer_call_counter()

    # Odd calls (initial/replay delivery) accept; even calls (confirmation)
    # report positive nondelivery. This cycles accept→confirm→replay.
    Application.put_env(
      :arbor_agent,
      :task_store_test_steer,
      {:steer_fn,
       fn call_count ->
         if rem(call_count, 2) == 1 do
           {:ok, :queued, :next_stage}
         else
           {:error, :not_delivered}
         end
       end}
    )

    store =
      start_configured_steering_store(supervisor,
        steer_confirmation_delay_ms: 10,
        max_steering_replays: 2
      )

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", _}

    assert {:ok, control} = TaskStore.steer(task_id, "bounded replay", name: store)

    assert_eventually(fn ->
      updated = get_control(store, task_id, control["control_id"])
      assert updated["status"] == "delivery_unconfirmed"
      assert updated["error"] == "replay_exhausted"
      assert updated["delivered_at"] == nil
    end)

    # 1 init + 2 replay cycles (each: accept + confirm) + 1 confirm that
    # triggers exhaustion = 6 calls. After exhaustion no further calls.
    count = steer_call_count_for(control["control_id"])
    assert count == 6
  end

  test "stale confirmation timer after cancellation is harmless", %{
    supervisor: supervisor
  } do
    fresh_steer_call_counter()

    Application.put_env(:arbor_agent, :task_store_test_steer, :queued)

    store =
      start_configured_steering_store(supervisor,
        steer_confirmation_delay_ms: 5_000
      )

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", _}

    assert {:ok, control} = TaskStore.steer(task_id, "cancel before confirm", name: store)
    assert control["status"] == "queued"

    # Cancel the task while the confirmation timer is still pending (5s delay).
    assert {:ok, %{state: :cancelled}} = TaskStore.cancel(task_id, name: store)

    assert_eventually(fn ->
      updated = get_control(store, task_id, control["control_id"])
      assert updated["status"] == "delivery_unconfirmed"
      assert updated["error"] == "delivery_unconfirmed_task_cancelled"
    end)

    # Only the initial delivery call was made; no confirmation happened.
    assert steer_call_count_for(control["control_id"]) == 1

    # The store remains alive and responsive after the stale timer window.
    assert Process.alive?(Process.whereis(store))
    assert {:ok, _} = TaskStore.status(task_id, name: store)
  end

  test "two-control FIFO: only the earliest unresolved control is confirmed", %{
    supervisor: supervisor
  } do
    fresh_steer_call_counter()

    Application.put_env(
      :arbor_agent,
      :task_store_test_steer,
      {:steer_fn,
       fn control, call_count ->
         cond do
           control["sequence"] == 1 and call_count == 1 ->
             {:ok, :queued, :next_stage}

           control["sequence"] == 1 and call_count < 4 ->
             {:ok, :queued, :next_stage}

           control["sequence"] == 1 ->
             {:ok, :next_stage}

           control["sequence"] == 2 and call_count == 1 ->
             {:ok, :queued, :next_stage}

           control["sequence"] == 2 ->
             {:ok, :next_stage}

           true ->
             {:ok, :next_stage}
         end
       end}
    )

    store =
      start_configured_steering_store(supervisor,
        steer_confirmation_delay_ms: 20,
        steer_retry_delay_ms: 20
      )

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", _}

    assert {:ok, first} = TaskStore.steer(task_id, "first", name: store)
    assert first["sequence"] == 1
    assert first["status"] == "queued"

    assert {:ok, second} = TaskStore.steer(task_id, "second", name: store)
    assert second["sequence"] == 2
    assert second["status"] == "queued"

    # While control 1 is still being confirmed (3 still-queued responses + 1 delivered),
    # control 2 should receive only its initial delivery call (count == 1).
    assert_eventually(fn ->
      first_updated = get_control(store, task_id, first["control_id"])
      assert first_updated["status"] == "delivered"
    end)

    # Control 2 was NOT confirmed while control 1 was unresolved.
    second_count_while_blocked = steer_call_count_for(second["control_id"])
    assert second_count_while_blocked == 1

    # After control 1 resolves, control 2's confirmation starts.
    assert_eventually(fn ->
      second_updated = get_control(store, task_id, second["control_id"])
      assert second_updated["status"] == "delivered"
      assert second_updated["delivered_at"] != nil
    end)

    assert steer_call_count_for(second["control_id"]) >= 2
    assert steer_call_count_for(first["control_id"]) >= 4
  end

  test "two-control FIFO: nondelivery plus immediate replay success of control 1 advances and confirms control 2",
       %{supervisor: supervisor} do
    fresh_steer_call_counter()

    Application.put_env(
      :arbor_agent,
      :task_store_test_steer,
      {:steer_fn,
       fn control, call_count ->
         cond do
           control["sequence"] == 1 and call_count == 1 -> {:ok, :queued, :next_stage}
           control["sequence"] == 1 and call_count == 2 -> {:error, :not_delivered}
           control["sequence"] == 1 and call_count == 3 -> {:ok, :queued, :next_stage}
           control["sequence"] == 1 -> {:ok, :next_stage}
           control["sequence"] == 2 and call_count == 1 -> {:ok, :queued, :next_stage}
           control["sequence"] == 2 -> {:ok, :next_stage}
           true -> {:ok, :next_stage}
         end
       end}
    )

    store =
      start_configured_steering_store(supervisor,
        steer_confirmation_delay_ms: 20,
        steer_retry_delay_ms: 20
      )

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", _}

    assert {:ok, first} = TaskStore.steer(task_id, "first", name: store)
    assert first["sequence"] == 1
    assert first["status"] == "queued"

    assert {:ok, second} = TaskStore.steer(task_id, "second", name: store)
    assert second["sequence"] == 2
    assert second["status"] == "queued"

    # Control 2 is NOT confirmed while control 1 is unresolved.
    second_count_while_blocked = steer_call_count_for(second["control_id"])
    assert second_count_while_blocked == 1

    # Control 1 cycles through accept -> confirm not_delivered -> replay -> accept -> confirm delivered.
    assert_eventually(fn ->
      first_updated = get_control(store, task_id, first["control_id"])
      assert first_updated["status"] == "delivered"
      assert first_updated["delivered_at"] != nil
    end)

    # After control 1's replay settles as delivered, control 2 must be confirmed
    # and delivered — not stranded behind the resolved predecessor.
    assert_eventually(fn ->
      second_updated = get_control(store, task_id, second["control_id"])
      assert second_updated["status"] == "delivered"
      assert second_updated["delivered_at"] != nil
    end)

    assert steer_call_count_for(first["control_id"]) >= 4
    assert steer_call_count_for(second["control_id"]) >= 2
  end

  test "two-control FIFO: terminal replay failure of control 1 advances and confirms control 2",
       %{supervisor: supervisor} do
    fresh_steer_call_counter()

    Application.put_env(
      :arbor_agent,
      :task_store_test_steer,
      {:steer_fn,
       fn control, call_count ->
         cond do
           control["sequence"] == 1 and call_count == 1 -> {:ok, :queued, :next_stage}
           control["sequence"] == 1 and call_count == 2 -> {:error, :not_delivered}
           control["sequence"] == 1 and call_count == 3 -> {:error, :delivery_unknown}
           control["sequence"] == 2 and call_count == 1 -> {:ok, :queued, :next_stage}
           control["sequence"] == 2 -> {:ok, :next_stage}
           true -> {:ok, :next_stage}
         end
       end}
    )

    store =
      start_configured_steering_store(supervisor,
        steer_confirmation_delay_ms: 20,
        steer_retry_delay_ms: 20
      )

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", _}

    assert {:ok, first} = TaskStore.steer(task_id, "first", name: store)
    assert first["sequence"] == 1

    assert {:ok, second} = TaskStore.steer(task_id, "second", name: store)
    assert second["sequence"] == 2

    # Control 1 terminalizes as delivery_unconfirmed after replay returns delivery_unknown.
    assert_eventually(fn ->
      first_updated = get_control(store, task_id, first["control_id"])
      assert first_updated["status"] == "delivery_unconfirmed"
      assert first_updated["error"] == "delivery_unknown"
      assert first_updated["delivered_at"] == nil
    end)

    # Control 2 is confirmed and delivered after control 1 terminalizes — no stranding.
    assert_eventually(fn ->
      second_updated = get_control(store, task_id, second["control_id"])
      assert second_updated["status"] == "delivered"
      assert second_updated["delivered_at"] != nil
    end)

    # Control 1: initial (1) + confirm not_delivered (2) + replay delivery_unknown (3) = 3.
    assert steer_call_count_for(first["control_id"]) == 3
    assert steer_call_count_for(second["control_id"]) >= 2
  end

  test "two-control FIFO: replay exhaustion of control 1 advances and confirms control 2",
       %{supervisor: supervisor} do
    fresh_steer_call_counter()

    # Control 1 cycles: accept -> confirm not_delivered -> replay -> accept -> ... until
    # max_steering_replays (2) is hit. Control 2 always confirms delivered.
    Application.put_env(
      :arbor_agent,
      :task_store_test_steer,
      {:steer_fn,
       fn control, call_count ->
         cond do
           control["sequence"] == 1 and rem(call_count, 2) == 1 ->
             {:ok, :queued, :next_stage}

           control["sequence"] == 1 ->
             {:error, :not_delivered}

           control["sequence"] == 2 and call_count == 1 ->
             {:ok, :queued, :next_stage}

           control["sequence"] == 2 ->
             {:ok, :next_stage}

           true ->
             {:ok, :next_stage}
         end
       end}
    )

    store =
      start_configured_steering_store(supervisor,
        steer_confirmation_delay_ms: 10,
        steer_retry_delay_ms: 10,
        max_steering_replays: 2
      )

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", _}

    assert {:ok, first} = TaskStore.steer(task_id, "cycle me", name: store)
    assert first["sequence"] == 1

    assert {:ok, second} = TaskStore.steer(task_id, "after cycle", name: store)
    assert second["sequence"] == 2

    # Control 1 exhausts its replay budget and terminalizes.
    assert_eventually(fn ->
      first_updated = get_control(store, task_id, first["control_id"])
      assert first_updated["status"] == "delivery_unconfirmed"
      assert first_updated["error"] == "replay_exhausted"
      assert first_updated["delivered_at"] == nil
    end)

    # Control 2 is confirmed and delivered after control 1 exhausts — no stranding.
    assert_eventually(fn ->
      second_updated = get_control(store, task_id, second["control_id"])
      assert second_updated["status"] == "delivered"
      assert second_updated["delivered_at"] != nil
    end)

    assert steer_call_count_for(second["control_id"]) >= 2
  end

  test "stale confirmation timer message cannot mutate a resolved control",
       %{supervisor: supervisor} do
    fresh_steer_call_counter()

    Application.put_env(
      :arbor_agent,
      :task_store_test_steer,
      {:steer_fn,
       fn
         1 -> {:ok, :queued, :next_stage}
         _ -> {:ok, :next_stage}
       end}
    )

    store =
      start_configured_steering_store(supervisor,
        steer_confirmation_delay_ms: 20
      )

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", _}

    assert {:ok, control} = TaskStore.steer(task_id, "confirm then stale", name: store)
    assert control["status"] == "queued"

    # Wait for confirmation to deliver the control.
    assert_eventually(fn ->
      updated = get_control(store, task_id, control["control_id"])
      assert updated["status"] == "delivered"
      assert updated["delivered_at"] != nil
    end)

    delivered_at = get_control(store, task_id, control["control_id"])["delivered_at"]
    count_before = steer_call_count_for(control["control_id"])

    # Actually inject and fire the stale confirmation timer message.
    send(store, {:confirm_steer, task_id, control["control_id"]})

    # Let the store process the stale message before asserting.
    ref = Process.monitor(store)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> flunk("store crashed on stale timer")
    after
      100 -> :ok
    end

    # The stale timer must not mutate the resolved control or re-invoke the executor.
    updated = get_control(store, task_id, control["control_id"])
    assert updated["status"] == "delivered"
    assert updated["delivered_at"] == delivered_at
    assert steer_call_count_for(control["control_id"]) == count_before

    assert Process.alive?(Process.whereis(store))
    assert {:ok, _} = TaskStore.status(task_id, name: store)
  end

  test "initial delivery retries are bounded and exhaustion terminalizes delivery_unconfirmed", %{
    supervisor: supervisor
  } do
    Application.put_env(:arbor_agent, :task_store_test_steer, :defer)

    store =
      start_configured_steering_store(supervisor,
        steer_retry_delay_ms: 10,
        max_steer_retries: 3
      )

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", _}

    assert {:ok, control} = TaskStore.steer(task_id, "always defers", name: store)

    assert_eventually(fn ->
      updated = get_control(store, task_id, control["control_id"])
      assert updated["status"] == "delivery_unconfirmed"
      assert updated["error"] == "initial_delivery_retries_exhausted"
      assert updated["delivered_at"] == nil
    end)

    # After exhaustion, the control is terminal and the store never schedules
    # another retry. Confirm the store is still responsive.
    assert {:ok, _} = TaskStore.status(task_id, name: store)
  end

  test "delivery_unknown during initial delivery terminalizes immediately without retry", %{
    supervisor: supervisor
  } do
    Application.put_env(:arbor_agent, :task_store_test_steer, :delivery_unknown)

    store =
      start_configured_steering_store(supervisor,
        steer_retry_delay_ms: 10,
        max_steer_retries: 5
      )

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", _}

    assert {:ok, control} = TaskStore.steer(task_id, "unknown at delivery", name: store)

    assert_eventually(fn ->
      updated = get_control(store, task_id, control["control_id"])
      assert updated["status"] == "delivery_unconfirmed"
      assert updated["error"] == "delivery_unknown"
      assert updated["delivered_at"] == nil
    end)

    # Only one call was made — no retries despite a generous max_steer_retries.
    assert_receive {:steer_task_called, _, _, _, _}
    refute_receive {:steer_task_called, _, _, _, _}, 100
  end

  test "cancelled during initial delivery terminalizes immediately with a distinct error", %{
    supervisor: supervisor
  } do
    Application.put_env(:arbor_agent, :task_store_test_steer, :cancelled)

    store =
      start_configured_steering_store(supervisor,
        steer_retry_delay_ms: 10,
        max_steer_retries: 5
      )

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)
    assert_receive {:steering_executor_started, _pid, "agent_1", "work", _}

    assert {:ok, control} = TaskStore.steer(task_id, "cancelled at delivery", name: store)

    assert_eventually(fn ->
      updated = get_control(store, task_id, control["control_id"])
      assert updated["status"] == "delivery_unconfirmed"
      assert updated["error"] == "cancelled"
      assert updated["delivered_at"] == nil
    end)

    assert_receive {:steer_task_called, _, _, _, _}
    refute_receive {:steer_task_called, _, _, _, _}, 100
  end

  test "hot-state upgrade: legacy records missing confirmation keys stay alive and do not manufacture ACKs",
       %{supervisor: supervisor} do
    store = start_configured_steering_store(supervisor, steer_confirmation_delay_ms: 10_000)
    Application.put_env(:arbor_agent, :task_store_test_steer, :queued)

    assert {:ok, task_id} = TaskStore.dispatch("agent_1", "work", name: store)

    assert_receive {:steering_executor_started, runner_pid, "agent_1", "work", _}

    # Create a real accepted queued control with full post-upgrade machinery.
    assert {:ok, first} = TaskStore.steer(task_id, "legacy queued", name: store)
    assert first["status"] == "queued"
    assert first["delivered_at"] == nil
    assert first["message"] == "legacy queued"

    # Model a pre-upgrade record: deliberately remove only the new
    # confirmation/replay keys, keeping accepted_control_ids intact.
    :sys.replace_state(store, fn state ->
      update_in(state.tasks[task_id], fn record ->
        record
        |> Map.delete(:confirmation_retries)
        |> Map.delete(:replay_counts)
      end)
    end)

    # Steering a new control must not crash; it triggers lazy normalization
    # that materializes missing maps and terminalizes the legacy accepted
    # queued control.
    Application.put_env(:arbor_agent, :task_store_test_steer, :deliver)

    assert {:ok, second} = TaskStore.steer(task_id, "post-upgrade deliver", name: store)
    assert second["status"] == "delivered"
    assert second["delivered_at"] != nil

    # The legacy accepted queued control is terminalized, NOT delivered.
    first_updated = get_control(store, task_id, first["control_id"])
    assert first_updated["status"] == "delivery_unconfirmed"
    assert first_updated["error"] == "legacy_upgrade_unconfirmed"
    assert first_updated["delivered_at"] == nil
    assert first_updated["control_id"] == first["control_id"]
    assert first_updated["message"] == "legacy queued"

    # Store is still alive and responsive.
    assert Process.alive?(Process.whereis(store))
    assert {:ok, _} = TaskStore.status(task_id, name: store)

    # Terminal reconciliation also stays alive and preserves payloads.
    send(runner_pid, {:finish, {:ok, %{}}})

    assert_eventually(fn ->
      assert {:ok, status} = TaskStore.status(task_id, name: store)
      assert status.state == :done
    end)

    # No control manufactured an ACK from the legacy accepted state; IDs and
    # payloads survive the upgrade and terminal reconciliation.
    final_first = get_control(store, task_id, first["control_id"])
    final_second = get_control(store, task_id, second["control_id"])

    assert final_first["status"] == "delivery_unconfirmed"
    assert final_first["delivered_at"] == nil
    assert final_first["control_id"] == first["control_id"]
    assert final_first["message"] == "legacy queued"

    assert final_second["status"] == "delivered"
    assert final_second["delivered_at"] != nil
    assert final_second["control_id"] == second["control_id"]
    assert final_second["message"] == "post-upgrade deliver"
  end

  test "security regression: pending-approval runner termination fails closed and cleans up once",
       %{store: store} do
    descriptor = cleanup_descriptor()

    assert {:ok, task_id} =
             TaskStore.dispatch("agent_1", "do gated work",
               name: store,
               runner: PendingRunner,
               approval_answer_cap_id: "cap_pending_owner",
               approval_answer_revoke: revoke_to(self()),
               approval_cleanup_descriptor: descriptor
             )

    assert_eventually(fn ->
      assert {:ok, status} = TaskStore.status(task_id, name: store)
      assert status.state == :failed
      assert status.waiting_on == nil
      assert status.completed_at

      assert {:error, {:failed, {:approval_owner_terminated, "approval_1"}}} =
               TaskStore.result(task_id, name: store)
    end)

    assert_receive {:lifecycle_cleanup, ^task_id, cleanup_opts}, 500
    assert cleanup_opts[:caller_id] == "dispatch_owner"
    assert cleanup_opts[:cleanup_reason] == :task_termination
    assert cleanup_opts[:trace_id] == "trace_cleanup"
    assert_receive {:revoke_approval_answer_capability, "cap_pending_owner"}
    refute_receive {:lifecycle_cleanup, ^task_id, _}, 200
  end

  test "pending-approval error tuple also fails closed with owner-terminated error", %{
    store: store
  } do
    descriptor = cleanup_descriptor()

    assert {:ok, task_id} =
             TaskStore.dispatch("agent_1", "do gated work",
               name: store,
               runner: PendingErrorRunner,
               approval_cleanup_descriptor: descriptor
             )

    assert_eventually(fn ->
      assert {:error, {:failed, {:approval_owner_terminated, "approval_err_1"}}} =
               TaskStore.result(task_id, name: store)
    end)

    assert_receive {:lifecycle_cleanup, ^task_id, _opts}, 500
  end

  test "successful completion schedules lifecycle approval cleanup exactly once", %{store: store} do
    descriptor = cleanup_descriptor()

    assert {:ok, task_id} =
             TaskStore.dispatch("agent_1", "do work",
               name: store,
               test_pid: self(),
               runner: ControlledRunner,
               approval_cleanup_descriptor: descriptor
             )

    assert_receive {:runner_started, runner_pid, "agent_1", "do work", runner_opts}
    refute Keyword.has_key?(runner_opts, :approval_cleanup_descriptor)

    send(runner_pid, {:finish, {:ok, %{result_type: :test, payload: %{ok: true}, raw: "ok"}}})

    assert_eventually(fn ->
      assert {:ok, %{state: :done}} = TaskStore.status(task_id, name: store)
      assert {:ok, %{result_type: :test}} = TaskStore.result(task_id, name: store)
    end)

    assert_receive {:lifecycle_cleanup, ^task_id, opts}, 500
    assert opts[:cleanup_reason] == :task_termination
    refute_receive {:lifecycle_cleanup, ^task_id, _}, 200
  end

  test "returned error and pipeline timeout schedule lifecycle approval cleanup", %{store: store} do
    descriptor = cleanup_descriptor()

    assert {:ok, task_id} =
             TaskStore.dispatch("agent_1", "do work",
               name: store,
               test_pid: self(),
               runner: ControlledRunner,
               approval_cleanup_descriptor: descriptor
             )

    assert_receive {:runner_started, runner_pid, "agent_1", "do work", _}
    send(runner_pid, {:finish, {:error, :pipeline_timeout}})

    assert_eventually(fn ->
      assert {:error, {:failed, :pipeline_timeout}} = TaskStore.result(task_id, name: store)
    end)

    assert_receive {:lifecycle_cleanup, ^task_id, _opts}, 500
    refute_receive {:lifecycle_cleanup, ^task_id, _}, 200
  end

  test "abnormal DOWN schedules lifecycle approval cleanup", %{store: store} do
    descriptor = cleanup_descriptor()

    assert {:ok, task_id} =
             TaskStore.dispatch("agent_1", "do work",
               name: store,
               test_pid: self(),
               runner: CrashRunner,
               approval_cleanup_descriptor: descriptor
             )

    assert_receive {:runner_started, runner_pid, "agent_1", "do work", _}
    send(runner_pid, :crash)

    assert_eventually(fn ->
      assert {:ok, %{state: :failed}} = TaskStore.status(task_id, name: store)
      assert {:error, {:failed, :abnormal_crash}} = TaskStore.result(task_id, name: store)
    end)

    assert_receive {:lifecycle_cleanup, ^task_id, _opts}, 500
    refute_receive {:lifecycle_cleanup, ^task_id, _}, 200
  end

  test "cleanup failure never changes terminal result availability", %{store: store} do
    Application.put_env(:arbor_agent, :lifecycle_cleanup_behavior, :raise)
    descriptor = cleanup_descriptor()

    assert {:ok, task_id} =
             TaskStore.dispatch("agent_1", "do work",
               name: store,
               test_pid: self(),
               runner: ControlledRunner,
               approval_cleanup_descriptor: descriptor
             )

    assert_receive {:runner_started, runner_pid, "agent_1", "do work", _}

    send(
      runner_pid,
      {:finish, {:ok, %{result_type: :test, payload: %{ok: true}, raw: "survived"}}}
    )

    assert_eventually(fn ->
      assert {:ok, result} = TaskStore.result(task_id, name: store)
      assert result.payload.ok == true
      assert {:ok, %{state: :done}} = TaskStore.status(task_id, name: store)
    end)

    assert_receive {:lifecycle_cleanup, ^task_id, _opts}, 500

    # Result remains available after the cleanup process crashes.
    assert {:ok, result} = TaskStore.result(task_id, name: store)
    assert result.payload.ok == true
  end

  test "security regression: direct cancel schedules exact-task cleanup once", %{
    store: store
  } do
    task_id = "task_cancel_1"
    other_task_id = "task_cancel_10"

    assert {:ok, ^task_id} =
             TaskStore.dispatch("agent_1", "do work",
               name: store,
               task_id: task_id,
               test_pid: self(),
               runner: ControlledRunner,
               approval_cleanup_descriptor: cleanup_descriptor()
             )

    assert_receive {:runner_started, _runner_pid, "agent_1", "do work", _}
    assert {:ok, %{state: :cancelled}} = TaskStore.cancel(task_id, name: store)

    assert_receive {:lifecycle_cleanup, ^task_id, opts}, 500
    assert opts[:caller_id] == "dispatch_owner"
    assert opts[:cleanup_reason] == :task_cancellation
    assert opts[:trace_id] == "trace_cleanup"

    assert {:error, {:not_running, :cancelled}} = TaskStore.cancel(task_id, name: store)
    refute_receive {:lifecycle_cleanup, ^task_id, _}, 200

    assert {:ok, ^other_task_id} =
             TaskStore.dispatch("agent_1", "other work",
               name: store,
               task_id: other_task_id,
               test_pid: self(),
               runner: ControlledRunner,
               approval_cleanup_descriptor: cleanup_descriptor()
             )

    assert_receive {:runner_started, _runner_pid, "agent_1", "other work", _}
    assert {:ok, %{state: :cancelled}} = TaskStore.cancel(other_task_id, name: store)
    assert_receive {:lifecycle_cleanup, ^other_task_id, _}, 500
  end

  test "security regression: direct dispatch cannot select or retain cleanup MFA/backends", %{
    store: store
  } do
    # Malicious per-task MFA/backends/functions/PIDs must be stripped and ignored;
    # store-init probe MFA and production-default backends remain authority.
    evil_fun = fn _task_id, _opts -> send(self(), :evil_fun) end

    descriptor =
      cleanup_descriptor()
      |> Map.put(:mfa, {EvilCleanup, :cleanup, 2})
      |> Map.put(:module, EvilCleanup)
      |> Map.put(:function, :cleanup)
      |> Map.put(:fun, evil_fun)
      |> Map.put(:consensus_module, EvilConsensus)
      |> Map.put(:interaction_router, EvilCleanup)
      |> Map.put(:audit_module, EvilAudit)
      |> Map.put(:notify_pid, self())
      |> Map.put(:unknown_key, :drop_me)

    assert {:ok, task_id} =
             TaskStore.dispatch("agent_1", "do work",
               name: store,
               test_pid: self(),
               runner: ControlledRunner,
               approval_cleanup_descriptor: descriptor
             )

    assert_receive {:runner_started, runner_pid, "agent_1", "do work", _}
    send(runner_pid, {:finish, {:ok, %{result_type: :test, payload: %{ok: true}, raw: "ok"}}})

    assert_eventually(fn ->
      assert {:ok, %{state: :done}} = TaskStore.status(task_id, name: store)
    end)

    assert_receive {:lifecycle_cleanup, ^task_id, opts}, 500
    assert opts[:cleanup_reason] == :task_termination
    assert opts[:caller_id] == "dispatch_owner"
    assert opts[:trace_id] == "trace_cleanup"
    # Store-init backends, not the malicious dispatch values.
    assert opts[:consensus_module] == Arbor.Consensus
    assert opts[:audit_module] == Arbor.Security
    refute opts[:consensus_module] == EvilConsensus
    refute opts[:audit_module] == EvilAudit
    refute Keyword.has_key?(opts, :notify_pid)
    refute Keyword.has_key?(opts, :mfa)
    refute Keyword.has_key?(opts, :fun)
    refute Keyword.has_key?(opts, :unknown_key)
    refute_receive {:evil_cleanup, ^task_id, _}, 200
    refute_receive :evil_fun, 200
    refute_receive {:evil_consensus_cancel, _}, 200
    refute_receive {:evil_audit, _, _, _, _, _}, 200
  end

  test "blocked cleanup child does not delay terminal result availability", %{
    store: store
  } do
    Application.put_env(:arbor_agent, :lifecycle_cleanup_behavior, :block)
    descriptor = cleanup_descriptor()

    assert {:ok, task_id} =
             TaskStore.dispatch("agent_1", "do work",
               name: store,
               test_pid: self(),
               runner: ControlledRunner,
               approval_cleanup_descriptor: descriptor
             )

    assert_receive {:runner_started, runner_pid, "agent_1", "do work", _}

    send(
      runner_pid,
      {:finish, {:ok, %{result_type: :test, payload: %{ok: true}, raw: "not delayed"}}}
    )

    # Terminal state must be available while cleanup is still blocked.
    assert_eventually(fn ->
      assert {:ok, result} = TaskStore.result(task_id, name: store)
      assert result.payload.ok == true
      assert {:ok, %{state: :done}} = TaskStore.status(task_id, name: store)
    end)

    assert_receive {:lifecycle_cleanup, ^task_id, _opts}, 500
    assert_receive {:lifecycle_cleanup_blocked, ^task_id, cleanup_pid}, 500
    assert Process.alive?(cleanup_pid)

    # Result remains readable while the cleanup child is deliberately blocked.
    assert {:ok, result} = TaskStore.result(task_id, name: store)
    assert result.payload.ok == true

    # Release promptly so supervised teardown does not wait on the block timeout.
    send(cleanup_pid, :release_cleanup)
  end

  test "forged cleanup mailbox messages are ignored", %{store: store} do
    send(store, {:run_approval_cleanup, "task_forged", cleanup_descriptor()})

    refute_receive {:lifecycle_cleanup, "task_forged", _}, 200
  end

  test "hot reload regression: legacy TaskStore state terminalizes without crashing", %{
    store: store
  } do
    :sys.replace_state(store, fn state ->
      Map.drop(state, [
        :cleanup_supervisor,
        :approval_cleanup_mfa,
        :approval_cleanup_consensus_module,
        :approval_cleanup_interaction_router,
        :approval_cleanup_audit_module
      ])
    end)

    assert {:ok, task_id} =
             TaskStore.dispatch("agent_1", "do work",
               name: store,
               test_pid: self(),
               runner: ControlledRunner,
               approval_cleanup_descriptor: cleanup_descriptor()
             )

    assert_receive {:runner_started, runner_pid, "agent_1", "do work", _}
    send(runner_pid, {:finish, {:ok, %{result_type: :test, payload: %{ok: true}, raw: "ok"}}})

    assert_eventually(fn ->
      assert {:ok, %{payload: %{ok: true}}} = TaskStore.result(task_id, name: store)
      assert {:ok, %{state: :done}} = TaskStore.status(task_id, name: store)
    end)

    assert Process.alive?(Process.whereis(store))
  end

  test "terminal result remains available while cleanup supervisor is suspended", %{
    supervisor: task_supervisor
  } do
    unique = System.unique_integer([:positive])
    cleanup_supervisor = Module.concat(__MODULE__, :"CleanupSup#{unique}")
    store = Module.concat(__MODULE__, :"StalledCleanupStore#{unique}")

    start_supervised!(
      Supervisor.child_spec({Task.Supervisor, name: cleanup_supervisor}, id: cleanup_supervisor)
    )

    start_supervised!(
      Supervisor.child_spec(
        {TaskStore,
         name: store,
         task_supervisor: task_supervisor,
         cleanup_supervisor: cleanup_supervisor,
         runner: ControlledRunner,
         approval_cleanup_mfa: {LifecycleCleanupProbe, :cleanup, 2}},
        id: store
      )
    )

    # Stall cleanup scheduling only; task execution stays on the healthy supervisor.
    :sys.suspend(cleanup_supervisor)

    task_id =
      try do
        assert {:ok, task_id} =
                 TaskStore.dispatch("agent_1", "do work",
                   name: store,
                   test_pid: self(),
                   runner: ControlledRunner,
                   approval_cleanup_descriptor: cleanup_descriptor()
                 )

        assert_receive {:runner_started, runner_pid, "agent_1", "do work", _}

        send(
          runner_pid,
          {:finish, {:ok, %{result_type: :test, payload: %{ok: true}, raw: "while stalled"}}}
        )

        # Result/status must be readable while cleanup supervisor cannot accept children.
        assert_eventually(fn ->
          assert {:ok, result} = TaskStore.result(task_id, name: store)
          assert result.payload.ok == true
          assert {:ok, %{state: :done}} = TaskStore.status(task_id, name: store)
        end)

        # Cleanup has not run yet (supervisor still suspended).
        refute_receive {:lifecycle_cleanup, ^task_id, _}, 200

        # Still readable after the negative window.
        assert {:ok, %{payload: %{ok: true}}} = TaskStore.result(task_id, name: store)
        task_id
      after
        :sys.resume(cleanup_supervisor)
      end

    assert_receive {:lifecycle_cleanup, ^task_id, opts}, 1_000
    assert opts[:cleanup_reason] == :task_termination
    refute_receive {:lifecycle_cleanup, ^task_id, _}, 200
  end

  test "rejects invalid approval_cleanup_mfa shape at store init", %{supervisor: supervisor} do
    assert_raise ArgumentError, ~r/approval_cleanup_mfa must be \{module, function, 2\}/, fn ->
      TaskStore.start_link(
        name: :"bad_cleanup_mfa_#{System.unique_integer([:positive])}",
        task_supervisor: supervisor,
        approval_cleanup_mfa: {LifecycleCleanupProbe, :cleanup, 1}
      )
    end
  end

  test "cancels a running task and keeps it cancelled after the process exits", %{store: store} do
    assert {:ok, task_id} =
             TaskStore.dispatch("agent_1", "do work",
               name: store,
               test_pid: self(),
               metadata: %{ticket: "A-1"},
               approval_answer_cap_id: "cap_task_cancel",
               approval_answer_revoke: revoke_to(self()),
               steer_cap_id: "cap_task_steer_cancel",
               steer_capability_revoke: revoke_steer_to(self()),
               adoption_cap_id: "cap_task_adopt_cancel",
               adoption_capability_revoke: revoke_adoption_to(self())
             )

    assert_receive {:runner_started, runner_pid, "agent_1", "do work", _opts}
    ref = Process.monitor(runner_pid)

    assert {:ok, status} = TaskStore.cancel(task_id, name: store)
    assert status.state == :cancelled
    assert status.current_step == "cancelled"
    assert status.completed_at

    assert_receive {:DOWN, ^ref, :process, ^runner_pid, :killed}

    assert {:ok, status} = TaskStore.status(task_id, name: store)
    assert status.state == :cancelled
    assert {:error, :cancelled} = TaskStore.result(task_id, name: store)
    assert_receive {:revoke_approval_answer_capability, "cap_task_cancel"}
    assert_receive {:revoke_steer_capability, "cap_task_steer_cancel"}
    assert_receive {:revoke_adoption_capability, "cap_task_adopt_cancel"}
  end

  test "cancel propagates agent_id and task_id to the scoped turn bridge before killing the runner",
       %{store: store} do
    test_pid = self()

    # Production-shaped callback: SessionManager.cancel_task/2 (agent_id, task_id).
    cancel_turn = fn agent_id, cancelled_task_id ->
      send(test_pid, {:cancel_turn_hook, agent_id, cancelled_task_id, self()})
      :ok
    end

    assert {:ok, task_id} =
             TaskStore.dispatch("agent_coding_1", "implement feature",
               name: store,
               test_pid: test_pid,
               cancel_turn: cancel_turn,
               approval_answer_cap_id: "cap_turn_cancel",
               approval_answer_revoke: revoke_to(test_pid)
             )

    assert_receive {:runner_started, runner_pid, "agent_coding_1", "implement feature", _opts}
    ref = Process.monitor(runner_pid)

    assert {:ok, status} = TaskStore.cancel(task_id, name: store)
    assert status.state == :cancelled

    # Hook must fire from the store process (survives :kill) with agent + task_id.
    assert_receive {:cancel_turn_hook, "agent_coding_1", ^task_id, store_pid}
    assert store_pid != runner_pid
    assert Process.whereis(store) == store_pid or is_pid(store_pid)

    assert_receive {:DOWN, ^ref, :process, ^runner_pid, :killed}
    assert_receive {:revoke_approval_answer_capability, "cap_turn_cancel"}
    assert {:error, :cancelled} = TaskStore.result(task_id, name: store)
  end

  test "returns clean errors for unknown and finished task cancellation", %{store: store} do
    assert {:error, :not_found} = TaskStore.cancel("missing", name: store)

    assert {:ok, task_id} =
             TaskStore.dispatch("agent_1", "do work",
               name: store,
               test_pid: self()
             )

    assert_receive {:runner_started, runner_pid, "agent_1", "do work", _opts}
    send(runner_pid, {:finish, {:ok, %{result_type: :test, payload: %{}, raw: "done"}}})

    assert_eventually(fn ->
      assert {:ok, status} = TaskStore.status(task_id, name: store)
      assert status.state == :done
    end)

    assert {:error, {:not_running, :done}} = TaskStore.cancel(task_id, name: store)
  end

  test "string and legacy maps use the default runner path", %{store: store} do
    assert {:ok, _task_id} =
             TaskStore.dispatch("agent_1", "plain string", name: store, test_pid: self())

    assert_receive {:runner_started, _pid, "agent_1", "plain string", opts}
    assert is_list(opts)
    assert opts[:test_pid] == self()

    assert {:ok, _task_id} =
             TaskStore.dispatch("agent_1", %{"input" => "legacy input"},
               name: store,
               test_pid: self()
             )

    assert_receive {:runner_started, _pid, "agent_1", %{"input" => "legacy input"}, _opts}

    assert {:ok, _task_id} =
             TaskStore.dispatch("agent_1", %{prompt: "legacy prompt"},
               name: store,
               test_pid: self()
             )

    assert_receive {:runner_started, _pid, "agent_1", %{prompt: "legacy prompt"}, _opts}
  end

  test "configured default executor uses JSON-clean boundary for plain string and legacy map",
       %{
         supervisor: supervisor
       } do
    Application.put_env(:arbor_agent, :default_task_executor, DefaultRecordingExecutor)

    unique = System.unique_integer([:positive])
    store = Module.concat(__MODULE__, :"DefaultExecStore#{unique}")

    start_supervised!(
      {TaskStore, name: store, task_supervisor: supervisor},
      id: store
    )

    # Plain string stays a string; private TaskStore opts do not leak.
    assert {:ok, task_id} =
             TaskStore.dispatch("agent_1", "via default config",
               name: store,
               task_id: "task_default_1",
               timeout: 15_000,
               caller_id: "caller_default",
               metadata: %{"ticket" => "D-1"},
               approval_answer_cap_id: "cap_private_default",
               approval_answer_revoke: revoke_to(self()),
               test_pid: self()
             )

    assert_receive {:default_executor, runner_pid, "agent_1", "via default config", context}
    assert is_map(context)
    assert context["task_id"] == "task_default_1"
    assert context["timeout"] == 15_000
    assert context["caller_id"] == "caller_default"
    assert context["metadata"] == %{"ticket" => "D-1"}
    refute Map.has_key?(context, :test_pid)
    refute Map.has_key?(context, "test_pid")
    refute Map.has_key?(context, :approval_answer_cap_id)
    refute Map.has_key?(context, "approval_answer_cap_id")
    refute Map.has_key?(context, :approval_answer_revoke)
    refute is_list(context)
    assert {:ok, _} = Jason.encode(context)

    send(runner_pid, {:finish, {:ok, %{result_type: :test, payload: %{}, raw: "ok"}}})

    assert_eventually(fn ->
      assert {:ok, status} = TaskStore.status(task_id, name: store)
      assert status.state == :done
    end)

    # Legacy unkinded map is canonicalized to a string-keyed JSON map.
    assert {:ok, _task_id2} =
             TaskStore.dispatch("agent_1", %{prompt: "legacy default", ticket: "L-1"},
               name: store,
               task_id: "task_default_legacy"
             )

    assert_receive {:default_executor, runner_pid2, "agent_1", clean_legacy, context2}
    assert clean_legacy == %{"prompt" => "legacy default", "ticket" => "L-1"}
    assert is_map(context2)
    assert context2["task_id"] == "task_default_legacy"
    assert {:ok, _} = Jason.encode(clean_legacy)
    send(runner_pid2, {:finish, {:ok, %{result_type: :test, payload: %{}, raw: "ok"}}})

    # Non-JSON metadata rejected before spawn on the default path.
    assert {:error, :non_json_execution_context} =
             TaskStore.dispatch("agent_1", "will not start",
               name: store,
               metadata: %{"owner" => self()}
             )

    refute_received {:default_executor, _, _, _, _}

    # Non-JSON values inside a legacy map rejected before spawn.
    assert {:error, :non_json_task} =
             TaskStore.dispatch("agent_1", %{input: "x", owner: self()}, name: store)

    refute_received {:default_executor, _, _, _, _}
  end

  test "invalid default_task_executor is rejected before spawn", %{supervisor: supervisor} do
    Application.put_env(:arbor_agent, :default_task_executor, NoRunModule)

    unique = System.unique_integer([:positive])
    store = Module.concat(__MODULE__, :"BadDefaultStore#{unique}")

    start_supervised!(
      {TaskStore, name: store, task_supervisor: supervisor},
      id: store
    )

    assert {:error, {:invalid_default_task_executor, NoRunModule}} =
             TaskStore.dispatch("agent_1", "will not start", name: store)

    refute_received {:runner_started, _, _, _, _}
    refute_received {:configured_executor, _, _, _, _}
  end

  test "explicit coding_change kind routes to the configured executor with JSON-clean context",
       %{
         supervisor: supervisor
       } do
    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => CodingChangeExecutor
    })

    unique = System.unique_integer([:positive])
    store = Module.concat(__MODULE__, :"KindStore#{unique}")

    start_supervised!(
      {TaskStore, name: store, task_supervisor: supervisor},
      id: store
    )

    task = %{
      "kind" => "coding_change",
      "input" => "implement feature",
      "repo" => "/tmp/repo"
    }

    assert {:ok, task_id} =
             TaskStore.dispatch("agent_coding", task,
               name: store,
               task_id: "task_coding_1",
               timeout: 30_000,
               caller_id: "caller_42",
               metadata: %{"ticket" => "C-1"},
               # Private store options must not leak into configured executor context.
               approval_answer_cap_id: "cap_private",
               approval_answer_revoke: revoke_to(self()),
               test_pid: self()
             )

    assert_receive {:configured_executor, runner_pid, "agent_coding", clean_task, context}

    assert clean_task == %{
             "kind" => "coding_change",
             "input" => "implement feature",
             "repo" => "/tmp/repo"
           }

    assert is_map(context)
    assert context["task_id"] == "task_coding_1"
    assert context["timeout"] == 30_000
    assert context["caller_id"] == "caller_42"
    assert context["metadata"] == %{"ticket" => "C-1"}

    refute Map.has_key?(context, :test_pid)
    refute Map.has_key?(context, "test_pid")
    refute Map.has_key?(context, :approval_answer_cap_id)
    refute Map.has_key?(context, "approval_answer_cap_id")
    refute Map.has_key?(context, :approval_answer_revoke)
    refute is_list(context)

    assert {:ok, _} = Jason.encode(context)
    assert {:ok, _} = Jason.encode(clean_task)

    send(runner_pid, {:finish, {:ok, %{result_type: :coding_change, payload: %{}, raw: "ok"}}})

    assert_eventually(fn ->
      assert {:ok, status} = TaskStore.status(task_id, name: store)
      assert status.state == :done
    end)
  end

  test "atom coding_change kind is canonicalized to string form before spawn", %{
    supervisor: supervisor
  } do
    Application.put_env(:arbor_agent, :task_executors, %{
      coding_change: CodingChangeExecutor
    })

    unique = System.unique_integer([:positive])
    store = Module.concat(__MODULE__, :"AtomKindStore#{unique}")

    start_supervised!(
      {TaskStore, name: store, task_supervisor: supervisor},
      id: store
    )

    task = %{kind: :coding_change, input: "atom kind task"}

    assert {:ok, _task_id} =
             TaskStore.dispatch("agent_1", task,
               name: store,
               metadata: %{"ticket" => "atom"}
             )

    assert_receive {:configured_executor, runner_pid, "agent_1", clean_task, context}
    assert clean_task == %{"kind" => "coding_change", "input" => "atom kind task"}
    assert context["metadata"] == %{"ticket" => "atom"}
    assert {:ok, _} = Jason.encode(clean_task)
    send(runner_pid, {:finish, {:ok, %{result_type: :test, payload: %{}, raw: "ok"}}})
  end

  test "conflicting atom and string kinds are rejected before spawn", %{supervisor: supervisor} do
    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => CodingChangeExecutor,
      "other_kind" => CodingChangeExecutor
    })

    unique = System.unique_integer([:positive])
    store = Module.concat(__MODULE__, :"ConflictStore#{unique}")

    start_supervised!(
      {TaskStore, name: store, task_supervisor: supervisor},
      id: store
    )

    conflicting_task = %{
      :kind => :coding_change,
      "kind" => "other_kind",
      "input" => "x"
    }

    assert {:error, :conflicting_task_kind} =
             TaskStore.dispatch("agent_1", conflicting_task, name: store)

    refute_received {:configured_executor, _, _, _, _}
  end

  test "non-JSON task and metadata fail before spawn", %{supervisor: supervisor} do
    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => CodingChangeExecutor
    })

    unique = System.unique_integer([:positive])
    store = Module.concat(__MODULE__, :"NonJsonStore#{unique}")

    start_supervised!(
      {TaskStore, name: store, task_supervisor: supervisor},
      id: store
    )

    assert {:error, :non_json_task} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "x", "owner" => self()},
               name: store
             )

    refute_received {:configured_executor, _, _, _, _}

    assert {:error, :non_json_task} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "x", "cb" => fn -> :ok end},
               name: store
             )

    refute_received {:configured_executor, _, _, _, _}

    assert {:error, :non_json_task} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "x", "mode" => :fast},
               name: store
             )

    refute_received {:configured_executor, _, _, _, _}

    assert {:error, :non_json_execution_context} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "x"},
               name: store,
               metadata: %{"test_pid" => self()}
             )

    refute_received {:configured_executor, _, _, _, _}
  end

  test "status projects only current_step and waiting_on from task_status/2", %{
    supervisor: supervisor
  } do
    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => CodingChangeExecutor
    })

    Application.put_env(:arbor_agent, :task_store_test_progress, %{
      "current_step" => "validating",
      "waiting_on" => "approval_9",
      "task_id" => "forged_task",
      "state" => "done",
      "started_at" => "forged",
      "updated_at" => "forged",
      "completed_at" => "forged",
      "metadata" => %{"evil" => true},
      "agent_id" => "forged_agent"
    })

    unique = System.unique_integer([:positive])
    store = Module.concat(__MODULE__, :"ProgressStore#{unique}")

    start_supervised!(
      {TaskStore, name: store, task_supervisor: supervisor},
      id: store
    )

    assert {:ok, task_id} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "progress"},
               name: store,
               task_id: "task_progress_1",
               metadata: %{"ticket" => "P-1"}
             )

    assert_receive {:configured_executor, runner_pid, "agent_1", _task, _context}

    assert {:ok, status} = TaskStore.status(task_id, name: store)
    assert status.state == :running
    assert status.task_id == "task_progress_1"
    assert status.agent_id == "agent_1"
    assert status.current_step == "validating"
    assert status.waiting_on == "approval_9"
    assert status.metadata == %{"ticket" => "P-1"}
    assert %DateTime{} = status.started_at
    assert %DateTime{} = status.updated_at
    assert status.completed_at == nil

    assert_receive {:task_status_called, "agent_1", %{"task_id" => "task_progress_1"}, _from}

    send(runner_pid, {:finish, {:ok, %{result_type: :test, payload: %{}, raw: "ok"}}})
  end

  test "status ignores non-JSON progress and invalid field values", %{supervisor: supervisor} do
    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => CodingChangeExecutor
    })

    unique = System.unique_integer([:positive])
    store = Module.concat(__MODULE__, :"BadProgressStore#{unique}")

    start_supervised!(
      {TaskStore, name: store, task_supervisor: supervisor},
      id: store
    )

    # Non-JSON progress (PID) is ignored entirely; stored view is preserved.
    Application.put_env(:arbor_agent, :task_store_test_progress, %{
      "current_step" => "should_not_project",
      "waiting_on" => "should_not_project",
      "owner" => self()
    })

    assert {:ok, task_id} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "bad progress"},
               name: store
             )

    assert_receive {:configured_executor, runner_pid, "agent_1", _task, _context}

    assert {:ok, status} = TaskStore.status(task_id, name: store)
    assert status.state == :running
    assert status.current_step == "running"
    assert status.waiting_on == nil
    assert_receive {:task_status_called, "agent_1", _context, _from}

    # Invalid field values are ignored; valid projected fields still apply.
    Application.put_env(:arbor_agent, :task_store_test_progress, %{
      "current_step" => "compiling",
      "waiting_on" => 99,
      "extra" => true
    })

    assert {:ok, status2} = TaskStore.status(task_id, name: store)
    assert status2.current_step == "compiling"
    assert status2.waiting_on == nil
    assert_receive {:task_status_called, "agent_1", _context, _from}

    send(runner_pid, {:finish, {:ok, %{result_type: :test, payload: %{}, raw: "ok"}}})
  end

  test "status falls back when task_status/2 is absent or errors", %{supervisor: supervisor} do
    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => RunOnlyExecutor
    })

    unique = System.unique_integer([:positive])
    store = Module.concat(__MODULE__, :"NoStatusStore#{unique}")

    start_supervised!(
      {TaskStore, name: store, task_supervisor: supervisor},
      id: store
    )

    assert {:ok, task_id} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "no status cb"},
               name: store
             )

    assert_receive {:configured_executor, runner_pid, "agent_1", _task, _context}

    assert {:ok, status} = TaskStore.status(task_id, name: store)
    assert status.state == :running
    assert status.current_step == "running"
    assert status.waiting_on == nil

    send(runner_pid, {:finish, {:ok, %{result_type: :test, payload: %{}, raw: "ok"}}})

    # Error from task_status also falls back.
    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => CodingChangeExecutor
    })

    Application.put_env(:arbor_agent, :task_store_test_progress, {:error, :busy})

    unique2 = System.unique_integer([:positive])
    store2 = Module.concat(__MODULE__, :"StatusErrStore#{unique2}")

    start_supervised!(
      {TaskStore, name: store2, task_supervisor: supervisor},
      id: store2
    )

    assert {:ok, task_id2} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "status error"},
               name: store2
             )

    assert_receive {:configured_executor, runner_pid2, "agent_1", _task, _context}
    assert {:ok, status2} = TaskStore.status(task_id2, name: store2)
    assert status2.current_step == "running"
    assert status2.waiting_on == nil
    send(runner_pid2, {:finish, {:ok, %{result_type: :test, payload: %{}, raw: "ok"}}})
  end

  test "cancel invokes cancel_task/2 before turn bridge and hard kill", %{
    supervisor: supervisor
  } do
    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => CodingChangeExecutor
    })

    unique = System.unique_integer([:positive])
    store = Module.concat(__MODULE__, :"CancelOrderStore#{unique}")
    test_pid = self()

    cancel_turn = fn agent_id, cancelled_task_id ->
      send(test_pid, {:cancel_turn_hook, agent_id, cancelled_task_id})
      :ok
    end

    start_supervised!(
      {TaskStore, name: store, task_supervisor: supervisor, cancel_turn: cancel_turn},
      id: store
    )

    assert {:ok, task_id} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "cancel me"},
               name: store,
               task_id: "task_cancel_order",
               approval_answer_cap_id: "cap_cancel_order",
               approval_answer_revoke: revoke_to(test_pid)
             )

    assert_receive {:configured_executor, runner_pid, "agent_1", _task, context}
    ref = Process.monitor(runner_pid)

    assert {:ok, status} = TaskStore.cancel(task_id, name: store)
    assert status.state == :cancelled

    assert_receive {:cancel_task_called, "agent_1", ^context, _from}
    assert_receive {:cancel_turn_hook, "agent_1", ^task_id}
    assert_receive {:DOWN, ^ref, :process, ^runner_pid, :killed}
    assert_receive {:revoke_approval_answer_capability, "cap_cancel_order"}
  end

  test "cancel still completes when cancel_task/2 errors or exits", %{supervisor: supervisor} do
    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => CodingChangeExecutor
    })

    for mode <- [:error, :raise, :exit] do
      Application.put_env(:arbor_agent, :task_store_test_cancel, mode)

      unique = System.unique_integer([:positive])
      store = Module.concat(__MODULE__, :"CancelTolStore#{unique}_#{mode}")

      start_supervised!(
        {TaskStore, name: store, task_supervisor: supervisor},
        id: store
      )

      assert {:ok, task_id} =
               TaskStore.dispatch(
                 "agent_1",
                 %{"kind" => "coding_change", "input" => "cancel #{mode}"},
                 name: store
               )

      assert_receive {:configured_executor, runner_pid, "agent_1", _task, _context}
      ref = Process.monitor(runner_pid)

      assert {:ok, status} = TaskStore.cancel(task_id, name: store)
      assert status.state == :cancelled
      assert_receive {:cancel_task_called, "agent_1", _context, _from}
      assert_receive {:DOWN, ^ref, :process, ^runner_pid, :killed}
      assert {:error, :cancelled} = TaskStore.result(task_id, name: store)
    end
  end

  test "hung task_status/2 and cancel_task/2 are bounded and cancel still completes", %{
    supervisor: supervisor
  } do
    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => CodingChangeExecutor
    })

    callback_timeout_ms = 80
    bound_ms = 500

    unique = System.unique_integer([:positive])
    store = Module.concat(__MODULE__, :"HangCbStore#{unique}")

    start_supervised!(
      {TaskStore,
       name: store, task_supervisor: supervisor, executor_callback_timeout_ms: callback_timeout_ms},
      id: store
    )

    Application.put_env(:arbor_agent, :task_store_test_progress, :hang)

    assert {:ok, task_id} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "hang callbacks"},
               name: store,
               task_id: "task_hang_cb"
             )

    assert_receive {:configured_executor, runner_pid, "agent_1", _task, _context}
    ref = Process.monitor(runner_pid)

    # Status must return within a bounded interval with the stored view.
    status_started = System.monotonic_time(:millisecond)
    assert {:ok, status} = TaskStore.status(task_id, name: store)
    status_elapsed = System.monotonic_time(:millisecond) - status_started

    assert status.state == :running
    assert status.current_step == "running"
    assert status.waiting_on == nil
    assert status_elapsed < bound_ms
    assert_receive {:task_status_called, "agent_1", %{"task_id" => "task_hang_cb"}, _from}

    # Cancel must return within a bounded interval despite hung cancel_task/2.
    Application.put_env(:arbor_agent, :task_store_test_cancel, :hang)
    cancel_started = System.monotonic_time(:millisecond)
    assert {:ok, cancelled} = TaskStore.cancel(task_id, name: store)
    cancel_elapsed = System.monotonic_time(:millisecond) - cancel_started

    assert cancelled.state == :cancelled
    assert cancel_elapsed < bound_ms
    assert_receive {:cancel_task_called, "agent_1", _context, _from}
    assert_receive {:DOWN, ^ref, :process, ^runner_pid, :killed}
    assert {:error, :cancelled} = TaskStore.result(task_id, name: store)
  end

  test "callback absence on cancel falls back to turn bridge and kill", %{
    supervisor: supervisor
  } do
    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => StatusOnlyExecutor
    })

    unique = System.unique_integer([:positive])
    store = Module.concat(__MODULE__, :"NoCancelCbStore#{unique}")
    test_pid = self()

    cancel_turn = fn agent_id, cancelled_task_id ->
      send(test_pid, {:cancel_turn_hook, agent_id, cancelled_task_id})
      :ok
    end

    start_supervised!(
      {TaskStore, name: store, task_supervisor: supervisor, cancel_turn: cancel_turn},
      id: store
    )

    assert {:ok, task_id} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "no cancel cb"},
               name: store
             )

    assert_receive {:configured_executor, runner_pid, "agent_1", _task, _context}
    ref = Process.monitor(runner_pid)

    assert {:ok, status} = TaskStore.status(task_id, name: store)
    assert status.current_step == "reviewing"
    assert status.waiting_on == "human"

    assert {:ok, cancelled} = TaskStore.cancel(task_id, name: store)
    assert cancelled.state == :cancelled
    refute_received {:cancel_task_called, _, _, _}
    assert_receive {:cancel_turn_hook, "agent_1", ^task_id}
    assert_receive {:DOWN, ^ref, :process, ^runner_pid, :killed}
  end

  test "explicit runner overrides skip cross-library progress and cancel callbacks", %{
    store: store
  } do
    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => CodingChangeExecutor
    })

    Application.put_env(:arbor_agent, :task_store_test_progress, %{
      "current_step" => "should_not_apply"
    })

    assert {:ok, task_id} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "override"},
               name: store,
               runner: ControlledRunner,
               test_pid: self()
             )

    assert_receive {:runner_started, runner_pid, "agent_1",
                    %{"kind" => "coding_change", "input" => "override"}, _opts}

    assert {:ok, status} = TaskStore.status(task_id, name: store)
    assert status.current_step == "running"
    refute_received {:task_status_called, _, _, _}

    assert {:ok, cancelled} = TaskStore.cancel(task_id, name: store)
    assert cancelled.state == :cancelled
    refute_received {:cancel_task_called, _, _, _}
    refute Process.alive?(runner_pid)
  end

  test "unknown blank malformed and invalid executors fail closed before spawn", %{
    store: store,
    supervisor: supervisor
  } do
    Application.delete_env(:arbor_agent, :task_executors)

    # Unknown kind: no spawn (a runner override would swallow this, so use a production store).
    unique = System.unique_integer([:positive])
    prod_store = Module.concat(__MODULE__, :"ProdStore#{unique}")

    start_supervised!(
      {TaskStore, name: prod_store, task_supervisor: supervisor},
      id: prod_store
    )

    assert {:error, {:unsupported_task_kind, "unknown_kind"}} =
             TaskStore.dispatch("agent_1", %{"kind" => "unknown_kind", "input" => "x"},
               name: prod_store
             )

    assert {:error, :blank_task_kind} =
             TaskStore.dispatch("agent_1", %{"kind" => "  ", "input" => "x"}, name: prod_store)

    assert {:error, :invalid_task_kind} =
             TaskStore.dispatch("agent_1", %{"kind" => 99, "input" => "x"}, name: prod_store)

    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => NoRunModule
    })

    assert {:error, {:invalid_task_executor, "coding_change", NoRunModule}} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "x"},
               name: prod_store
             )

    # Store-level runner override remains a compatibility seam (does not fail closed).
    assert {:ok, _task_id} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "coding_change", "input" => "override path"},
               name: store,
               test_pid: self()
             )

    assert_receive {:runner_started, _pid, "agent_1",
                    %{"kind" => "coding_change", "input" => "override path"}, _opts}

    # Per-dispatch runner override also wins.
    assert {:ok, _task_id} =
             TaskStore.dispatch(
               "agent_1",
               %{"kind" => "still_unknown", "input" => "dispatch override"},
               name: prod_store,
               runner: ControlledRunner,
               test_pid: self()
             )

    assert_receive {:runner_started, _pid, "agent_1",
                    %{"kind" => "still_unknown", "input" => "dispatch override"}, _opts}
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    fun.()
  rescue
    error in [ExUnit.AssertionError] ->
      if attempts == 1 do
        reraise error, __STACKTRACE__
      else
        Process.sleep(10)
        assert_eventually(fun, attempts - 1)
      end
  end

  defp get_control(store, task_id, control_id) do
    :sys.get_state(store).tasks[task_id].controls
    |> Enum.find(&(&1["control_id"] == control_id))
  end

  defp fresh_steer_call_counter do
    if :ets.whereis(:steer_call_counter) != :undefined do
      :ets.delete(:steer_call_counter)
    end

    :ets.new(:steer_call_counter, [:set, :public, :named_table])

    on_exit(fn ->
      if :ets.whereis(:steer_call_counter) != :undefined do
        :ets.delete(:steer_call_counter)
      end
    end)

    :ok
  end

  defp steer_call_count_for(control_id) do
    case :ets.lookup(:steer_call_counter, control_id) do
      [{^control_id, count}] -> count
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  # Closed scalar only — cleanup MFA/backends/supervisor are fixed at TaskStore start.
  defp cleanup_descriptor do
    %{
      caller_id: "dispatch_owner",
      trace_id: "trace_cleanup"
    }
  end

  defp revoke_to(test_pid) do
    fn capability_id ->
      send(test_pid, {:revoke_approval_answer_capability, capability_id})
      :ok
    end
  end

  defp revoke_steer_to(test_pid) do
    fn capability_id ->
      send(test_pid, {:revoke_steer_capability, capability_id})
      :ok
    end
  end

  defp revoke_adoption_to(test_pid) do
    fn capability_id ->
      send(test_pid, {:revoke_adoption_capability, capability_id})
      :ok
    end
  end

  defp task_outcome do
    %{
      "version" => 1,
      "disposition" => "succeeded",
      "code" => "implemented",
      "phase" => "worker_turn",
      "origin" => "worker",
      "retry" => "none",
      "message" => "completed"
    }
  end

  defp registered_outcome(code) do
    {:ok, outcome} = TaskOutcome.from_code(code)
    TaskOutcome.to_map(outcome)
  end

  defp coding_artifacts do
    %{
      "coding_plan_path" => "/tmp/plan.json",
      "coding_pipeline_path" => "/tmp/pipeline.dot",
      "compile_manifest_path" => "/tmp/manifest.json",
      "compiler_version" => "1",
      "graph_hash" => String.duplicate("b", 64)
    }
  end

  defp subscribe_to_task_steering_transitions(task_id) do
    test_pid = self()
    ensure_signals_started()

    {:ok, subscription_id} =
      Arbor.Signals.subscribe(
        "agent.task_steering_transition",
        fn signal ->
          if signal.data[:task_id] == task_id do
            send(test_pid, {:task_steering_transition, signal.data})
          end

          :ok
        end,
        async: false
      )

    on_exit(fn ->
      if Process.whereis(Arbor.Signals.Bus) do
        Arbor.Signals.unsubscribe(subscription_id)
      end
    end)

    :ok
  end

  defp ensure_signals_started do
    if Process.whereis(Arbor.Signals.Store) == nil do
      start_supervised!({Arbor.Signals.Store, []})
    end

    if Process.whereis(Arbor.Signals.Bus) == nil do
      start_supervised!({Arbor.Signals.Bus, []})
    end
  end

  defp start_configured_steering_store(supervisor, opts \\ []) do
    store = Module.concat(__MODULE__, :"SteeringStore#{System.unique_integer([:positive])}")
    Application.put_env(:arbor_agent, :default_task_executor, SteeringExecutor)

    final_opts =
      [name: store, task_supervisor: supervisor, steer_confirmation_delay_ms: 10_000]
      |> Keyword.merge(opts)

    start_supervised!({TaskStore, final_opts}, id: store)
    store
  end

  defp start_finalizing_store(supervisor, opts \\ []) do
    store = Module.concat(__MODULE__, :"FinalizingStore#{System.unique_integer([:positive])}")

    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => FinalizingExecutor
    })

    final_opts =
      [name: store, task_supervisor: supervisor, steer_confirmation_delay_ms: 10_000]
      |> Keyword.merge(opts)

    start_supervised!({TaskStore, final_opts}, id: store)
    store
  end

  defp start_all_terminal_store(supervisor, opts \\ []) do
    store = Module.concat(__MODULE__, :"AllTerminalStore#{System.unique_integer([:positive])}")

    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => AllTerminalExecutor
    })

    final_opts =
      [name: store, task_supervisor: supervisor, steer_confirmation_delay_ms: 10_000]
      |> Keyword.merge(opts)

    start_supervised!({TaskStore, final_opts}, id: store)
    store
  end

  defp start_dual_finalizing_store(supervisor, opts \\ []) do
    store = Module.concat(__MODULE__, :"DualFinalizingStore#{System.unique_integer([:positive])}")

    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => DualFinalizingExecutor
    })

    final_opts =
      [name: store, task_supervisor: supervisor, steer_confirmation_delay_ms: 10_000]
      |> Keyword.merge(opts)

    start_supervised!({TaskStore, final_opts}, id: store)
    store
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_agent, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_agent, key, value)
end
