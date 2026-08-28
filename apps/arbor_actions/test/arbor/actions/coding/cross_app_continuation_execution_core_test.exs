defmodule Arbor.Actions.Coding.CrossApp.ContinuationExecutionCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.CrossApp.ContinuationCore, as: Core
  alias Arbor.Actions.Coding.CrossApp.ContinuationExecutionCore, as: Exec
  alias Arbor.Contracts.Coding.ValidationCapacityHandoff

  @moduletag :fast

  @inv1 String.duplicate("a", 64)
  @inv2 String.duplicate("b", 64)
  @hex String.duplicate("c", 64)
  @token "fence-token-1"
  @claimed_at "2026-08-27T12:00:00Z"
  @expires_at "2026-08-27T13:00:00Z"
  @base_oid String.duplicate("1", 40)
  @base_tree_oid String.duplicate("2", 40)
  @candidate_tree_oid String.duplicate("3", 40)
  @empty_sha String.duplicate("a", 64)

  test "limits publish escaped JSON string bounds and reuse continuation ceilings" do
    limits = Exec.limits()
    assert limits["max_excerpt_json_bytes"] == 2 + 6 * limits["max_excerpt_raw_bytes"]
    assert limits["max_reason_json_bytes"] == 2 + 6 * limits["max_reason_raw_bytes"]

    assert limits["max_identifier_json_bytes"] ==
             2 + 6 * limits["max_identifier_raw_bytes"]

    assert limits["max_continuation_id_json_bytes"] ==
             2 + limits["max_continuation_id_raw_bytes"]

    assert limits["max_excerpt_raw_bytes"] == 2_000
    assert limits["max_reason_raw_bytes"] == 256

    max_check =
      hd_check(String.duplicate(<<0>>, limits["max_excerpt_raw_bytes"]))
      |> Map.put("stdout_truncated", false)
      |> Map.put("stderr_truncated", false)

    assert limits["max_check_json_bytes"] == byte_size(Jason.encode!(max_check))
    assert limits["max_static_receipt_json_bytes"] > 76_000
    refute limits["max_excerpt_json_bytes"] in [4_640, 19_040]
    assert limits["max_reason_json_bytes"] > 512
    assert limits["max_plan_json_bytes"] == 256_000
    assert limits["max_receipts_json_bytes"] == 256_000
    assert limits["max_handoff_json_bytes"] == 256_000
    assert limits["max_window_json_bytes"] == 778_240
    assert limits["max_window_json_bytes"] == Core.limits()["max_state_json_bytes"]
    assert limits["max_static_receipt_json_bytes"] == expected_static_receipt_ceiling(limits)
    assert limits["max_progress_json_bytes"] == expected_progress_ceiling(limits)
  end

  test "static receipt is non-circular, closed JSON, and digest-stable" do
    identities = identities(plan())
    {:ok, receipt, digest} = Exec.new_static_stage_receipt(identities, successful_checks())

    assert receipt["schema_version"] == 1
    assert receipt["continuation_id"] =~ ~r/\Axappc_[0-9a-f]{64}\z/
    assert receipt["identities"] == identities
    assert Enum.sort(Map.keys(receipt)) == ~w(checks continuation_id identities schema_version)
    assert Enum.sort(Map.keys(receipt["checks"])) == ~w(compile test_compile xref)

    Enum.each(["compile", "xref", "test_compile"], fn name ->
      check = receipt["checks"][name]
      assert Enum.sort(Map.keys(check)) == expected_check_keys()
      assert check["status"] == "completed"
      assert check["passed"] == true
      assert check["exit_code"] == 0
      assert check["reason"] == nil
    end)

    refute Map.has_key?(receipt, "digest")
    refute Map.has_key?(receipt, "static_stage_receipt_digest")
    assert {:ok, encoded} = Jason.encode(receipt)
    refute encoded =~ "fence_token"
    refute encoded =~ "authority"

    {:ok, admitted} = Exec.admit_static_stage_receipt(receipt)
    assert admitted == receipt
    assert {:ok, ^digest} = Exec.static_receipt_digest(receipt)
    assert digest =~ ~r/\A[0-9a-f]{64}\z/
    {:ok, reshuffled} = Exec.static_receipt_digest(shuffle_map(receipt))
    assert reshuffled == digest
    {:ok, from_core} = Core.digest(receipt)
    assert digest == from_core
  end

  test "static receipt admits 2000-byte NUL/newline/quote/backslash excerpts and rejects 2001" do
    heavy = String.duplicate(<<0, ?\n, ?", ?\\>>, 500)
    assert byte_size(heavy) == 2_000
    assert String.valid?(heavy)

    nuls = String.duplicate(<<0>>, 2_000)
    assert byte_size(Jason.encode!(nuls)) == 2 + 6 * 2_000
    assert byte_size(Jason.encode!(nuls)) == Exec.limits()["max_excerpt_json_bytes"]

    {:ok, receipt, _digest} =
      Exec.new_static_stage_receipt(identities(plan()), successful_checks(heavy_excerpt: heavy))

    assert receipt["checks"]["compile"]["stdout_excerpt"] == heavy
    assert {:ok, encoded} = Jason.encode(receipt)
    assert byte_size(encoded) <= Exec.limits()["max_static_receipt_json_bytes"]
    assert {:ok, _} = Exec.admit_static_stage_receipt(receipt)
    assert {:ok, _} = Exec.static_receipt_digest(receipt)

    too_long = heavy <> <<0>>
    assert byte_size(too_long) == 2_001

    assert {:error, :malformed_envelope} =
             Exec.new_static_stage_receipt(
               identities(plan()),
               successful_checks(heavy_excerpt: too_long)
             )
  end

  test "static receipt rejects failed, mixed, and malformed checks" do
    identities = identities(plan())
    checks = successful_checks()

    failed = put_in(checks, ["compile", "passed"], false)
    assert {:error, :malformed_envelope} = Exec.new_static_stage_receipt(identities, failed)

    nonzero = put_in(checks, ["xref", "exit_code"], 1)
    assert {:error, :malformed_envelope} = Exec.new_static_stage_receipt(identities, nonzero)

    reasoned = put_in(checks, ["test_compile", "reason"], "ok")
    assert {:error, :malformed_envelope} = Exec.new_static_stage_receipt(identities, reasoned)

    skipped = put_in(checks, ["compile", "status"], "skipped")
    assert {:error, :malformed_envelope} = Exec.new_static_stage_receipt(identities, skipped)

    extra = Map.put(checks, "test", hd_check())
    assert {:error, :malformed_envelope} = Exec.new_static_stage_receipt(identities, extra)

    missing = Map.delete(checks, "xref")
    assert {:error, :malformed_envelope} = Exec.new_static_stage_receipt(identities, missing)

    mixed = Map.put(checks, :compile, hd_check())
    assert {:error, :malformed_envelope} = Exec.new_static_stage_receipt(identities, mixed)

    uppercase = put_in(checks, ["compile", "stdout_sha256"], String.duplicate("A", 64))
    assert {:error, :malformed_envelope} = Exec.new_static_stage_receipt(identities, uppercase)

    invalid_utf8 = put_in(checks, ["compile", "stdout_excerpt"], <<255>>)

    assert {:error, :malformed_envelope} =
             Exec.new_static_stage_receipt(identities, invalid_utf8)

    assert {:error, :malformed_state} = Exec.new_static_stage_receipt(%{task_id: "atom"}, checks)
    assert {:error, :malformed_envelope} = Exec.admit_static_stage_receipt(DateTime.utc_now())
    assert {:error, :malformed_envelope} = Exec.static_receipt_digest("not-a-receipt")
  end

  test "window prepare/admit is token-free and bound to claimed state plus receipt digest" do
    {claimed, digest, receipt} = claimed_with_receipt()
    {:ok, window} = Exec.prepare_execution_window(claimed, receipt)

    assert Enum.sort(Map.keys(window)) == expected_window_keys()
    assert window["schema_version"] == 1
    assert window["static_stage_receipt_digest"] == digest
    assert window["identities"] == claimed["identities"]
    assert window["planned_batches"] == claimed["planned_batches"]
    assert window["accepted_receipts"] == []
    assert window["capacity_handoff"] == nil
    assert window["owner_id"] == claimed["claim"]["owner_id"]
    assert window["fence_generation"] == claimed["fence_generation"]
    assert window["claimed_at"] == claimed["claim"]["claimed_at"]
    assert window["expires_at"] == claimed["claim"]["expires_at"]
    {:ok, expected_id} = Core.lineage_key(claimed)
    assert window["continuation_id"] == expected_id

    refute Map.has_key?(window, "fence_token")
    refute Map.has_key?(window, "token")
    refute Map.has_key?(window, "authority")
    refute Map.has_key?(window, "claim")
    encoded = Jason.encode!(window)
    refute encoded =~ "fence_token"
    refute encoded =~ @token
    refute encoded =~ "authority"
    assert byte_size(encoded) <= Exec.limits()["max_window_json_bytes"]

    assert {:ok, ^window} = Exec.admit_execution_window(window, receipt)
    shuffled = Map.put(window, "identities", shuffle_map(window["identities"]))
    assert {:ok, ^window} = Exec.admit_execution_window(shuffled, receipt)

    {:ok, open} = Core.new(fresh_attrs(%{"static_stage_receipt_digest" => digest}))
    assert {:error, :claim_required} = Exec.prepare_execution_window(open, receipt)

    drifted_receipt =
      put_in(receipt, ["checks", "compile", "stdout_sha256"], String.duplicate("e", 64))

    assert {:error, :static_receipt_drift} =
             Exec.prepare_execution_window(claimed, drifted_receipt)

    with_token = Map.put(window, "fence_token", @token)
    assert {:error, :malformed_envelope} = Exec.admit_execution_window(with_token, receipt)
  end

  test "progress constructs completed, failed, and capacity_handoff and admits arbitrarily" do
    {claimed, digest, receipt} = claimed_with_receipt()
    {:ok, window} = Exec.prepare_execution_window(claimed, receipt)
    [first, second] = plan()

    completed_obs = %{
      "new_receipts" => [passed(first), passed(second)],
      "disposition" => %{"type" => "completed"}
    }

    {:ok, completed} = Exec.new_progress(window, receipt, completed_obs)
    assert Enum.sort(Map.keys(completed)) == expected_progress_keys()
    assert completed["disposition"] == %{"type" => "completed"}
    assert completed["new_receipts"] == [passed(first), passed(second)]
    assert completed["continuation_id"] == window["continuation_id"]
    assert completed["owner_id"] == window["owner_id"]
    assert completed["fence_generation"] == window["fence_generation"]
    assert completed["static_stage_receipt_digest"] == digest
    assert {:ok, ^completed} = Exec.admit_progress(window, receipt, completed)
    refute_token_leak(completed)

    fail_reason = String.duplicate("\"\\", 128)
    assert byte_size(fail_reason) == 256

    failed_obs = %{
      "new_receipts" => [],
      "disposition" => %{"type" => "failed", "reason" => fail_reason}
    }

    {:ok, failed} = Exec.new_progress(window, receipt, failed_obs)
    assert failed["disposition"] == %{"type" => "failed", "reason" => fail_reason}
    assert {:ok, encoded_fail} = Jason.encode(failed)
    assert byte_size(encoded_fail) <= Exec.limits()["max_progress_json_bytes"]
    assert byte_size(Jason.encode!(fail_reason)) <= Exec.limits()["max_reason_json_bytes"]
    assert {:ok, ^failed} = Exec.admit_progress(window, receipt, failed)
    refute_token_leak(failed)

    structural = v3_handoff(plan(), [], nil, plan(), "structural")

    handoff_obs = %{
      "new_receipts" => [],
      "disposition" => %{"type" => "capacity_handoff", "capacity_handoff" => structural}
    }

    {:ok, handed} = Exec.new_progress(window, receipt, handoff_obs)
    assert handed["disposition"]["type"] == "capacity_handoff"
    assert handed["disposition"]["capacity_handoff"] == structural
    assert {:ok, canonical_handoff} = ValidationCapacityHandoff.normalize(structural)
    assert handed["disposition"]["capacity_handoff"] == canonical_handoff
    assert {:ok, ^handed} = Exec.admit_progress(window, receipt, handed)
    refute_token_leak(handed)
    assert claimed["status"] == "claimed"
    assert claimed["claim"]["fence_token"] == @token
  end

  test "progress replay rejects skipped receipts, incomplete complete, and bad handoff" do
    {claimed, _digest, receipt} = claimed_with_receipt()
    {:ok, window} = Exec.prepare_execution_window(claimed, receipt)
    [_first, second] = plan()

    skipped = %{
      "new_receipts" => [passed(second)],
      "disposition" => %{"type" => "completed"}
    }

    assert {:error, :skipped_receipt} = Exec.new_progress(window, receipt, skipped)

    incomplete = %{
      "new_receipts" => [],
      "disposition" => %{"type" => "completed"}
    }

    assert {:error, :incomplete_plan} = Exec.new_progress(window, receipt, incomplete)

    residual =
      Map.put(v3_handoff(plan(), [], nil, plan(), "structural"), "available_budget_ms", 1)

    bad_handoff = %{
      "new_receipts" => [],
      "disposition" => %{"type" => "capacity_handoff", "capacity_handoff" => residual}
    }

    assert {:error, :non_canonical_capacity_handoff} =
             Exec.new_progress(window, receipt, bad_handoff)
  end

  test "progress rejects oversized or illegal failure reasons and mixed observation keys" do
    {claimed, _digest, receipt} = claimed_with_receipt()
    {:ok, window} = Exec.prepare_execution_window(claimed, receipt)

    too_long = String.duplicate("x", 257)

    assert {:error, :malformed_envelope} =
             Exec.new_progress(
               window,
               receipt,
               %{
                 "new_receipts" => [],
                 "disposition" => %{"type" => "failed", "reason" => too_long}
               }
             )

    assert {:error, :malformed_envelope} =
             Exec.new_progress(
               window,
               receipt,
               %{
                 "new_receipts" => [],
                 "disposition" => %{"type" => "failed", "reason" => "bad\0reason"}
               }
             )

    assert {:error, :malformed_envelope} =
             Exec.new_progress(
               window,
               receipt,
               %{
                 "new_receipts" => [],
                 "disposition" => %{"type" => "failed", "reason" => "line\nbreak"}
               }
             )

    assert {:error, :malformed_envelope} =
             Exec.new_progress(
               window,
               receipt,
               %{new_receipts: [], disposition: %{"type" => "completed"}}
             )

    extra = %{
      "new_receipts" => [],
      "disposition" => %{"type" => "completed"},
      "fence_token" => @token
    }

    assert {:error, :malformed_envelope} = Exec.new_progress(window, receipt, extra)

    {:ok, progress} =
      Exec.new_progress(
        window,
        receipt,
        %{"new_receipts" => [], "disposition" => %{"type" => "failed", "reason" => "failed"}}
      )

    drifted = Map.put(progress, "continuation_id", "xappc_" <> String.duplicate("0", 64))
    assert {:error, :lineage_drift} = Exec.admit_progress(window, receipt, drifted)
  end

  test "claimed source state is unchanged after successful and failed replay" do
    {claimed, _digest, receipt} = claimed_with_receipt()
    snapshot = :erlang.term_to_binary(claimed)
    {:ok, window} = Exec.prepare_execution_window(claimed, receipt)
    [first, second] = plan()

    {:ok, _progress} =
      Exec.new_progress(
        window,
        receipt,
        %{
          "new_receipts" => [passed(first), passed(second)],
          "disposition" => %{"type" => "completed"}
        }
      )

    assert :erlang.term_to_binary(claimed) == snapshot

    assert {:error, :incomplete_plan} =
             Exec.new_progress(
               window,
               receipt,
               %{"new_receipts" => [], "disposition" => %{"type" => "completed"}}
             )

    assert :erlang.term_to_binary(claimed) == snapshot
    assert claimed["claim"]["fence_token"] == @token
  end

  test "progress is exactly the new prefix after the window accepted prefix" do
    {claimed, _digest, receipt} = claimed_with_receipt()
    [first, second] = plan()

    {:ok, after_first, _effects} =
      Core.accept_passed_receipt(claimed, %{
        "fence_token" => @token,
        "fence_generation" => claimed["fence_generation"],
        "now" => @claimed_at,
        "receipt" => passed(first)
      })

    {:ok, window} = Exec.prepare_execution_window(after_first, receipt)
    assert window["accepted_receipts"] == [passed(first)]

    assert {:ok, progress} =
             Exec.new_progress(window, receipt, %{
               "new_receipts" => [passed(second)],
               "disposition" => %{"type" => "completed"}
             })

    assert progress["new_receipts"] == [passed(second)]

    assert {:error, :duplicate_receipt} =
             Exec.new_progress(window, receipt, %{
               "new_receipts" => [passed(first)],
               "disposition" => %{"type" => "failed", "reason" => "duplicate"}
             })
  end

  test "progress rejects duplicate reordered contradictory and drifted bindings" do
    {claimed, _digest, receipt} = claimed_with_receipt()
    {:ok, window} = Exec.prepare_execution_window(claimed, receipt)
    [first, second] = plan()

    assert {:error, :duplicate_receipt} =
             Exec.new_progress(window, receipt, %{
               "new_receipts" => [passed(first), passed(first)],
               "disposition" => %{"type" => "failed", "reason" => "duplicate"}
             })

    reordered = second |> Map.put("index", 1) |> passed()

    assert {:error, :reordered_receipt} =
             Exec.new_progress(window, receipt, %{
               "new_receipts" => [reordered],
               "disposition" => %{"type" => "failed", "reason" => "reordered"}
             })

    contradictory = Map.put(passed(first), "outcome", "failed")

    assert {:error, :contradictory_receipt} =
             Exec.new_progress(window, receipt, %{
               "new_receipts" => [contradictory],
               "disposition" => %{"type" => "failed", "reason" => "contradictory"}
             })

    {:ok, progress} =
      Exec.new_progress(window, receipt, %{
        "new_receipts" => [],
        "disposition" => %{"type" => "failed", "reason" => "failed"}
      })

    assert {:error, :owner_drift} =
             Exec.admit_progress(window, receipt, Map.put(progress, "owner_id", "other"))

    assert {:error, :generation_drift} =
             Exec.admit_progress(
               window,
               receipt,
               Map.update!(progress, "fence_generation", &(&1 + 1))
             )

    assert {:error, :static_receipt_drift} =
             Exec.admit_progress(
               window,
               receipt,
               Map.put(progress, "static_stage_receipt_digest", String.duplicate("f", 64))
             )
  end

  test "window admission rejects receipt identity drift and malformed closed shapes" do
    {claimed, _digest, receipt} = claimed_with_receipt()
    {:ok, window} = Exec.prepare_execution_window(claimed, receipt)

    other_identities = Map.put(receipt["identities"], "task_id", "task_other")

    {:ok, other_receipt, _other_digest} =
      Exec.new_static_stage_receipt(other_identities, successful_checks())

    assert {:error, :static_receipt_drift} =
             Exec.admit_execution_window(window, other_receipt)

    assert {:error, :malformed_envelope} =
             Exec.admit_execution_window(Map.put(window, "extra", true), receipt)

    nested_secret =
      put_in(
        window,
        ["capacity_handoff"],
        %{"credential" => "not-authority-free"}
      )

    assert {:error, :malformed_envelope} =
             Exec.admit_execution_window(nested_secret, receipt)
  end

  test "production execution core contains no side-effect calls" do
    source =
      Path.expand(
        "../../../../lib/arbor/actions/coding/cross_app_continuation_execution_core.ex",
        __DIR__
      )
      |> File.read!()

    for forbidden <- [
          "File.",
          "System.",
          "Application.",
          "Registry.",
          "GenServer.",
          "Process.",
          ":ets.",
          "DateTime.utc_now",
          "make_ref",
          "strong_rand_bytes",
          "String.to_atom",
          "IO."
        ] do
      refute source =~ forbidden, "execution core must not call #{forbidden}"
    end
  end

  defp expected_check_keys do
    Enum.sort(~w(
      exit_code passed reason status
      stderr_excerpt stderr_sha256 stderr_truncated
      stdout_excerpt stdout_sha256 stdout_truncated
    ))
  end

  defp expected_static_receipt_ceiling(limits) do
    empty_object_bytes = byte_size(Jason.encode!(%{}))
    empty_string_bytes = byte_size(Jason.encode!(""))

    fixture = %{
      "schema_version" => 1,
      "continuation_id" => "",
      "identities" => %{},
      "checks" => %{"compile" => %{}, "xref" => %{}, "test_compile" => %{}}
    }

    fixed =
      byte_size(Jason.encode!(fixture)) - 4 * empty_object_bytes - empty_string_bytes

    fixed + limits["max_continuation_id_json_bytes"] + limits["max_identities_json_bytes"] +
      3 * limits["max_check_json_bytes"]
  end

  defp expected_progress_ceiling(limits) do
    empty_object_bytes = byte_size(Jason.encode!(%{}))
    empty_list_bytes = byte_size(Jason.encode!([]))
    empty_string_bytes = byte_size(Jason.encode!(""))

    fixture = %{
      "schema_version" => 1,
      "continuation_id" => "xappc_" <> String.duplicate("0", 64),
      "owner_id" => "",
      "fence_generation" => 1_000_000,
      "static_stage_receipt_digest" => String.duplicate("0", 64),
      "new_receipts" => [],
      "disposition" => %{}
    }

    fixed =
      byte_size(Jason.encode!(fixture)) - empty_string_bytes - empty_list_bytes -
        empty_object_bytes

    capacity_fixed =
      byte_size(Jason.encode!(%{"type" => "capacity_handoff", "capacity_handoff" => %{}})) -
        empty_object_bytes

    failure_fixed =
      byte_size(Jason.encode!(%{"type" => "failed", "reason" => ""})) -
        empty_string_bytes

    disposition_max =
      max(
        limits["max_handoff_json_bytes"] + capacity_fixed,
        max(
          limits["max_reason_json_bytes"] + failure_fixed,
          byte_size(Jason.encode!(%{"type" => "completed"}))
        )
      )

    fixed + limits["max_identifier_json_bytes"] + limits["max_receipts_json_bytes"] +
      disposition_max
  end

  defp expected_window_keys do
    Enum.sort(~w(
      accepted_receipts capacity_handoff claimed_at continuation_id expires_at
      fence_generation identities owner_id per_batch_budget_ms planned_batches
      schema_version static_stage_receipt_digest
    ))
  end

  defp expected_progress_keys do
    Enum.sort(~w(
      continuation_id disposition fence_generation new_receipts owner_id
      schema_version static_stage_receipt_digest
    ))
  end

  defp successful_checks(opts \\ []) do
    excerpt = Keyword.get(opts, :heavy_excerpt, "")
    check = hd_check(excerpt)
    %{"compile" => check, "xref" => check, "test_compile" => check}
  end

  defp hd_check(excerpt \\ "") do
    %{
      "status" => "completed",
      "passed" => true,
      "exit_code" => 0,
      "reason" => nil,
      "stdout_excerpt" => excerpt,
      "stderr_excerpt" => excerpt,
      "stdout_truncated" => excerpt != "",
      "stderr_truncated" => excerpt != "",
      "stdout_sha256" => @empty_sha,
      "stderr_sha256" => String.duplicate("b", 64)
    }
  end

  defp claimed_with_receipt do
    identities = identities(plan())
    {:ok, receipt, digest} = Exec.new_static_stage_receipt(identities, successful_checks())
    {:ok, open} = Core.new(fresh_attrs(%{"static_stage_receipt_digest" => digest}))
    {:ok, claimed, _effects} = Core.claim(open, claim_attrs())
    {claimed, digest, receipt}
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

  defp identities(plan) do
    {:ok, digest} = ValidationCapacityHandoff.ordered_plan_digest(plan)

    %{
      "task_id" => "task_continuation_slice1",
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

  defp fresh_attrs(extra) do
    plan = plan()

    Map.merge(
      %{
        "identities" => identities(plan),
        "planned_batches" => plan,
        "per_batch_budget_ms" => 1_000,
        "static_stage_receipt_digest" => String.duplicate("d", 64)
      },
      extra
    )
  end

  defp claim_attrs do
    %{
      "fence_token" => @token,
      "claimed_at" => @claimed_at,
      "expires_at" => @expires_at,
      "now" => @claimed_at
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

  defp shuffle_map(map) when is_map(map) do
    map |> Enum.shuffle() |> Map.new()
  end

  defp refute_token_leak(envelope) do
    encoded = Jason.encode!(envelope)
    refute encoded =~ "fence_token"
    refute encoded =~ @token
    refute encoded =~ "authority"
    refute Map.has_key?(envelope, "fence_token")
    refute Map.has_key?(envelope, "token")
    refute Map.has_key?(envelope, "authority")
  end
end
