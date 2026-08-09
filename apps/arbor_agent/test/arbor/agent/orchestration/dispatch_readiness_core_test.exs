defmodule Arbor.Agent.Orchestration.DispatchReadinessCoreTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.Orchestration.DispatchReadinessCore, as: Core

  defp ready_plane(details \\ %{}) do
    Core.plane("ready", nil, nil, details)
  end

  defp base_facts(overrides \\ %{}) do
    Map.merge(
      %{
        observed_at: "2026-08-09T00:00:00Z",
        agent_id: "agent_target1",
        caller_id: "human_caller1",
        security: ready_plane(%{"healthy" => true}),
        coordinator: ready_plane(%{"host_state" => "running"}),
        exact_template: ready_plane(%{"template_state" => "current"}),
        task_control: ready_plane(%{"recovery_ready" => true}),
        executor: ready_plane(%{"callback_present" => true})
      },
      overrides
    )
  end

  test "composes ready when all planes are ready" do
    assert {:ok, report} = Core.compose(base_facts())
    assert report["status"] == "ready"
    assert report["kind"] == "agent_coding_dispatch_readiness"
    assert report["version"] == 1
    assert report["error"] == nil
    assert {:ok, ^report} = Core.assert_report(report)
  end

  test "nested executor degraded yields top-level degraded" do
    executor =
      Core.project_executor(%{
        kind: "coding_change",
        callback_present?: true,
        projection: %{"status" => "degraded", "kind" => "coding_dispatch_readiness"},
        diagnostic: nil
      })

    assert executor["status"] == "degraded"
    assert {:ok, report} = Core.compose(base_facts(%{executor: executor}))
    assert report["status"] == "degraded"
  end

  test "executor blocked plane blocks top-level" do
    executor =
      Core.project_executor(%{
        kind: "coding_change",
        callback_present?: true,
        projection: %{"status" => "blocked"},
        diagnostic: nil
      })

    assert {:ok, report} = Core.compose(base_facts(%{executor: executor}))
    assert report["status"] == "blocked"
  end

  test "executor report without status is error, not ready" do
    executor =
      Core.project_executor(%{
        kind: "coding_change",
        callback_present?: true,
        projection: %{"kind" => "coding_dispatch_readiness", "ok" => true},
        diagnostic: nil
      })

    assert executor["status"] == "error"
    assert executor["code"] == "executor_status_missing"
    assert executor["details"]["projection"] == nil
  end

  test "executor report with unknown status is error" do
    executor =
      Core.project_executor(%{
        kind: "coding_change",
        callback_present?: true,
        projection: %{"status" => "kinda_ready"},
        diagnostic: nil
      })

    assert executor["status"] == "error"
    assert executor["code"] == "executor_status_invalid"
  end

  test "executor non-JSON (atom keys, pids, tuples) is error and is not laundered" do
    executor =
      Core.project_executor(%{
        kind: "coding_change",
        callback_present?: true,
        projection: %{:atom_key => self(), "tuple" => {:a, :b}},
        diagnostic: nil
      })

    assert executor["status"] == "error"
    assert executor["code"] == "executor_non_json"
    assert executor["details"]["projection"] == nil
  end

  test "executor excessive depth is error, not truncated to ready" do
    deep =
      Enum.reduce(1..12, "leaf", fn _, acc ->
        %{"nested" => acc}
      end)

    projection = Map.put(deep, "status", "ready")

    executor =
      Core.project_executor(%{
        kind: "coding_change",
        callback_present?: true,
        projection: projection,
        diagnostic: nil
      })

    assert executor["status"] == "error"
    assert executor["code"] == "executor_non_json"
  end

  test "validate_and_bound_executor_report preserves status after bounding" do
    long = String.duplicate("x", 2_000)

    assert {:ok, bounded, "ready"} =
             Core.validate_and_bound_executor_report(%{
               "status" => "ready",
               "note" => long
             })

    assert bounded["status"] == "ready"
    assert byte_size(bounded["note"]) <= 1_024
  end

  test "utf8_truncate does not split multibyte characters" do
    # "é" is 2 bytes; truncating to 3 bytes must keep one full grapheme only.
    assert Core.utf8_truncate("ééé", 3) == "é"
    assert String.valid?(Core.utf8_truncate("ééé", 3))
  end

  test "map bounding is deterministic by sorted keys" do
    # More than max_map_keys (64) so truncation order is observable.
    oversized =
      1..80
      |> Enum.reduce(%{"status" => "ready"}, fn i, acc ->
        Map.put(acc, "k#{String.pad_leading(Integer.to_string(i), 3, "0")}", i)
      end)

    assert {:ok, left, "ready"} = Core.validate_and_bound_executor_report(oversized)
    assert {:ok, right, "ready"} = Core.validate_and_bound_executor_report(oversized)
    assert left == right
    # Truncation is deterministic; status is re-asserted after bounding.
    assert left["status"] == "ready"
    assert map_size(left) <= 65
    assert map_size(left) >= 64
  end

  test "exact-template drift blocks" do
    plane =
      Core.project_exact_template(%{
        template_state: "drifted",
        template_name: "pipeline_architect",
        managed: true,
        stored_digest_present: true,
        digest_match: false,
        source_layer: "shipped"
      })

    assert plane["status"] == "blocked"
    assert {:ok, report} = Core.compose(base_facts(%{exact_template: plane}))
    assert report["status"] == "blocked"
  end

  test "unmanaged exact template degrades without blocking" do
    plane =
      Core.project_exact_template(%{
        template_state: "unmanaged",
        template_name: "conversationalist",
        managed: false,
        stored_digest_present: false,
        digest_match: nil,
        source_layer: nil
      })

    assert plane["status"] == "degraded"
    assert {:ok, report} = Core.compose(base_facts(%{exact_template: plane}))
    assert report["status"] == "degraded"
  end

  test "security recovery failure blocks" do
    plane =
      Core.project_security(%{
        facts_available?: true,
        healthy?: false,
        restore_status: "failed",
        restore_scanned: 0,
        restore_active: 0,
        restore_expired: 0,
        restore_superseded: 0,
        restore_rejected: 0,
        quota_enforcement_enabled?: true,
        active_capabilities: 0,
        max_global: 100,
        max_per_principal: 50,
        principal_indexed_count: 0
      })

    assert plane["status"] == "blocked"
    assert {:ok, report} = Core.compose(base_facts(%{security: plane}))
    assert report["status"] == "blocked"
  end

  test "unavailable security facts fail closed" do
    plane =
      Core.project_security(%{
        facts_available?: false,
        healthy?: true,
        restore_status: "unavailable",
        quota_enforcement_enabled?: :unavailable,
        active_capabilities: :unavailable,
        max_global: :unavailable,
        max_per_principal: :unavailable,
        principal_indexed_count: :unavailable
      })

    assert plane["status"] == "blocked"
    assert plane["code"] == "security_facts_unavailable"
  end

  test "missing quota enforcement fails closed; only explicit false bypasses" do
    missing =
      Core.project_task_control(%{
        facts_available?: true,
        recovery_ready?: true,
        quota_enforcement_enabled?: :unavailable,
        principal_indexed_count: 0,
        active_capabilities: 0,
        max_per_principal: 100,
        max_global: 1000
      })

    assert missing["status"] == "blocked"
    assert missing["code"] == "quota_enforcement_unavailable"

    bypassed =
      Core.project_task_control(%{
        facts_available?: true,
        recovery_ready?: true,
        quota_enforcement_enabled?: false,
        principal_indexed_count: :unavailable,
        active_capabilities: :unavailable,
        max_per_principal: :unavailable,
        max_global: :unavailable
      })

    assert bypassed["status"] == "ready"
    assert bypassed["details"]["quota"]["sufficient_for_lease"] == true
  end

  test "unavailable principal indexed count fails closed" do
    plane =
      Core.project_task_control(%{
        facts_available?: true,
        recovery_ready?: true,
        quota_enforcement_enabled?: true,
        principal_indexed_count: :unavailable,
        active_capabilities: 0,
        max_per_principal: 100,
        max_global: 1000
      })

    assert plane["status"] == "blocked"
    assert plane["code"] == "principal_quota_count_unavailable"
  end

  test "task-control recovery-not-ready blocks all six members" do
    plane =
      Core.project_task_control(%{
        facts_available?: true,
        recovery_ready?: false,
        quota_enforcement_enabled?: true,
        principal_indexed_count: 0,
        active_capabilities: 0,
        max_per_principal: 100,
        max_global: 1000
      })

    assert plane["status"] == "blocked"
    assert plane["details"]["recovery_ready"] == false

    for role <- Core.lease_roles() do
      assert plane["details"]["members"][role]["provisionable"] == false
      assert plane["details"]["members"][role]["code"] == "recovery_not_ready"
      refute Map.has_key?(plane["details"]["members"][role], "id")
    end
  end

  test "quota uses principal_indexed_count + 6 and active_capabilities + 6" do
    plane =
      Core.project_task_control(%{
        facts_available?: true,
        recovery_ready?: true,
        quota_enforcement_enabled?: true,
        principal_indexed_count: 5,
        active_capabilities: 0,
        max_per_principal: 10,
        max_global: 1000
      })

    assert plane["status"] == "blocked"
    assert plane["details"]["quota"]["sufficient_for_lease"] == false
    assert plane["code"] == "quota_insufficient_principal"

    ready =
      Core.project_task_control(%{
        facts_available?: true,
        recovery_ready?: true,
        quota_enforcement_enabled?: true,
        principal_indexed_count: 4,
        active_capabilities: 10,
        max_per_principal: 10,
        max_global: 1000
      })

    assert ready["status"] == "ready"
    assert ready["details"]["quota"]["sufficient_for_lease"] == true

    for role <- Core.lease_roles() do
      assert ready["details"]["members"][role]["provisionable"] == true
    end
  end

  test "malformed plane input returns error" do
    assert {:error, :malformed_plane_input} =
             Core.compose(base_facts(%{security: %{"status" => "ready"}}))
  end

  test "reports are recursive string-keyed JSON without atoms or pids" do
    assert {:ok, report} = Core.compose(base_facts())
    assert Core.json_clean?(report)
    refute report |> inspect() |> String.contains?("#PID")
  end

  test "error_report is closed and JSON-clean" do
    report =
      Core.error_report(
        observed_at: "2026-08-09T00:00:00Z",
        agent_id: "agent_x",
        caller_id: "human_y",
        code: "projection_failed",
        message: "dispatch readiness failed closed"
      )

    assert report["status"] == "error"
    assert {:ok, ^report} = Core.assert_report(report)
  end
end
