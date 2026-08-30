defmodule Arbor.Actions.Coding.CrossApp.ProgressCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.CrossApp.EvidenceCore
  alias Arbor.Actions.Coding.CrossApp.Core
  alias Arbor.Actions.Coding.CrossApp.ProgressCore
  alias Arbor.Contracts.Coding.ValidationCapacityHandoff

  @moduletag :fast

  @inv1 String.duplicate("a", 64)
  @inv2 String.duplicate("b", 64)
  @inv3 String.duplicate("e", 64)
  @hex String.duplicate("c", 64)
  @static String.duplicate("d", 64)
  @base_oid String.duplicate("1", 40)
  @base_tree_oid String.duplicate("2", 40)
  @candidate_tree_oid String.duplicate("3", 40)

  test "new/1 constructs in_progress compact progress without plan or remaining suffix" do
    plan = plan()
    {:ok, expected_digest} = ValidationCapacityHandoff.ordered_plan_digest(plan)
    {:ok, identities_digest} = EvidenceCore.digest(identities(plan))
    {:ok, receipts_digest} = EvidenceCore.digest([])
    {:ok, state} = ProgressCore.new(fresh_bindings())

    assert state["schema_version"] == 2
    assert state["refinement"] == nil
    assert state["status"] == "in_progress"
    refute state["status"] == "open"
    assert state["plan_digest"] == expected_digest
    assert state["identities_digest"] == identities_digest
    assert state["total_batch_count"] == 2
    assert state["total_file_count"] == 2
    assert state["passed_receipts"] == []
    assert state["passed_receipts_digest"] == receipts_digest
    assert state["completed_batch_count"] == 0
    assert state["completed_file_count"] == 0
    assert state["next_batch_index"] == 1
    assert state["window_ordinal"] == 0
    assert state["capacity"] == nil
    assert state["static_stage_receipt_digest"] == @static
    refute Map.has_key?(state, "planned_batches")
    refute Map.has_key?(state, "unstarted_batches")
    refute Map.has_key?(state, "claim")

    assert Enum.to_list(state) == Enum.to_list(ProgressCore.show(state))
    assert {:ok, encoded} = Jason.encode(ProgressCore.show(state))
    refute encoded =~ "planned_batches"
    refute encoded =~ "fence_token"
    refute encoded =~ "authority"
  end

  test "whole-stage timeout is terminal infrastructure failure, not source rework" do
    assert {:error, :validation_stage_timeout} =
             ProgressCore.project_failure("validation_stage_timeout")

    assert {:error, :validation_infrastructure_failed} =
             ProgressCore.project_failure("validation_infrastructure_failed")

    assert {:error, :validation_tree_mutated} =
             ProgressCore.project_failure("validation_tree_mutated")

    assert {:ok, domain_failure} = ProgressCore.project_failure("tests_failed")
    assert domain_failure["disposition_type"] == "failed"
    assert domain_failure["passed"] == false
    assert domain_failure["reason"] == "tests_failed"

    assert Enum.sort(Map.keys(domain_failure)) ==
             ~w(disposition_type passed reason schema_version)

    refute Map.has_key?(domain_failure, "feedback_json")
    refute Map.has_key?(domain_failure, "planned_batches")
    refute Map.has_key?(domain_failure, "test_paths")
  end

  test "project_failure admits a bounded check into feedback_json and fails closed on malformed or oversized input" do
    label = "batch-1-of-2-n1-#{@inv1}"

    diagnostic =
      "  1) test value is one (AlphaTest)\n     Assertion with == failed\n     left:  99\n     right: 1"

    check = failure_check(label: label, stdout: diagnostic)
    assert {:ok, projected} = ProgressCore.project_failure("tests_failed", check)
    assert projected["schema_version"] == 1
    assert projected["disposition_type"] == "failed"
    assert projected["passed"] == false
    assert projected["reason"] == "tests_failed"
    assert is_binary(projected["feedback_json"])

    assert byte_size(projected["feedback_json"]) <=
             ProgressCore.limits()["max_failure_feedback_json_bytes"]

    decoded = Jason.decode!(projected["feedback_json"])
    assert Enum.sort(Map.keys(decoded)) == failure_check_keys()
    assert decoded["status"] == "completed"
    assert decoded["passed"] == false
    assert decoded["reason"] == "tests_failed"
    assert decoded["exit_code"] == 1
    assert decoded["stdout_excerpt"] =~ "[#{label}]"
    assert decoded["stdout_excerpt"] =~ "Assertion with == failed"
    assert decoded["stdout_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    assert decoded["stderr_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    assert is_boolean(decoded["stdout_truncated"])
    assert is_boolean(decoded["stderr_truncated"])
    refute Map.has_key?(decoded, "planned_batches")
    refute Map.has_key?(decoded, "test_paths")
    refute Map.has_key?(decoded, "paths")
    refute projected["feedback_json"] =~ "planned_batches"
    refute projected["feedback_json"] =~ "test_paths"
    assert {:ok, _} = Jason.encode(projected)

    assert {:ok, ^projected} = ProgressCore.project_failure("tests_failed", check)

    assert {:error, :malformed_failure_feedback} =
             ProgressCore.project_failure("tests_failed", Map.put(check, "test_paths", ["x"]))

    assert {:error, :malformed_failure_feedback} =
             ProgressCore.project_failure(
               "tests_failed",
               Map.put(check, "planned_batches", [batch(1, 2, 1, @inv1)])
             )

    assert {:error, :malformed_failure_feedback} =
             ProgressCore.project_failure(
               "tests_failed",
               Map.put(check, "extra", %{"nested" => 1})
             )

    assert {:error, :malformed_failure_feedback} =
             ProgressCore.project_failure("tests_failed", Map.put(check, "token", "nope"))

    assert {:error, :malformed_failure_feedback} =
             ProgressCore.project_failure("tests_failed", Map.delete(check, "stdout_sha256"))

    assert {:error, :malformed_failure_feedback} =
             ProgressCore.project_failure("tests_failed", Map.put(check, "passed", true))

    assert {:error, :malformed_failure_feedback} =
             ProgressCore.project_failure("tests_timed_out", check)

    assert {:error, :malformed_failure_feedback} =
             ProgressCore.project_failure("tests_failed", %{})

    assert {:error, :malformed_failure_feedback} =
             ProgressCore.project_failure("tests_failed", [])

    oversized =
      Map.put(check, "stdout_excerpt", String.duplicate("x", Core.max_aggregate_excerpt() + 1))

    assert {:error, :oversized_failure_feedback} =
             ProgressCore.project_failure("tests_failed", oversized)

    assert {:error, :validation_infrastructure_failed} =
             ProgressCore.project_failure("validation_infrastructure_failed", check)

    assert {:error, :validation_tree_mutated} =
             ProgressCore.project_failure("validation_tree_mutated", check)

    assert {:error, :validation_stage_timeout} =
             ProgressCore.project_failure("validation_stage_timeout", check)
  end

  test "admit/2 rehydrates a show/1 snapshot against freshly injected bindings" do
    {:ok, state} = ProgressCore.new(fresh_bindings())
    snapshot = ProgressCore.show(state)
    assert {:ok, ^state} = ProgressCore.admit(snapshot, fresh_bindings())
    assert {:ok, _} = Jason.encode(snapshot)

    shuffled_bindings =
      fresh_bindings()
      |> Map.put("identities", identities(plan()) |> Enum.shuffle() |> Map.new())

    assert {:ok, ^state} = ProgressCore.admit(snapshot, shuffled_bindings)
  end

  test "new/1 rejects snapshots, open status, extra keys, and plan digest mismatch" do
    {:ok, state} = ProgressCore.new(fresh_bindings())
    assert {:error, :malformed_state} = ProgressCore.new(ProgressCore.show(state))

    assert {:error, :malformed_state} =
             ProgressCore.new(Map.put(fresh_bindings(), "status", "open"))

    assert {:error, :plan_drift} =
             ProgressCore.new(
               Map.put(
                 fresh_bindings(),
                 "identities",
                 Map.put(identities(plan()), "validation_plan_digest", @hex)
               )
             )

    assert {:error, :plan_drift} =
             ProgressCore.new(Map.put(fresh_bindings(), "planned_batches", []))
  end

  test "new/1 constructs completed compact progress for an exact empty plan" do
    {:ok, expected_digest} = ValidationCapacityHandoff.ordered_plan_digest([])
    {:ok, identities_digest} = EvidenceCore.digest(identities([]))
    {:ok, receipts_digest} = EvidenceCore.digest([])
    {:ok, state} = ProgressCore.new(empty_bindings())

    assert state["status"] == "completed"
    assert state["plan_digest"] == expected_digest
    assert state["identities_digest"] == identities_digest
    assert state["total_batch_count"] == 0
    assert state["total_file_count"] == 0
    assert state["passed_receipts"] == []
    assert state["passed_receipts_digest"] == receipts_digest
    assert state["completed_batch_count"] == 0
    assert state["completed_file_count"] == 0
    assert state["next_batch_index"] == 1
    assert state["window_ordinal"] == 0
    assert state["capacity"] == nil
    assert {:ok, ^state} = ProgressCore.admit(ProgressCore.show(state), empty_bindings())
    assert Enum.to_list(state) == Enum.to_list(ProgressCore.show(state))
  end

  test "in_progress empty plan is malformed" do
    {:ok, state} = ProgressCore.new(empty_bindings())
    forged = Map.put(ProgressCore.show(state), "status", "in_progress")
    assert {:error, :malformed_state} = ProgressCore.admit(forged, empty_bindings())
    assert {:error, :malformed_state} = ProgressCore.show(forged)
  end

  test "admit/2 rejects status open" do
    {:ok, state} = ProgressCore.new(fresh_bindings())
    opened = Map.put(ProgressCore.show(state), "status", "open")
    assert {:error, :malformed_state} = ProgressCore.admit(opened, fresh_bindings())
  end

  test "one structural capacity advance stores compact summary without remaining suffix" do
    {:ok, state} = ProgressCore.new(fresh_bindings())
    plan = plan()
    structural = v3_handoff(plan, [], nil, plan, "structural")

    assert {:ok, handed} =
             ProgressCore.advance(state, capacity_bindings(), %{
               "schema_version" => 1,
               "new_receipts" => [],
               "disposition" => %{"type" => "capacity_handoff", "capacity_handoff" => structural}
             })

    assert handed["status"] == "in_progress"
    assert handed["window_ordinal"] == 1
    assert handed["passed_receipts"] == []
    assert handed["next_batch_index"] == 1
    assert is_map(handed["capacity"])
    refute Map.has_key?(handed["capacity"], "unstarted_batches")
    assert handed["capacity"]["phase"] == "structural"
    assert handed["capacity"]["completed_batch_count"] == 0
    assert handed["capacity"]["unstarted_batch_count"] == 2
    assert handed["capacity"]["interrupted_batch"] == nil
    assert handed["refinement"] == nil
    {:ok, suffix_digest} = ValidationCapacityHandoff.ordered_plan_digest(plan)
    assert handed["capacity"]["remaining_suffix_digest"] == suffix_digest
    refute Jason.encode!(handed) =~ "unstarted_batches"
  end

  test "runtime capacity with receipts then a second advance increments ordinal" do
    {:ok, fresh} = ProgressCore.new(fresh_bindings())
    [first, second] = plan()
    runtime = v3_handoff(plan(), [first], nil, [second], "runtime")

    assert {:ok, after_first} =
             ProgressCore.advance(fresh, capacity_bindings(), %{
               "schema_version" => 1,
               "new_receipts" => [passed(first)],
               "disposition" => %{"type" => "capacity_handoff", "capacity_handoff" => runtime}
             })

    assert after_first["window_ordinal"] == 1
    assert after_first["completed_batch_count"] == 1
    assert after_first["next_batch_index"] == 2
    assert after_first["passed_receipts"] == [passed(first)]
    assert after_first["capacity"]["phase"] == "runtime"
    assert after_first["capacity"]["interrupted_batch"] == nil
    refute Map.has_key?(after_first["capacity"], "unstarted_batches")

    interrupted = v3_handoff(plan(), [first], second, [], "runtime")

    assert {:ok, after_second} =
             ProgressCore.advance(after_first, capacity_bindings(), %{
               "schema_version" => 1,
               "new_receipts" => [],
               "disposition" => %{"type" => "capacity_handoff", "capacity_handoff" => interrupted}
             })

    assert after_second["window_ordinal"] == 2
    assert after_second["completed_batch_count"] == 1
    assert after_second["capacity"]["interrupted_batch"]["index"] == 2
    assert after_second["capacity"]["unstarted_batch_count"] == 0
    {:ok, remaining_digest} = ValidationCapacityHandoff.ordered_plan_digest([second])
    assert after_second["capacity"]["remaining_suffix_digest"] == remaining_digest
  end

  test "complete requires exactly one passed receipt per injected batch" do
    {:ok, fresh} = ProgressCore.new(fresh_bindings())
    [first, second] = plan()

    assert {:error, :incomplete_plan} =
             ProgressCore.advance(fresh, fresh_bindings(), %{
               "schema_version" => 1,
               "new_receipts" => [],
               "disposition" => %{"type" => "completed"}
             })

    assert {:error, :incomplete_plan} =
             ProgressCore.advance(fresh, fresh_bindings(), %{
               "schema_version" => 1,
               "new_receipts" => [passed(first)],
               "disposition" => %{"type" => "completed"}
             })

    assert {:ok, completed} =
             ProgressCore.advance(fresh, fresh_bindings(), %{
               "schema_version" => 1,
               "new_receipts" => [passed(first), passed(second)],
               "disposition" => %{"type" => "completed"}
             })

    assert completed["status"] == "completed"
    assert completed["capacity"] == nil
    assert completed["window_ordinal"] == 1
    assert completed["next_batch_index"] == 3
    assert completed["completed_batch_count"] == 2
    assert {:ok, _} = ProgressCore.admit(ProgressCore.show(completed), fresh_bindings())
  end

  test "canonical digest is stable across show/1 and key shuffle of bindings" do
    {:ok, state} = ProgressCore.new(fresh_bindings())
    {:ok, digest} = EvidenceCore.digest(ProgressCore.show(state))
    {:ok, again} = EvidenceCore.digest(ProgressCore.show(state))
    assert digest == again
    assert digest =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "receipt errors follow duplicate, skipped, reordered, then contradictory precedence" do
    {:ok, fresh} = ProgressCore.new(fresh_bindings())
    [first, second] = plan()

    {:ok, after_first} =
      ProgressCore.advance(fresh, capacity_bindings(), %{
        "schema_version" => 1,
        "new_receipts" => [passed(first)],
        "disposition" => %{
          "type" => "capacity_handoff",
          "capacity_handoff" => runtime_after([first])
        }
      })

    duplicate = second |> Map.put("index", 1) |> passed()

    assert {:error, :duplicate_receipt} =
             ProgressCore.advance(
               after_first,
               capacity_bindings(),
               observation([duplicate], :complete_invalid)
             )

    assert {:error, :duplicate_receipt} =
             ProgressCore.advance(
               after_first,
               capacity_bindings(),
               %{
                 "schema_version" => 1,
                 "new_receipts" => [passed(first)],
                 "disposition" => %{"type" => "completed"}
               }
             )

    assert {:error, :skipped_receipt} =
             ProgressCore.advance(fresh, fresh_bindings(), %{
               "schema_version" => 1,
               "new_receipts" => [passed(second)],
               "disposition" => %{"type" => "completed"}
             })

    reordered = passed(Map.put(second, "index", 1))

    assert {:error, :reordered_receipt} =
             ProgressCore.advance(fresh, fresh_bindings(), %{
               "schema_version" => 1,
               "new_receipts" => [reordered],
               "disposition" => %{"type" => "completed"}
             })

    contradictory = Map.put(passed(first), "outcome", "failed")

    assert {:error, :contradictory_receipt} =
             ProgressCore.advance(fresh, fresh_bindings(), %{
               "schema_version" => 1,
               "new_receipts" => [contradictory],
               "disposition" => %{"type" => "completed"}
             })
  end

  test "malformed, oversized, and authority-bearing input fail before an effect escapes" do
    assert {:error, :malformed_state} = ProgressCore.new(:nope)
    assert {:error, :malformed_state} = ProgressCore.new(%{"identities" => %{}})

    {:ok, state} = ProgressCore.new(fresh_bindings())

    assert {:error, :malformed_state} =
             ProgressCore.advance(state, fresh_bindings(), %{
               "schema_version" => 1,
               "new_receipts" => [%{"not" => "a-receipt"}],
               "disposition" => %{"type" => "completed"}
             })

    leaked = Map.put(fresh_bindings(), "token", "nope")
    assert {:error, :malformed_state} = ProgressCore.new(leaked)

    snapshot = ProgressCore.show(state) |> Map.put("authority", "x")
    assert {:error, :malformed_state} = ProgressCore.admit(snapshot, fresh_bindings())

    assert {:error, :malformed_observation} =
             ProgressCore.advance(state, fresh_bindings(), %{
               "schema_version" => 1,
               "new_receipts" => [],
               "disposition" => %{"type" => "failed", "reason" => "nope"},
               "fence_token" => "x"
             })

    encoded = Jason.encode!(ProgressCore.show(state))
    refute encoded =~ "authority"
    refute encoded =~ "fence_token"
    refute encoded =~ "capability"

    pad = String.duplicate("x", 5_000)
    padded = Map.put(identities(plan()), "pad", pad)

    assert {:error, :oversized_state} =
             ProgressCore.new(Map.put(fresh_bindings(), "identities", padded))
  end

  test "show/1 rejects malformed, oversized, non-JSON, and forbidden-key state instead of coercing capacity" do
    {:ok, state} = ProgressCore.new(fresh_bindings())
    assert {:error, :malformed_state} = ProgressCore.show(:nope)
    assert {:error, :malformed_state} = ProgressCore.show(DateTime.utc_now())
    assert {:error, :malformed_state} = ProgressCore.show(Map.put(state, "extra", "nope"))
    assert {:error, :malformed_state} = ProgressCore.show(Map.put(state, :status, "in_progress"))

    assert {:error, :malformed_state} =
             ProgressCore.show(Map.put(state, "total_batch_count", "2"))

    assert {:error, :malformed_state} =
             ProgressCore.show(Map.put(state, "total_file_count", 0))

    assert {:error, :malformed_state} =
             ProgressCore.show(Map.put(state, "identities_digest", String.duplicate("0", 64)))

    niled = Map.put(ProgressCore.show(state), "capacity", "not-a-capacity")
    assert {:error, :malformed_state} = ProgressCore.show(niled)
    refute match?(%{"capacity" => nil}, ProgressCore.show(niled))

    nested_token = put_in(ProgressCore.show(state), ["identities", "token"], "x")
    assert {:error, :malformed_state} = ProgressCore.show(nested_token)

    oversized_receipts =
      Enum.map(1..2_000, fn i -> %{"pad" => String.duplicate("x", 200), "n" => i} end)

    huge = Map.put(ProgressCore.show(state), "passed_receipts", oversized_receipts)
    assert {:error, :malformed_state} = ProgressCore.show(huge)

    [first, second] = plan()

    {:ok, completed} =
      ProgressCore.advance(state, fresh_bindings(), %{
        "schema_version" => 1,
        "new_receipts" => [passed(first), passed(second)],
        "disposition" => %{"type" => "completed"}
      })

    assert {:error, :malformed_state} =
             ProgressCore.show(Map.put(completed, "total_file_count", 1))

    wrong_receipt_digest =
      Map.put(ProgressCore.show(completed), "passed_receipts_digest", String.duplicate("0", 64))

    assert {:error, :malformed_state} = ProgressCore.show(wrong_receipt_digest)

    malformed_receipt =
      put_in(ProgressCore.show(completed), ["passed_receipts", Access.at(0), "count"], "1")

    assert {:error, :malformed_state} = ProgressCore.show(malformed_receipt)

    {:ok, handed} =
      ProgressCore.advance(state, capacity_bindings(), %{
        "schema_version" => 1,
        "new_receipts" => [],
        "disposition" => %{
          "type" => "capacity_handoff",
          "capacity_handoff" => v3_handoff(plan(), [], nil, plan(), "structural")
        }
      })

    malformed_capacity =
      put_in(ProgressCore.show(handed), ["capacity", "per_batch_budget_ms"], "1000")

    assert {:error, :malformed_state} = ProgressCore.show(malformed_capacity)
  end

  test "nonfresh in_progress requires canonical capacity; extra interrupted keys are drift" do
    {:ok, fresh} = ProgressCore.new(fresh_bindings())
    [first, second] = plan()

    {:ok, after_first} =
      ProgressCore.advance(fresh, capacity_bindings(), %{
        "schema_version" => 1,
        "new_receipts" => [passed(first)],
        "disposition" => %{
          "type" => "capacity_handoff",
          "capacity_handoff" => runtime_after([first])
        }
      })

    assert is_map(after_first["capacity"])

    dropped_capacity =
      ProgressCore.show(after_first)
      |> Map.put("capacity", nil)

    assert {:error, :ordinal_drift} = ProgressCore.admit(dropped_capacity, capacity_bindings())
    assert {:error, :malformed_state} = ProgressCore.show(dropped_capacity)

    extra_interrupted =
      put_in(
        ProgressCore.show(after_first),
        ["capacity", "interrupted_batch"],
        Map.put(second, "paths", ["x"])
      )

    assert {:error, :capacity_drift} = ProgressCore.admit(extra_interrupted, capacity_bindings())
    assert {:error, :malformed_state} = ProgressCore.show(extra_interrupted)
  end

  test "authority exclusion is key-schema based and does not substring-match task_tokenizer" do
    plan = plan()
    identities = Map.put(identities(plan), "task_id", "task_tokenizer")
    bindings = Map.put(fresh_bindings(), "identities", identities)
    assert {:ok, state} = ProgressCore.new(bindings)
    assert state["identities"]["task_id"] == "task_tokenizer"
    assert {:ok, _} = ProgressCore.admit(ProgressCore.show(state), bindings)

    assert {:error, :malformed_state} =
             ProgressCore.new(Map.put(fresh_bindings(), "secret", "nope"))
  end

  test "identity, plan, static, count, index, ordinal, capacity, and prefix digest drift fail closed" do
    {:ok, state} = ProgressCore.new(fresh_bindings())
    snapshot = ProgressCore.show(state)

    drifted_ids = Map.put(identities(plan()), "task_id", "task_other")

    assert {:error, :identity_drift} =
             ProgressCore.admit(snapshot, Map.put(fresh_bindings(), "identities", drifted_ids))

    other_plan = [batch(1, 1, 1, @inv3)]

    assert {:error, :plan_drift} =
             ProgressCore.admit(
               snapshot,
               Map.put(fresh_bindings(), "planned_batches", other_plan)
             )

    assert {:error, :static_receipt_drift} =
             ProgressCore.admit(
               snapshot,
               Map.put(fresh_bindings(), "static_stage_receipt_digest", String.duplicate("f", 64))
             )

    assert {:error, :ordinal_drift} =
             ProgressCore.admit(snapshot, Map.put(fresh_bindings(), "window_ordinal", 1))

    counted = Map.put(snapshot, "completed_batch_count", 1)
    assert {:error, :count_drift} = ProgressCore.admit(counted, fresh_bindings())

    indexed = Map.put(snapshot, "next_batch_index", 2)
    assert {:error, :index_drift} = ProgressCore.admit(indexed, fresh_bindings())

    ordinaled = Map.put(snapshot, "window_ordinal", 4)
    assert {:error, :ordinal_drift} = ProgressCore.admit(ordinaled, fresh_bindings())

    digested = Map.put(snapshot, "passed_receipts_digest", String.duplicate("0", 64))
    assert {:error, :receipt_prefix_drift} = ProgressCore.admit(digested, fresh_bindings())

    {:ok, handed} =
      ProgressCore.advance(state, capacity_bindings(), %{
        "schema_version" => 1,
        "new_receipts" => [],
        "disposition" => %{
          "type" => "capacity_handoff",
          "capacity_handoff" => v3_handoff(plan(), [], nil, plan(), "structural")
        }
      })

    drifted_capacity = put_in(ProgressCore.show(handed), ["capacity", "completed_batch_count"], 1)

    assert {:error, :capacity_drift} =
             ProgressCore.admit(drifted_capacity, capacity_bindings())
  end

  test "non-canonical capacity evidence is rejected" do
    {:ok, state} = ProgressCore.new(fresh_bindings())
    structural = v3_handoff(plan(), [], nil, plan(), "structural")

    residual = Map.put(structural, "available_budget_ms", 1)

    assert {:error, :non_canonical_capacity_handoff} =
             ProgressCore.advance(state, capacity_bindings(), %{
               "schema_version" => 1,
               "new_receipts" => [],
               "disposition" => %{"type" => "capacity_handoff", "capacity_handoff" => residual}
             })

    v1 = Map.put(structural, "schema_version", 1)

    assert {:error, :non_canonical_capacity_handoff} =
             ProgressCore.advance(state, capacity_bindings(), %{
               "schema_version" => 1,
               "new_receipts" => [],
               "disposition" => %{"type" => "capacity_handoff", "capacity_handoff" => v1}
             })

    other_plan = [
      batch(1, 2, 1, String.duplicate("8", 64)),
      batch(2, 2, 1, String.duplicate("9", 64))
    ]

    wrong = v3_handoff(other_plan, [], nil, other_plan, "structural")

    assert {:error, :non_canonical_capacity_handoff} =
             ProgressCore.advance(state, capacity_bindings(), %{
               "schema_version" => 1,
               "new_receipts" => [],
               "disposition" => %{"type" => "capacity_handoff", "capacity_handoff" => wrong}
             })
  end

  test "incomplete prefix cannot be admitted as completed" do
    {:ok, state} = ProgressCore.new(fresh_bindings())
    [first | _] = plan()

    {:ok, after_first} =
      ProgressCore.advance(state, capacity_bindings(), %{
        "schema_version" => 1,
        "new_receipts" => [passed(first)],
        "disposition" => %{
          "type" => "capacity_handoff",
          "capacity_handoff" => runtime_after([first])
        }
      })

    forged =
      ProgressCore.show(after_first) |> Map.put("status", "completed") |> Map.put("capacity", nil)

    assert {:error, :malformed_state} = ProgressCore.admit(forged, fresh_bindings())
  end

  test "schema-v1 snapshots without refinement upgrade; v1 with refinement and v2 gaps fail closed" do
    {:ok, state} = ProgressCore.new(fresh_bindings())
    v2 = ProgressCore.show(state)
    assert v2["schema_version"] == 2
    assert v2["refinement"] == nil

    v1 =
      v2
      |> Map.delete("refinement")
      |> Map.put("schema_version", 1)

    assert {:ok, upgraded} = ProgressCore.admit(v1, fresh_bindings())
    assert upgraded["schema_version"] == 2
    assert upgraded["refinement"] == nil
    assert {:error, :malformed_state} = ProgressCore.show(v1)

    v1_with_frontier = Map.put(v1, "refinement", nil)
    assert {:error, :malformed_state} = ProgressCore.admit(v1_with_frontier, fresh_bindings())

    v2_missing = Map.delete(v2, "refinement")
    assert {:error, :malformed_state} = ProgressCore.admit(v2_missing, fresh_bindings())

    v3 = Map.put(v2, "schema_version", 3)
    assert {:error, :malformed_state} = ProgressCore.admit(v3, fresh_bindings())
  end

  test "schema-v1 observations advance schema-v2 snapshots; observation schema 2 fails closed" do
    {:ok, state} = ProgressCore.new(fresh_bindings())
    assert state["schema_version"] == 2
    [first, second] = plan()

    assert {:ok, completed} =
             ProgressCore.advance(state, fresh_bindings(), %{
               "schema_version" => 1,
               "new_receipts" => [passed(first), passed(second)],
               "disposition" => %{"type" => "completed"}
             })

    assert completed["schema_version"] == 2
    assert completed["status"] == "completed"

    assert {:error, :malformed_observation} =
             ProgressCore.advance(state, fresh_bindings(), %{
               "schema_version" => 2,
               "new_receipts" => [passed(first), passed(second)],
               "disposition" => %{"type" => "completed"}
             })
  end

  test "refinement fail-closed table rejects tamper, overlap, gaps, reorder, drift, and oversized state" do
    {original, compact, frontier, bindings} = wide_frontier_fixture()
    {:ok, fresh} = ProgressCore.new(bindings)
    handoff = v3_handoff([compact], [], compact, [], "runtime")

    assert {:ok, handed} =
             ProgressCore.advance(fresh, Map.put(bindings, "per_batch_budget_ms", 1_000), %{
               "schema_version" => 1,
               "new_receipts" => [],
               "disposition" => %{
                 "type" => "capacity_handoff",
                 "capacity_handoff" => handoff,
                 "refinement" => frontier
               }
             })

    assert handed["refinement"]["pending_positions"] == frontier["pending_positions"]
    assert handed["passed_receipts"] == []
    snapshot = ProgressCore.show(handed)

    tampered = put_in(snapshot, ["refinement", "pending_positions"], ["rootX"])
    assert {:error, reason} = ProgressCore.admit(tampered, bindings)
    assert reason in [:malformed_state, :invalid_refinement_state]

    overlap =
      put_in(snapshot, ["refinement", "accepted_positions"], ["rootL"])
      |> put_in(["refinement", "pending_positions"], ["rootLL", "rootR"])
      |> put_in(["refinement", "accepted_file_count"], 2)
      |> put_in(["refinement", "pending_file_count"], 3)

    assert {:error, overlap_reason} = ProgressCore.admit(overlap, bindings)
    assert overlap_reason in [:malformed_state, :invalid_refinement_state]

    gap =
      snapshot
      |> put_in(["refinement", "accepted_positions"], [])
      |> put_in(["refinement", "pending_positions"], ["rootR"])
      |> put_in(["refinement", "accepted_file_count"], 0)
      |> put_in(["refinement", "pending_file_count"], 2)
      |> put_in(["refinement", "refined_child_count"], 2)

    assert {:error, gap_reason} = ProgressCore.admit(gap, bindings)
    assert gap_reason in [:malformed_state, :invalid_refinement_state]

    reordered =
      put_in(snapshot, ["refinement", "pending_positions"], ["rootR", "rootLR"])

    assert {:error, reorder_reason} = ProgressCore.admit(reordered, bindings)
    assert reorder_reason in [:malformed_state, :invalid_refinement_state]

    drifted_index = put_in(snapshot, ["refinement", "original_index"], 9)
    assert {:error, :plan_drift} = ProgressCore.admit(drifted_index, bindings)

    drifted_inventory =
      put_in(snapshot, ["refinement", "original_inventory_sha256"], String.duplicate("f", 64))

    assert {:error, :plan_drift} = ProgressCore.admit(drifted_inventory, bindings)

    drifted_ids = Map.put(identities([compact]), "task_id", "task_other")

    assert {:error, :identity_drift} =
             ProgressCore.admit(snapshot, Map.put(bindings, "identities", drifted_ids))

    oversized =
      put_in(
        snapshot,
        ["refinement", "pending_positions"],
        Enum.map(1..21, fn i -> "root" <> String.duplicate("L", rem(i, 5) + 1) end)
      )

    assert {:error, oversized_reason} = ProgressCore.admit(oversized, bindings)
    assert oversized_reason in [:malformed_state, :invalid_refinement_state, :oversized_state]

    forbidden = put_in(snapshot, ["refinement", "token"], "nope")
    assert {:error, :malformed_state} = ProgressCore.admit(forbidden, bindings)

    structural = v3_handoff([compact], [], nil, [compact], "structural")

    assert {:error, :malformed_state} =
             ProgressCore.advance(fresh, Map.put(bindings, "per_batch_budget_ms", 1_000), %{
               "schema_version" => 1,
               "new_receipts" => [],
               "disposition" => %{
                 "type" => "capacity_handoff",
                 "capacity_handoff" => structural,
                 "refinement" => frontier
               }
             })

    completed_bindings = bindings

    assert {:error, :malformed_observation} =
             ProgressCore.advance(fresh, completed_bindings, %{
               "schema_version" => 1,
               "new_receipts" => [passed(compact)],
               "disposition" => %{"type" => "completed", "refinement" => frontier}
             })

    child_receipt = Map.put(compact, "label", original.label <> ":refine-rootLL-n1-dead")

    assert {:error, child_reason} =
             ProgressCore.advance(fresh, Map.put(bindings, "per_batch_budget_ms", 1_000), %{
               "schema_version" => 1,
               "new_receipts" => [passed(child_receipt)],
               "disposition" => %{
                 "type" => "capacity_handoff",
                 "capacity_handoff" => handoff,
                 "refinement" => frontier
               }
             })

    assert child_reason in [:contradictory_receipt, :malformed_state, :reordered_receipt]
  end

  test "20-path refinement snapshot round-trips under the compact progress byte ceiling" do
    paths =
      for i <- 1..20 do
        "apps/alpha/test/f#{String.pad_leading(Integer.to_string(i), 2, "0")}_test.exs"
      end

    assert {:ok, [original]} = Core.partition_test_batches(paths)
    {:ok, [compact]} = Core.compact_batch_plan([original])
    assert {:ok, execution} = Core.new_test_execution([original], 10_000)
    max_state = progress_refine_until_last_leaf(execution, 100_000)
    assert {:ok, frontier} = Core.compact_refinement_frontier(max_state)
    bindings = bindings_for([compact]) |> Map.put("per_batch_budget_ms", 1_000)
    {:ok, fresh} = ProgressCore.new(bindings)
    handoff = v3_handoff([compact], [], compact, [], "runtime")

    assert {:ok, handed} =
             ProgressCore.advance(fresh, bindings, %{
               "schema_version" => 1,
               "new_receipts" => [],
               "disposition" => %{
                 "type" => "capacity_handoff",
                 "capacity_handoff" => handoff,
                 "refinement" => frontier
               }
             })

    snapshot = ProgressCore.show(handed)
    encoded = Jason.encode!(snapshot)
    assert byte_size(encoded) <= ProgressCore.max_json_bytes()

    assert byte_size(Jason.encode!(snapshot["refinement"])) <=
             ProgressCore.limits()["max_refinement_json_bytes"]

    assert {:ok, admitted} = ProgressCore.admit(Jason.decode!(encoded), bindings)
    assert admitted["refinement"]["refined_child_count"] == 38
    assert admitted["refinement"]["pending_file_count"] == 1
  end

  test "343 and 604 compact snapshots stay at or below 163840 bytes; 604 capacity-before-final is the measured max" do
    current = current_max_batches()
    historical = historical_five_file_max_batches()
    assert length(current) == 343
    assert length(historical) == 604

    {:ok, current_fresh} = ProgressCore.new(bindings_for(current))
    current_fresh_bytes = byte_size(Jason.encode!(ProgressCore.show(current_fresh)))

    {:ok, current_cap} = admit_capacity_before_final(current)
    current_cap_bytes = byte_size(Jason.encode!(ProgressCore.show(current_cap)))

    {:ok, historical_cap} = admit_capacity_before_final(historical)
    historical_cap_bytes = byte_size(Jason.encode!(ProgressCore.show(historical_cap)))

    assert current_fresh_bytes <= ProgressCore.max_json_bytes()
    assert current_cap_bytes <= ProgressCore.max_json_bytes()
    assert historical_cap_bytes <= ProgressCore.max_json_bytes()
    assert historical_cap_bytes >= current_cap_bytes
    assert historical_cap_bytes >= current_fresh_bytes
    assert historical_cap["capacity"]["interrupted_batch"]["index"] == 604
    assert historical_cap["completed_batch_count"] == 603
    refute Map.has_key?(historical_cap["capacity"], "unstarted_batches")
  end

  defp admit_capacity_before_final(plan) do
    bindings = bindings_for(plan) |> Map.put("per_batch_budget_ms", 1_000)
    {:ok, fresh} = ProgressCore.new(bindings)
    prefix = Enum.map(Enum.take(plan, length(plan) - 1), &passed/1)
    last = List.last(plan)
    {:ok, prefix_digest} = EvidenceCore.digest(prefix)
    {:ok, remaining_digest} = ValidationCapacityHandoff.ordered_plan_digest([last])
    completed_files = Enum.reduce(prefix, 0, fn receipt, acc -> acc + receipt["count"] end)
    unstarted_files = 0

    snapshot =
      fresh
      |> Map.put("passed_receipts", prefix)
      |> Map.put("passed_receipts_digest", prefix_digest)
      |> Map.put("completed_batch_count", length(prefix))
      |> Map.put("completed_file_count", completed_files)
      |> Map.put("next_batch_index", length(prefix) + 1)
      |> Map.put("window_ordinal", 1)
      |> Map.put("capacity", %{
        "phase" => "runtime",
        "available_budget_ms" => 0,
        "per_batch_budget_ms" => 1_000,
        "completed_batch_count" => length(prefix),
        "completed_file_count" => completed_files,
        "unstarted_batch_count" => 0,
        "unstarted_file_count" => unstarted_files,
        "total_batch_count" => length(plan),
        "total_file_count" => completed_files + last["count"],
        "remaining_suffix_digest" => remaining_digest,
        "interrupted_batch" => last
      })

    ProgressCore.admit(snapshot, bindings)
  end

  defp observation(receipts, :complete_invalid) do
    %{
      "schema_version" => 1,
      "new_receipts" => receipts,
      "disposition" => %{"type" => "completed"}
    }
  end

  defp runtime_after(completed) do
    remaining = Enum.drop(plan(), length(completed))
    v3_handoff(plan(), completed, nil, remaining, "runtime")
  end

  defp plan do
    [batch(1, 2, 1, @inv1), batch(2, 2, 1, @inv2)]
  end

  defp batch(index, total, count, inventory) do
    %{
      "index" => index,
      "total" => total,
      "count" => count,
      "label" => "batch-#{index}-of-#{total}-n#{count}-#{inventory}",
      "inventory_sha256" => inventory
    }
  end

  defp passed(batch), do: Map.put(batch, "outcome", "passed")

  defp failure_check_keys do
    Enum.sort(~w(
      exit_code
      passed
      reason
      status
      stderr_excerpt
      stderr_sha256
      stderr_truncated
      stdout_excerpt
      stdout_sha256
      stdout_truncated
    ))
  end

  defp failure_check(opts) do
    label = Keyword.fetch!(opts, :label)
    stdout = Keyword.fetch!(opts, :stdout)

    classified =
      Core.classify_app_test_result(label, %{
        "exit_code" => 1,
        "passed" => false,
        "stdout_excerpt" => stdout,
        "stderr_excerpt" => "",
        "stdout_truncated" => false,
        "stderr_truncated" => false,
        "stdout_sha256" => String.duplicate("a", 64),
        "stderr_sha256" => String.duplicate("b", 64)
      })

    Core.aggregate_test_check([classified])
  end

  defp identities(plan) do
    {:ok, digest} = ValidationCapacityHandoff.ordered_plan_digest(plan)

    %{
      "task_id" => "task_progress_g1",
      "work_packet_digest" => "sha256:" <> @hex,
      "base_commit" => @base_oid,
      "base_tree_oid" => @base_tree_oid,
      "candidate_head" => @base_oid,
      "candidate_tree_oid" => @candidate_tree_oid,
      "validation_plan_digest" => digest,
      "toolchain_digest" => String.duplicate("3", 64),
      "dependency_baseline_digest" => String.duplicate("4", 64),
      "wrapper_digest" => String.duplicate("5", 64),
      "validator_id" => "coding_cross_app_validate",
      "principal_id" => "agent_principal",
      "configuration_digest" => String.duplicate("6", 64)
    }
  end

  defp fresh_bindings do
    %{
      "identities" => identities(plan()),
      "planned_batches" => plan(),
      "static_stage_receipt_digest" => @static
    }
  end

  defp empty_bindings do
    %{
      "identities" => identities([]),
      "planned_batches" => [],
      "static_stage_receipt_digest" => @static
    }
  end

  defp capacity_bindings do
    Map.put(fresh_bindings(), "per_batch_budget_ms", 1_000)
  end

  defp bindings_for(plan) do
    %{
      "identities" => identities(plan),
      "planned_batches" => plan,
      "static_stage_receipt_digest" => @static
    }
  end

  defp v3_handoff(planned, completed, interrupted, unstarted, phase) do
    digest_subject = if interrupted, do: [interrupted | unstarted], else: unstarted
    {:ok, digest} = ValidationCapacityHandoff.ordered_plan_digest(digest_subject)
    completed_files = Enum.reduce(completed, 0, fn batch, acc -> acc + batch["count"] end)
    interrupted_files = if is_map(interrupted), do: interrupted["count"], else: 0
    unstarted_files = Enum.reduce(unstarted, 0, fn batch, acc -> acc + batch["count"] end)

    {:ok, descriptor} =
      ValidationCapacityHandoff.new(%{
        "schema_version" => ValidationCapacityHandoff.schema_version(),
        "phase" => phase,
        "available_budget_ms" => 0,
        "per_batch_budget_ms" => 1_000,
        "completed_batch_count" => length(completed),
        "completed_file_count" => completed_files,
        "unstarted_batch_count" => length(unstarted),
        "unstarted_file_count" => unstarted_files,
        "total_batch_count" => length(planned),
        "total_file_count" => completed_files + interrupted_files + unstarted_files,
        "ordered_plan_sha256" => digest,
        "interrupted_batch" => interrupted,
        "unstarted_batches" => unstarted
      })

    ValidationCapacityHandoff.to_map(descriptor)
  end

  defp wide_frontier_fixture do
    paths =
      for i <- 1..4 do
        "apps/alpha/test/f#{i}_test.exs"
      end

    {:ok, [original]} = Core.partition_test_batches(paths)
    {:ok, [compact]} = Core.compact_batch_plan([original])
    {:ok, execution} = Core.new_test_execution([original], 10_000)
    assert {:run, root, 10_000} = Core.next_test_execution_step(execution, 20_000)

    assert {:continue, after_root} =
             Core.record_test_execution_attempt(
               execution,
               root,
               progress_test_feedback(nil, "root timeout"),
               true,
               10_000,
               10_000
             )

    assert {:run, left, 10_000} = Core.next_test_execution_step(after_root, 10_000)

    assert {:continue, after_left} =
             Core.record_test_execution_attempt(
               after_root,
               left,
               progress_test_feedback(nil, "left timeout"),
               true,
               10_000,
               10_000
             )

    assert {:run, left_left, 10_000} = Core.next_test_execution_step(after_left, 10_000)

    assert {:continue, after_leaf} =
             Core.record_test_execution_attempt(
               after_left,
               left_left,
               progress_test_feedback(0, "leaf pass"),
               false,
               10_000,
               0
             )

    {:ok, frontier} = Core.compact_refinement_frontier(after_leaf)
    bindings = bindings_for([compact])
    {original, compact, frontier, bindings}
  end

  defp progress_refine_until_last_leaf(state, residual) do
    assert {:run, attempt, 10_000} = Core.next_test_execution_step(state, residual)

    {runner_timeout, exit_code, stdout} =
      if attempt.count > 1 do
        {true, nil, "#{attempt.position} timeout"}
      else
        {false, 0, "#{attempt.position} pass"}
      end

    assert {:continue, next} =
             Core.record_test_execution_attempt(
               state,
               attempt,
               progress_test_feedback(exit_code, stdout),
               runner_timeout,
               10_000,
               residual - 1
             )

    if length(next.accepted_paths) == 19 and length(next.work_queue) == 1 do
      next
    else
      progress_refine_until_last_leaf(next, residual - 1)
    end
  end

  defp progress_test_feedback(exit_code, stdout) do
    %{
      "exit_code" => exit_code,
      "passed" => exit_code == 0,
      "stdout_excerpt" => stdout,
      "stderr_excerpt" => "",
      "stdout_truncated" => false,
      "stderr_truncated" => false,
      "stdout_sha256" => :crypto.hash(:sha256, stdout) |> Base.encode16(case: :lower),
      "stderr_sha256" => :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)
    }
  end

  defp current_max_batches do
    Enum.map(1..343, fn index ->
      count =
        cond do
          index <= 255 -> 1
          index <= 342 -> 20
          true -> 5
        end

      inventory_sha256 =
        :crypto.hash(:sha256, "inventory-#{index}")
        |> Base.encode16(case: :lower)

      batch(index, 343, count, inventory_sha256)
    end)
  end

  defp historical_five_file_max_batches do
    Enum.map(1..604, fn index ->
      count = if index <= 255, do: 1, else: 5

      inventory_sha256 =
        :crypto.hash(:sha256, "historical-inventory-#{index}")
        |> Base.encode16(case: :lower)

      batch(index, 604, count, inventory_sha256)
    end)
  end
end
