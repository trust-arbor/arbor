defmodule Arbor.Agent.Orchestration.TaskRunBindingCoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Agent.Orchestration.{TaskControlLease, TaskRunBindingCore}

  test "v1 markers are orphans" do
    {:ok, marker} = TaskControlLease.marker_new("task_a", DateTime.utc_now())
    assert TaskRunBindingCore.classify(marker) == :orphan
  end

  test "v2 coding markers are candidates without executor lookup" do
    {:ok, marker} =
      TaskControlLease.marker_new("task_b", DateTime.utc_now(), %{
        agent_id: "agent_target",
        executor_kind: "coding_change",
        control_principal_id: "caller_1",
        cleanup: %{"caller_id" => "caller_1", "principal_id" => "agent_target"}
      })

    assert TaskRunBindingCore.classify(marker) == :v2_candidate
  end

  test "rehydrate CAS includes the binding digest" do
    {:ok, marker} =
      TaskControlLease.marker_new("task_c", DateTime.utc_now(), %{
        agent_id: "agent_target",
        executor_kind: "coding_change",
        control_principal_id: "caller_1",
        cleanup: %{"caller_id" => "caller_1", "principal_id" => "agent_target"}
      })

    digest = String.duplicate("a", 64)
    assert {:ok, cas} = TaskRunBindingCore.rehydrate_cas(marker, digest)
    assert byte_size(cas) == 64

    other = String.duplicate("b", 64)
    assert {:ok, other_cas} = TaskRunBindingCore.rehydrate_cas(marker, other)
    refute cas == other_cas
  end

  test "cleanup descriptor is closed scalars" do
    {:ok, marker} =
      TaskControlLease.marker_new("task_d", DateTime.utc_now(), %{
        agent_id: "agent_target",
        executor_kind: "coding_change",
        control_principal_id: "caller_1",
        cleanup: %{
          "caller_id" => "caller_1",
          "principal_id" => "agent_target",
          "trace_id" => "tr_1"
        }
      })

    assert TaskRunBindingCore.cleanup_descriptor(marker) == %{
             caller_id: "caller_1",
             principal_id: "agent_target",
             trace_id: "tr_1"
           }
  end

  test "join_probe exact-matches marker identity fields" do
    {:ok, marker} =
      TaskControlLease.marker_new("task_join", DateTime.utc_now(), %{
        agent_id: "agent_target",
        executor_kind: "coding_change",
        control_principal_id: "caller_1",
        cleanup: %{"caller_id" => "caller_1", "principal_id" => "agent_target"}
      })

    digest = String.duplicate("a", 64)

    projection = %{
      "schema_version" => 1,
      "task_id" => "task_join",
      "run_id" => "task_join",
      "agent_id" => "agent_target",
      "execution_principal" => "agent_target",
      "control_principal_id" => "caller_1",
      "executor_kind" => "coding_change",
      "graph_hash" => digest,
      "artifact_identity" => digest,
      "binding_digest" => digest
    }

    assert {:ok, cas} = TaskRunBindingCore.join_probe(marker, projection)
    assert byte_size(cas) == 64

    assert {:error, :orphan} =
             TaskRunBindingCore.join_probe(
               marker,
               Map.put(projection, "control_principal_id", "other")
             )

    assert {:error, :orphan} =
             TaskRunBindingCore.join_probe(
               marker,
               Map.put(projection, "graph_hash", "not-a-digest")
             )

    assert {:error, :orphan} =
             TaskRunBindingCore.join_probe(
               marker,
               Map.put(projection, "artifact_identity", "not-a-digest")
             )

    assert {:error, :orphan} =
             TaskRunBindingCore.join_probe(
               marker,
               Map.put(projection, "executor_kind", "other_kind")
             )
  end

  test "admit_cas covers running, terminal, and catch-all states" do
    cas = String.duplicate("a", 64)
    other = String.duplicate("b", 64)

    assert {:spawn, ^cas} = TaskRunBindingCore.admit_cas(nil, cas)
    assert :idempotent = TaskRunBindingCore.admit_cas(%{state: :running, recovery_cas: cas}, cas)

    assert {:error, :recovery_cas_conflict} =
             TaskRunBindingCore.admit_cas(%{state: :running, recovery_cas: other}, cas)

    assert :idempotent = TaskRunBindingCore.admit_cas(%{state: :done, recovery_cas: cas}, cas)

    assert {:error, :stale_or_duplicate_terminal} =
             TaskRunBindingCore.admit_cas(%{state: :done, recovery_cas: other}, cas)

    assert {:error, :not_admitted} =
             TaskRunBindingCore.admit_cas(%{state: :waiting_approval, recovery_cas: cas}, cas)

    assert {:error, :not_admitted} = TaskRunBindingCore.admit_cas(:malformed, cas)
    assert {:error, :not_admitted} = TaskRunBindingCore.admit_cas(%{state: :running}, "short")
  end

  test "admission_action table: spawn, keep conflict/stale, orphan only not_admitted, unknown unavailable" do
    cas = String.duplicate("a", 64)

    assert :spawn = TaskRunBindingCore.admission_action({:spawn, cas})
    assert :keep = TaskRunBindingCore.admission_action(:idempotent)
    assert :keep = TaskRunBindingCore.admission_action({:error, :recovery_cas_conflict})
    assert :keep = TaskRunBindingCore.admission_action({:error, :stale_or_duplicate_terminal})
    assert :orphan = TaskRunBindingCore.admission_action({:error, :not_admitted})
    assert :unavailable = TaskRunBindingCore.admission_action({:error, :unexpected_future_reason})
    assert :unavailable = TaskRunBindingCore.admission_action(:not_a_cas_decision)
  end
end
