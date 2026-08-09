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

  # Representative string-keyed Orchestrator readiness nesting with nested
  # readiness + authority_horizon maps (measured production shape).
  defp real_orchestrator_readiness_fixture(status \\ "ready") do
    %{
      "version" => 1,
      "kind" => "coding_dispatch_readiness",
      "status" => status,
      "observed_at" => "2026-08-09T00:00:00.000000Z",
      "agent_id" => "agent_target1",
      "plan_digest" => "sha256:" <> String.duplicate("ab", 32),
      "budget" => %{
        "effective_wall_clock_ms" => 900_000,
        "cleanup_reserve_ms" => 30_000,
        "run_deadline_unix_ms" => 1_725_000_000_000,
        "horizon_unix_ms" => 1_724_999_970_000
      },
      "readiness" => %{
        "version" => 1,
        "status" => status,
        "plan_digest" => "sha256:" <> String.duplicate("ab", 32),
        "observed_at" => "2026-08-09T00:00:00.000000Z",
        "diagnostics" => [
          %{
            "version" => 1,
            "gate_id" => "provider_readiness",
            "phase" => "preflight",
            "decision" => if(status == "ready", do: "passed", else: "degraded"),
            "code" => "provider_ok",
            "observed_at" => "2026-08-09T00:00:00.000000Z",
            "message" => "provider is available"
          }
        ]
      },
      "execution_boundary" => %{"status" => "verified", "code" => nil},
      "authority_horizon" => %{
        "version" => 1,
        "kind" => "authority_horizon_projection",
        "status" => "ready",
        "observed_at" => "2026-08-09T00:00:00.000000Z",
        "scope" => %{
          "mode" => "future_task",
          "task_id" => nil,
          "session_id" => nil
        },
        "horizon" => %{
          "run_deadline_unix_ms" => 1_725_000_000_000,
          "cleanup_reserve_ms" => 30_000,
          "horizon_unix_ms" => 1_724_999_970_000
        },
        "principals" => [
          %{"role" => "execution", "principal_id" => "agent_target1"}
        ],
        "required_resources" => ["arbor://fs/read/", "arbor://shell/exec/git"],
        "findings" => [
          %{
            "principal_role" => "execution",
            "classification" => "ready",
            "total_count" => 0,
            "resource_uris" => [],
            "resource_uris_digest" => "sha256:" <> String.duplicate("00", 32)
          }
        ],
        "summary" => %{
          "missing_n" => 0,
          "expiring_n" => 0,
          "findings_digest" => "sha256:" <> String.duplicate("11", 32)
        },
        "error" => nil
      },
      "error" => nil
    }
  end

  test "composes ready when all planes are ready" do
    assert {:ok, report} = Core.compose(base_facts())
    assert report["status"] == "ready"
    assert report["kind"] == "agent_coding_dispatch_readiness"
    assert report["version"] == 1
    assert report["error"] == nil
    assert {:ok, ^report} = Core.assert_report(report)
  end

  test "real orchestrator readiness shape composes with nested evidence retained" do
    fixture = real_orchestrator_readiness_fixture("ready")

    executor =
      Core.project_executor(%{
        kind: "coding_change",
        callback_present?: true,
        projection: fixture,
        diagnostic: nil
      })

    assert executor["status"] == "ready"
    nested = executor["details"]["projection"]
    assert nested["status"] == "ready"
    assert is_map(nested["readiness"])
    assert nested["readiness"]["status"] == "ready"
    assert is_map(nested["authority_horizon"])
    assert nested["authority_horizon"]["status"] == "ready"
    assert is_list(nested["authority_horizon"]["findings"])
    assert nested["budget"]["effective_wall_clock_ms"] == 900_000

    assert {:ok, report} = Core.compose(base_facts(%{executor: executor}))
    assert report["status"] == "ready"
    assert {:ok, _} = Core.assert_report(report)

    retained = report["planes"]["executor"]["details"]["projection"]
    assert retained["readiness"]["diagnostics"] != nil
    assert retained["authority_horizon"]["horizon"]["cleanup_reserve_ms"] == 30_000
  end

  test "real orchestrator degraded readiness yields top-level degraded" do
    fixture = real_orchestrator_readiness_fixture("degraded")

    executor =
      Core.project_executor(%{
        kind: "coding_change",
        callback_present?: true,
        projection: fixture,
        diagnostic: nil
      })

    assert executor["status"] == "degraded"
    assert {:ok, report} = Core.compose(base_facts(%{executor: executor}))
    assert report["status"] == "degraded"
    assert report["planes"]["executor"]["details"]["projection"]["readiness"]["status"] ==
             "degraded"
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

  test "tuple and non-string keys are rejected without raising or status laundering" do
    assert {:error, "executor_non_json", _} =
             Core.validate_and_bound_executor_report(%{{:tuple, :key} => "x", "status" => "ready"})

    assert {:error, "executor_non_json", _} =
             Core.validate_and_bound_executor_report(%{1 => "x", "status" => "ready"})

    assert {:error, "executor_non_json", _} =
             Core.validate_and_bound_executor_report(%{self() => "x", "status" => "ready"})

    executor =
      Core.project_executor(%{
        kind: "coding_change",
        callback_present?: true,
        projection: %{{:a, :b} => "v", "status" => "ready"},
        diagnostic: nil
      })

    assert executor["status"] == "error"
    assert executor["code"] == "executor_non_json"
    refute executor["status"] == "ready"
  end

  test "overlong valid UTF-8 map key is rejected rather than truncated" do
    overlong_key = String.duplicate("k", Core.max_key_bytes() + 1)

    assert {:error, "executor_non_json", _} =
             Core.validate_and_bound_executor_report(%{
               "status" => "ready",
               overlong_key => "value"
             })
  end

  test "invalid UTF-8 is rejected without raising" do
    invalid = <<0xFF, 0xFE>>

    assert {:error, "executor_non_json", _} =
             Core.validate_and_bound_executor_report(%{
               "status" => "ready",
               "bad" => invalid
             })

    assert {:error, "executor_non_json", _} =
             Core.validate_and_bound_executor_report(%{
               "status" => "ready",
               invalid => "x"
             })
  end

  test "oversized top-level strings are bounded" do
    long = String.duplicate("a", 2_000)

    assert {:ok, report} =
             Core.compose(
               base_facts(%{
                 agent_id: long,
                 caller_id: long,
                 observed_at: long
               })
             )

    assert byte_size(report["agent_id"]) <= 512
    assert byte_size(report["caller_id"]) <= 512
    assert byte_size(report["observed_at"]) <= 512
    assert {:ok, _} = Core.assert_report(report)
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

  test "aggregate accepts known wrapper overhead while executor depth stays strict" do
    # max_executor_depth nestings: deepest map at depth max-1 (still valid).
    deep =
      Enum.reduce(1..Core.max_executor_depth(), "leaf", fn _, acc ->
        %{"nested" => acc}
      end)

    projection = Map.put(deep, "status", "ready")

    assert {:ok, _bounded, "ready"} = Core.validate_and_bound_executor_report(projection)

    executor =
      Core.project_executor(%{
        kind: "coding_change",
        callback_present?: true,
        projection: projection,
        diagnostic: nil
      })

    assert executor["status"] == "ready"
    assert {:ok, report} = Core.compose(base_facts(%{executor: executor}))
    assert report["status"] == "ready"
    assert {:ok, _} = Core.assert_report(report)

    # One more nesting level fails at the executor boundary (not the aggregate).
    too_deep =
      %{"nested" => deep, "status" => "ready"}

    assert {:error, "executor_non_json", _} =
             Core.validate_and_bound_executor_report(too_deep)
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

  test "current requires closed source provenance and fails closed without it" do
    with_source =
      Core.project_exact_template(%{
        template_state: "current",
        template_name: "pipeline_architect",
        managed: true,
        stored_digest_present: true,
        digest_match: true,
        source_layer: "shipped"
      })

    assert with_source["status"] == "ready"
    assert with_source["details"]["template_state"] == "current"
    assert with_source["details"]["source_layer"] == "shipped"

    missing =
      Core.project_exact_template(%{
        template_state: "current",
        template_name: "pipeline_architect",
        managed: true,
        stored_digest_present: true,
        digest_match: true,
        source_layer: nil
      })

    assert missing["status"] == "blocked"
    assert missing["details"]["template_state"] == "invalid"
    refute missing["details"]["template_state"] == "current"

    unknown =
      Core.project_exact_template(%{
        template_state: "current",
        template_name: "pipeline_architect",
        managed: true,
        stored_digest_present: true,
        digest_match: true,
        source_layer: "mystery"
      })

    assert unknown["status"] == "blocked"
    assert unknown["details"]["template_state"] == "invalid"
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

  test "recovery projection failure is error not blocked" do
    plane =
      Core.project_task_control(%{
        facts_available?: true,
        recovery_ready?: false,
        recovery_facts_ok?: false,
        quota_enforcement_enabled?: true,
        principal_indexed_count: 0,
        active_capabilities: 0,
        max_per_principal: 100,
        max_global: 1000
      })

    assert plane["status"] == "error"
    assert plane["code"] == "recovery_projection_failed"
  end

  test "coordinator absent blocks; projection failure is error" do
    absent = Core.project_coordinator(%{host_state: "absent"})
    assert absent["status"] == "blocked"
    assert absent["code"] == "coordinator_absent"

    failed = Core.project_coordinator(%{host_state: "error"})
    assert failed["status"] == "error"
    assert failed["code"] == "coordinator_projection_failed"
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

  test "executor diagnostic timeout and raise map to error not blocked" do
    timeout =
      Core.project_executor(%{
        kind: "coding_change",
        callback_present?: true,
        projection: nil,
        diagnostic: %{
          "code" => "executor_callback_timeout",
          "message" => "executor readiness callback timed out"
        }
      })

    assert timeout["status"] == "error"
    assert timeout["code"] == "executor_callback_timeout"

    raised =
      Core.project_executor(%{
        kind: "coding_change",
        callback_present?: true,
        projection: nil,
        diagnostic: %{
          "code" => "executor_callback_exception",
          "message" => "executor readiness callback raised"
        }
      })

    assert raised["status"] == "error"
  end
end
