defmodule Arbor.Actions.Coding.CrossApp.ContinuationCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.CrossApp.ContinuationCore, as: Core
  alias Arbor.Contracts.Coding.ValidationCapacityHandoff

  @moduletag :fast

  @inv1 String.duplicate("a", 64)
  @inv2 String.duplicate("b", 64)
  @hex String.duplicate("c", 64)
  @token "fence-token-1"
  @claimed_at "2026-08-27T12:00:00Z"
  @mid "2026-08-27T12:30:00Z"
  @expires_at "2026-08-27T13:00:00Z"
  @after_expiry "2026-08-27T14:00:00Z"
  @later_expires "2026-08-27T15:00:00Z"
  @base_oid String.duplicate("1", 40)
  @base_tree_oid String.duplicate("2", 40)
  @candidate_tree_oid String.duplicate("3", 40)

  test "new/1 binds identities, equal candidate_head, and round-trips show/1" do
    plan = plan()
    {:ok, expected_digest} = ValidationCapacityHandoff.ordered_plan_digest(plan)
    {:ok, state} = Core.new(fresh_attrs())

    assert state["schema_version"] == 1
    assert state["status"] == "open"
    assert state["claim"] == nil
    assert state["fence_generation"] == 0
    assert state["accepted_receipts"] == []
    assert state["capacity_handoff"] == nil
    assert state["terminal_reason"] == nil
    assert state["planned_batches"] == plan
    assert state["identities"]["candidate_head"] == state["identities"]["base_commit"]
    assert state["identities"]["candidate_tree_oid"] != state["identities"]["base_tree_oid"]
    assert state["identities"]["validation_plan_digest"] == expected_digest
    assert state["identities"]["work_packet_digest"] == "sha256:" <> @hex
    assert state["identities"]["principal_id"] != state["identities"]["validator_id"]
    assert {:ok, _} = Jason.encode(Core.show(state))
    assert Core.new(Core.show(state)) == {:ok, state}

    raw_packet =
      Map.put(fresh_attrs(), "identities", Map.put(identities(plan), "work_packet_digest", @hex))

    assert {:error, :malformed_state} = Core.new(raw_packet)

    with_commit = Map.put(identities(plan), "candidate_commit", String.duplicate("9", 40))

    assert {:error, :malformed_state} =
             Core.new(Map.put(fresh_attrs(), "identities", with_commit))
  end

  test "new/1 rejects mixed keys, identity gaps, paths, order, digest mismatch, and extra fields" do
    plan = plan()

    mixed = Map.put(fresh_attrs(), :planned_batches, plan)
    assert {:error, :malformed_state} = Core.new(mixed)

    missing = identities(plan) |> Map.delete("principal_id")
    assert {:error, :malformed_state} = Core.new(Map.put(fresh_attrs(), "identities", missing))

    extra = identities(plan) |> Map.put("extra", "nope")
    assert {:error, :malformed_state} = Core.new(Map.put(fresh_attrs(), "identities", extra))

    with_paths = [Map.put(hd(plan), "paths", ["apps/a/test/a_test.exs"]) | tl(plan)]

    assert {:error, :invalid_batch_plan} =
             Core.new(Map.put(fresh_attrs(), "planned_batches", with_paths))

    non_contiguous = [batch(1, 2, 1, @inv1), batch(3, 2, 1, @inv2)]

    assert {:error, :invalid_batch_plan} =
             Core.new(Map.put(fresh_attrs(), "planned_batches", non_contiguous))

    drifted = Map.put(identities(plan), "validation_plan_digest", String.duplicate("e", 64))
    assert {:error, :identity_drift} = Core.new(Map.put(fresh_attrs(), "identities", drifted))

    assert is_integer(Core.max_json_bytes())
    {:ok, state} = Core.new(fresh_attrs())
    assert byte_size(Jason.encode!(Core.show(state))) <= Core.max_json_bytes()
  end

  test "claim is principal-owned, assigns generation 1, and rejects a second window" do
    {:ok, open} = Core.new(fresh_attrs())

    assert {:error, :identity_drift} =
             Core.claim(
               open,
               claim_attrs(%{"owner_id" => identities(plan())["validator_id"]})
             )

    assert {:ok, claimed, [%{"op" => "persist"}]} = Core.claim(open, claim_attrs())
    assert claimed["status"] == "claimed"
    assert claimed["fence_generation"] == 1
    assert claimed["claim"]["owner_id"] == claimed["identities"]["principal_id"]
    assert claimed["claim"]["fence_generation"] == 1
    assert {:error, :claim_active} = Core.claim(claimed, claim_attrs())
  end

  test "ordered receipts persist and generation plus token fence ABA reuse" do
    claimed = claimed_state()
    [first, second] = plan()

    assert {:ok, after_first, [%{"op" => "persist"}]} =
             Core.accept_passed_receipt(
               claimed,
               fence(claimed, @mid, %{"receipt" => passed(first)})
             )

    assert Enum.map(after_first["accepted_receipts"], & &1["index"]) == [1]

    assert {:ok, after_second, [%{"op" => "persist"}]} =
             Core.accept_passed_receipt(
               after_first,
               fence(after_first, @mid, %{"receipt" => passed(second)})
             )

    assert length(after_second["accepted_receipts"]) == 2

    assert {:error, :wrong_fence} =
             Core.accept_passed_receipt(
               after_second,
               fence(after_second, @mid, %{
                 "fence_token" => "other-token",
                 "receipt" => passed(first)
               })
             )

    {:ok, expired, _} = Core.expire_claim(after_second, fence(after_second, @after_expiry))
    {:ok, reclaimed, _} = Core.claim(expired, reclaim_attrs())
    assert reclaimed["fence_generation"] == 2
    assert reclaimed["claim"]["fence_token"] == @token

    assert {:error, :stale_fence} =
             Core.accept_passed_receipt(
               reclaimed,
               %{
                 "fence_token" => @token,
                 "fence_generation" => 1,
                 "now" => @after_expiry,
                 "receipt" => passed(first)
               }
             )
  end

  test "receipt errors follow duplicate, skipped, reordered, then contradictory precedence" do
    claimed = claimed_state()
    [first, second] = plan()

    {:ok, after_first, _} =
      Core.accept_passed_receipt(
        claimed,
        fence(claimed, @mid, %{"receipt" => passed(first)})
      )

    duplicate =
      second
      |> Map.put("index", 1)
      |> passed()

    assert {:error, :duplicate_receipt} =
             Core.accept_passed_receipt(
               after_first,
               fence(after_first, @mid, %{"receipt" => duplicate})
             )

    skipped = passed(second)
    assert skipped["index"] == 2

    assert {:error, :skipped_receipt} =
             Core.accept_passed_receipt(
               claimed,
               fence(claimed, @mid, %{"receipt" => skipped})
             )

    reordered = passed(Map.put(second, "index", 1))

    assert {:error, :reordered_receipt} =
             Core.accept_passed_receipt(
               claimed,
               fence(claimed, @mid, %{"receipt" => reordered})
             )

    contradictory = Map.put(passed(first), "outcome", "failed")

    assert {:error, :contradictory_receipt} =
             Core.accept_passed_receipt(
               claimed,
               fence(claimed, @mid, %{"receipt" => contradictory})
             )
  end

  test "canonical v3 handoffs emit persist and mint_successor and reject non-canonical evidence" do
    claimed = claimed_state()
    plan = plan()
    structural = v3_handoff(plan, [], nil, plan, "structural")

    assert {:ok, handed, effects} =
             Core.accept_capacity_handoff(
               claimed,
               fence(claimed, @mid, %{"handoff" => structural})
             )

    assert [%{"op" => "persist"}, %{"op" => "mint_successor"} = mint] = effects
    assert handed["status"] == "open"
    assert handed["claim"] == nil
    assert handed["fence_generation"] == 1
    assert mint["fence_generation"] == 1
    assert mint["remaining_batches"] == plan
    assert mint["static_stage_receipt_digest"] == handed["static_stage_receipt_digest"]
    refute Enum.any?(mint["remaining_batches"], &Map.has_key?(&1, "paths"))
    assert byte_size(Jason.encode!(effects)) <= Core.limits()["max_effects_json_bytes"]
    assert byte_size(Jason.encode!(hd(effects))) <= Core.limits()["max_persist_effect_bytes"]
    assert byte_size(Jason.encode!(mint)) <= Core.limits()["max_mint_effect_bytes"]

    [first, second] = plan
    interrupted = v3_handoff(plan, [], first, [second], "runtime")
    claimed2 = claimed_state()

    assert {:ok, runtime, runtime_effects} =
             Core.accept_capacity_handoff(
               claimed2,
               fence(claimed2, @mid, %{"handoff" => interrupted})
             )

    assert [%{"op" => "persist"}, %{"op" => "mint_successor"} = runtime_mint] = runtime_effects
    assert runtime_mint["remaining_batches"] == [first, second]
    assert runtime["capacity_handoff"]["interrupted_batch"]["index"] == 1

    residual = Map.put(structural, "available_budget_ms", 1)

    assert {:error, :non_canonical_capacity_handoff} =
             Core.accept_capacity_handoff(
               claimed,
               fence(claimed, @mid, %{"handoff" => residual})
             )

    v1 = Map.put(structural, "schema_version", 1)

    assert {:error, :non_canonical_capacity_handoff} =
             Core.accept_capacity_handoff(claimed, fence(claimed, @mid, %{"handoff" => v1}))

    v2 = Map.put(structural, "schema_version", 2)

    assert {:error, :non_canonical_capacity_handoff} =
             Core.accept_capacity_handoff(claimed, fence(claimed, @mid, %{"handoff" => v2}))

    wrapper = %{
      "passed" => false,
      "reason" => "validation_capacity_exceeded",
      "capacity_handoff" => structural
    }

    assert {:error, :non_canonical_capacity_handoff} =
             Core.accept_capacity_handoff(claimed, fence(claimed, @mid, %{"handoff" => wrapper}))

    other_plan = [
      batch(1, 2, 1, String.duplicate("8", 64)),
      batch(2, 2, 1, String.duplicate("9", 64))
    ]

    wrong_suffix = v3_handoff(other_plan, [], nil, other_plan, "structural")

    assert {:error, :non_canonical_capacity_handoff} =
             Core.accept_capacity_handoff(
               claimed,
               fence(claimed, @mid, %{"handoff" => wrong_suffix})
             )

    mismatched_counts = v3_handoff(plan, [first], nil, [second], "runtime")

    assert {:error, :non_canonical_capacity_handoff} =
             Core.accept_capacity_handoff(
               claimed,
               fence(claimed, @mid, %{"handoff" => mismatched_counts})
             )
  end

  test "fail and cancel persist a terminal effect and reject later receipts" do
    claimed = claimed_state()
    [first | _] = plan()

    assert {:ok, failed, effects} = Core.fail(claimed, fence(claimed, @mid))
    assert [%{"op" => "persist"}, %{"op" => "terminal", "status" => "failed"}] = effects
    assert failed["status"] == "failed"
    assert failed["claim"] == nil
    assert failed["fence_generation"] == 1

    assert {:error, :terminal_state} =
             Core.accept_passed_receipt(failed, %{
               "fence_token" => @token,
               "fence_generation" => 1,
               "now" => @mid,
               "receipt" => passed(first)
             })

    claimed2 = claimed_state()
    assert {:ok, cancelled, cancel_effects} = Core.cancel(claimed2, fence(claimed2, @mid))
    assert [%{"op" => "persist"}, %{"op" => "terminal", "status" => "cancelled"}] = cancel_effects
    assert cancelled["status"] == "cancelled"
  end

  test "complete requires a live matching claim after every planned batch has one receipt" do
    claimed = claimed_state()
    [first, second] = plan()
    assert {:error, :incomplete_plan} = Core.complete(claimed, fence(claimed, @mid))

    {:ok, after_first, _} =
      Core.accept_passed_receipt(
        claimed,
        fence(claimed, @mid, %{"receipt" => passed(first)})
      )

    assert {:error, :incomplete_plan} = Core.complete(after_first, fence(after_first, @mid))

    {:ok, full, _} =
      Core.accept_passed_receipt(
        after_first,
        fence(after_first, @mid, %{"receipt" => passed(second)})
      )

    {:ok, open, _} = Core.revoke_claim(full, fence(full, @mid))
    assert open["status"] == "open"
    assert open["fence_generation"] == 1
    assert length(open["accepted_receipts"]) == 2

    assert {:error, :claim_required} =
             Core.complete(open, %{
               "fence_token" => @token,
               "fence_generation" => 1,
               "now" => @mid
             })

    {:ok, reclaimed, _} =
      Core.claim(open, reclaim_attrs(%{"now" => @mid, "claimed_at" => @mid}))

    assert reclaimed["fence_generation"] == 2

    assert {:ok, completed, effects} = Core.complete(reclaimed, fence(reclaimed, @mid))

    assert [
             %{"op" => "persist"},
             %{"op" => "terminal", "status" => "completed", "reason" => nil}
           ] = effects

    refute Enum.any?(effects, &(&1["op"] == "mint_successor"))
    assert completed["status"] == "completed"
    assert completed["claim"] == nil
    assert completed["fence_generation"] == 2
  end

  test "identity drift on a transition is rejected before effects" do
    claimed = claimed_state()
    [first | _] = plan()

    assert {:error, :identity_drift} =
             Core.accept_passed_receipt(
               claimed,
               fence(claimed, @mid, %{"receipt" => passed(first), "task_id" => "task_other"})
             )
  end

  test "now equal to expires_at splits live mutations from expire and revoke" do
    claimed = claimed_state()
    [first | _] = plan()
    at_expiry = fence(claimed, @expires_at, %{"receipt" => passed(first)})
    plan = plan()
    structural = v3_handoff(plan, [], nil, plan, "structural")

    assert {:error, :stale_fence} = Core.accept_passed_receipt(claimed, at_expiry)

    assert {:error, :stale_fence} =
             Core.accept_capacity_handoff(
               claimed,
               fence(claimed, @expires_at, %{"handoff" => structural})
             )

    assert {:error, :stale_fence} = Core.fail(claimed, fence(claimed, @expires_at))
    assert {:error, :stale_fence} = Core.cancel(claimed, fence(claimed, @expires_at))
    assert {:error, :stale_fence} = Core.complete(claimed, fence(claimed, @expires_at))

    assert {:ok, expired, [%{"op" => "persist"}]} =
             Core.expire_claim(claimed, fence(claimed, @expires_at))

    assert expired["claim"] == nil
    assert expired["status"] == "open"
    assert expired["fence_generation"] == 1

    claimed2 = claimed_state()

    assert {:ok, revoked, [%{"op" => "persist"}]} =
             Core.revoke_claim(claimed2, fence(claimed2, @expires_at))

    assert revoked["claim"] == nil
    assert revoked["status"] == "open"
  end

  test "expired revoke is time-independent and live mutations stay stale after expiry" do
    claimed = claimed_state()
    [first | _] = plan()

    assert {:error, :stale_fence} =
             Core.accept_passed_receipt(
               claimed,
               fence(claimed, @after_expiry, %{"receipt" => passed(first)})
             )

    assert {:ok, expired, [%{"op" => "persist"}]} =
             Core.expire_claim(claimed, fence(claimed, @after_expiry))

    assert expired["claim"] == nil

    claimed2 = claimed_state()

    assert {:ok, revoked, [%{"op" => "persist"}]} =
             Core.revoke_claim(claimed2, fence(claimed2, @after_expiry))

    assert revoked["claim"] == nil
    assert revoked["fence_generation"] == 1
  end

  test "expire before expiry is :not_expired while revoke still clears" do
    claimed = claimed_state()
    assert {:error, :not_expired} = Core.expire_claim(claimed, fence(claimed, @mid))
    assert claimed["claim"] != nil

    assert {:ok, revoked, [%{"op" => "persist"}]} =
             Core.revoke_claim(claimed, fence(claimed, @mid))

    assert revoked["claim"] == nil
    assert revoked["status"] == "open"
  end

  test "wrong token never expires or revokes, expired or not" do
    claimed = claimed_state()
    wrong = fence(claimed, @mid, %{"fence_token" => "wrong-token"})
    assert {:error, :wrong_fence} = Core.expire_claim(claimed, wrong)
    assert {:error, :wrong_fence} = Core.revoke_claim(claimed, wrong)

    expired_wrong = fence(claimed, @after_expiry, %{"fence_token" => "wrong-token"})
    assert {:error, :wrong_fence} = Core.expire_claim(claimed, expired_wrong)
    assert {:error, :wrong_fence} = Core.revoke_claim(claimed, expired_wrong)
  end

  test "stale generation after reclaim is :stale_fence even when the token is reused" do
    claimed = claimed_state()
    {:ok, expired, _} = Core.expire_claim(claimed, fence(claimed, @after_expiry))
    {:ok, reclaimed, _} = Core.claim(expired, reclaim_attrs())
    assert reclaimed["fence_generation"] == 2
    assert reclaimed["claim"]["fence_token"] == @token

    stale = %{
      "fence_token" => @token,
      "fence_generation" => 1,
      "now" => @after_expiry
    }

    assert {:error, :stale_fence} = Core.expire_claim(reclaimed, stale)
    assert {:error, :stale_fence} = Core.revoke_claim(reclaimed, stale)
  end

  test "show/1 fails closed on non-map input" do
    assert {:error, :malformed_state} = Core.show(nil)
    assert {:error, :malformed_state} = Core.show([])
  end

  test "lineage_key/1 is stable under shuffled identity keys and changes with identity" do
    {:ok, state} = Core.new(fresh_attrs())
    {:ok, key} = Core.lineage_key(state)
    assert key =~ ~r/\Axappc_[0-9a-f]{64}\z/

    shuffled =
      state["identities"]
      |> Enum.shuffle()
      |> Map.new()

    {:ok, shuffled_key} = Core.lineage_key(Map.put(state, "identities", shuffled))
    assert shuffled_key == key

    drifted = put_in(state, ["identities", "task_id"], "task_other_lineage")
    {:ok, other} = Core.lineage_key(drifted)
    assert other != key
    assert {:error, :malformed_state} = Core.lineage_key(nil)
  end

  test "retained_effects/1 match persist-only, mint_successor, and terminal Core outputs" do
    {:ok, open} = Core.new(fresh_attrs())
    {:ok, claimed, persist_effects} = Core.claim(open, claim_attrs())
    {:ok, claimed_retained} = Core.retained_effects(claimed)
    assert persist_effects == [claimed_retained["persist"]]
    assert claimed_retained["successor"] == nil
    assert claimed_retained["terminal"] == nil
    assert claimed_retained["snapshot"] == claimed

    plan = plan()
    structural = v3_handoff(plan, [], nil, plan, "structural")

    {:ok, handed, mint_effects} =
      Core.accept_capacity_handoff(claimed, fence(claimed, @mid, %{"handoff" => structural}))

    {:ok, handed_retained} = Core.retained_effects(handed)
    assert [%{"op" => "persist"}, mint] = mint_effects
    assert handed_retained["persist"]["snapshot"] == handed
    assert handed_retained["successor"] == mint
    assert handed_retained["terminal"] == nil

    {:ok, failed, fail_effects} = Core.fail(claimed_state(), fence(claimed_state(), @mid))
    {:ok, failed_retained} = Core.retained_effects(failed)
    assert [%{"op" => "persist"}, terminal] = fail_effects
    assert failed_retained["terminal"] == terminal
    assert failed_retained["successor"] == nil

    {:ok, cancelled, cancel_effects} =
      Core.cancel(claimed_state(), fence(claimed_state(), @mid))

    {:ok, cancelled_retained} = Core.retained_effects(cancelled)
    assert [%{"op" => "persist"}, cancel_terminal] = cancel_effects
    assert cancelled_retained["terminal"] == cancel_terminal
  end

  test "candidate_head must equal base_commit; candidate_tree_oid may differ" do
    plan = plan()
    drifted_head = Map.put(identities(plan), "candidate_head", String.duplicate("7", 40))

    assert {:error, :identity_drift} =
             Core.new(Map.put(fresh_attrs(), "identities", drifted_head))

    {:ok, state} = Core.new(fresh_attrs())
    assert state["identities"]["candidate_head"] == state["identities"]["base_commit"]
    assert state["identities"]["candidate_tree_oid"] == @candidate_tree_oid
    assert state["identities"]["base_tree_oid"] == @base_tree_oid
    assert state["identities"]["candidate_tree_oid"] != state["identities"]["base_tree_oid"]
  end

  test "claim/2 rejects inverted, expired, and zero-length windows" do
    {:ok, open} = Core.new(fresh_attrs())

    assert {:error, :malformed_state} =
             Core.claim(open, claim_attrs(%{"claimed_at" => @after_expiry, "now" => @claimed_at}))

    assert {:error, :malformed_state} =
             Core.claim(open, claim_attrs(%{"now" => @expires_at}))

    assert {:error, :malformed_state} =
             Core.claim(open, claim_attrs(%{"now" => @after_expiry}))

    assert {:error, :malformed_state} =
             Core.claim(open, claim_attrs(%{"expires_at" => @claimed_at}))
  end

  test "rehydration binds stored handoffs to this plan and receipt prefix" do
    claimed = claimed_state()
    plan = plan()
    structural = v3_handoff(plan, [], nil, plan, "structural")

    {:ok, handed, _} =
      Core.accept_capacity_handoff(
        claimed,
        fence(claimed, @mid, %{"handoff" => structural})
      )

    assert Core.new(Core.show(handed)) == {:ok, handed}

    {:ok, reclaimed, _} =
      Core.claim(handed, reclaim_attrs(%{"now" => @mid, "claimed_at" => @mid}))

    [first, second] = plan

    {:ok, after_first, _} =
      Core.accept_passed_receipt(
        reclaimed,
        fence(reclaimed, @mid, %{"receipt" => passed(first)})
      )

    {:ok, continued, _} =
      Core.accept_passed_receipt(
        after_first,
        fence(after_first, @mid, %{"receipt" => passed(second)})
      )

    assert Core.new(Core.show(continued)) == {:ok, continued}

    other_plan = [
      batch(1, 2, 1, String.duplicate("8", 64)),
      batch(2, 2, 1, String.duplicate("9", 64))
    ]

    other = v3_handoff(other_plan, [], nil, other_plan, "structural")
    snapshot = Core.show(handed)

    assert {:error, :malformed_state} =
             Core.new(Map.put(snapshot, "capacity_handoff", other))

    mismatched = v3_handoff(plan, [first], nil, [second], "runtime")

    assert {:error, :malformed_state} =
             Core.new(Map.put(snapshot, "capacity_handoff", mismatched))

    interrupted = v3_handoff(other_plan, [], hd(other_plan), tl(other_plan), "runtime")

    assert {:error, :malformed_state} =
             Core.new(Map.put(snapshot, "capacity_handoff", interrupted))
  end

  test "security regression: tampered nested snapshot fields cannot emit transition effects" do
    claimed = claimed_state()
    [first, second] = plan()
    claimed_snap = Core.show(claimed)
    structural = v3_handoff(plan(), [], nil, plan(), "structural")

    other_plan = [
      batch(1, 2, 1, String.duplicate("8", 64)),
      batch(2, 2, 1, String.duplicate("9", 64))
    ]

    other_handoff = v3_handoff(other_plan, [], nil, other_plan, "structural")

    {:ok, open} = Core.new(fresh_attrs())
    open_snap = Core.show(open)

    forged_open_head =
      put_in(open_snap, ["identities", "candidate_head"], String.duplicate("7", 40))

    assert {:error, :identity_drift} = Core.claim(forged_open_head, claim_attrs())

    forged_head =
      put_in(claimed_snap, ["identities", "candidate_head"], String.duplicate("7", 40))

    assert {:error, :identity_drift} =
             Core.accept_passed_receipt(
               forged_head,
               fence(claimed, @mid, %{"receipt" => passed(first)})
             )

    assert {:error, :identity_drift} =
             Core.accept_capacity_handoff(
               forged_head,
               fence(claimed, @mid, %{"handoff" => structural})
             )

    forged_plan = Map.put(claimed_snap, "planned_batches", other_plan)

    assert {:error, :identity_drift} =
             Core.accept_capacity_handoff(
               forged_plan,
               fence(claimed, @mid, %{"handoff" => other_handoff})
             )

    assert {:error, :identity_drift} = Core.expire_claim(forged_plan, fence(claimed, @mid))

    forged_receipts = Map.put(claimed_snap, "accepted_receipts", [passed(second)])
    assert {:error, :malformed_state} = Core.expire_claim(forged_receipts, fence(claimed, @mid))

    forged_owner =
      put_in(claimed_snap, ["claim", "owner_id"], identities(plan())["validator_id"])

    assert {:error, :malformed_state} =
             Core.accept_passed_receipt(
               forged_owner,
               fence(claimed, @mid, %{"receipt" => passed(first)})
             )

    forged_token = put_in(claimed_snap, ["claim", "fence_token"], "not a token")
    assert {:error, :malformed_state} = Core.expire_claim(forged_token, fence(claimed, @mid))

    forged_gen = put_in(claimed_snap, ["claim", "fence_generation"], 99)

    assert {:error, :malformed_state} =
             Core.accept_passed_receipt(
               forged_gen,
               fence(forged_gen, @mid, %{"receipt" => passed(first)})
             )

    forged_window = put_in(claimed_snap, ["claim", "claimed_at"], @later_expires)

    assert {:error, :malformed_state} =
             Core.accept_passed_receipt(
               forged_window,
               fence(claimed, @mid, %{"receipt" => passed(first)})
             )

    {:ok, handed, _} =
      Core.accept_capacity_handoff(
        claimed,
        fence(claimed, @mid, %{"handoff" => structural})
      )

    handed_snap = Core.show(handed)
    forged_handoff = Map.put(handed_snap, "capacity_handoff", other_handoff)

    assert {:error, :malformed_state} =
             Core.claim(forged_handoff, reclaim_attrs(%{"now" => @mid, "claimed_at" => @mid}))
  end

  test "new/1 rejects reachable oversized identities, plan, receipts, claim, and handoff JSON" do
    pad = String.duplicate("x", 5_000)
    padded_ids = Map.put(identities(plan()), "pad", pad)
    assert {:error, :oversized_state} = Core.new(Map.put(fresh_attrs(), "identities", padded_ids))

    junk_plan =
      Enum.map(1..2_000, fn i ->
        %{"pad" => String.duplicate("x", 200), "n" => i}
      end)

    assert {:error, :oversized_state} =
             Core.new(Map.put(fresh_attrs(), "planned_batches", junk_plan))

    {:ok, open} = Core.new(fresh_attrs())
    snapshot = Core.show(open)

    junk_receipts =
      Enum.map(1..2_000, fn i ->
        %{"pad" => String.duplicate("x", 200), "n" => i}
      end)

    assert {:error, :oversized_state} =
             Core.new(Map.put(snapshot, "accepted_receipts", junk_receipts))

    claimed = claimed_state()
    claimed_snapshot = Core.show(claimed)
    padded_claim = Map.put(claimed_snapshot["claim"], "pad", String.duplicate("x", 2_000))

    assert {:error, :oversized_state} =
             Core.new(Map.put(claimed_snapshot, "claim", padded_claim))

    huge_handoff = %{"pad" => String.duplicate("x", 300_000)}

    assert {:error, :oversized_state} =
             Core.new(Map.put(snapshot, "capacity_handoff", huge_handoff))

    assert byte_size(Jason.encode!(snapshot)) <= Core.max_json_bytes()
  end

  test "persist mint and terminal effects stay under documented ceilings" do
    claimed = claimed_state()
    plan = plan()
    structural = v3_handoff(plan, [], nil, plan, "structural")

    {:ok, _handed, mint_effects} =
      Core.accept_capacity_handoff(
        claimed,
        fence(claimed, @mid, %{"handoff" => structural})
      )

    assert byte_size(Jason.encode!(mint_effects)) <= Core.limits()["max_effects_json_bytes"]
    persist = Enum.find(mint_effects, &(&1["op"] == "persist"))
    mint = Enum.find(mint_effects, &(&1["op"] == "mint_successor"))
    assert byte_size(Jason.encode!(persist)) <= Core.limits()["max_persist_effect_bytes"]
    assert byte_size(Jason.encode!(mint)) <= Core.limits()["max_mint_effect_bytes"]

    failed_state = claimed_state()

    {:ok, _failed, fail_effects} =
      Core.fail(failed_state, fence(failed_state, @mid))

    terminal = Enum.find(fail_effects, &(&1["op"] == "terminal"))
    assert byte_size(Jason.encode!(terminal)) <= Core.limits()["max_terminal_effect_bytes"]
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

  defp fresh_attrs do
    plan = plan()

    %{
      "identities" => identities(plan),
      "planned_batches" => plan,
      "per_batch_budget_ms" => 1_000,
      "static_stage_receipt_digest" => String.duplicate("d", 64)
    }
  end

  defp claim_attrs(extra \\ %{}) do
    Map.merge(
      %{
        "fence_token" => @token,
        "claimed_at" => @claimed_at,
        "expires_at" => @expires_at,
        "now" => @claimed_at
      },
      extra
    )
  end

  defp reclaim_attrs(extra \\ %{}) do
    Map.merge(
      %{
        "fence_token" => @token,
        "claimed_at" => @after_expiry,
        "expires_at" => @later_expires,
        "now" => @after_expiry
      },
      extra
    )
  end

  defp claimed_state do
    {:ok, open} = Core.new(fresh_attrs())
    {:ok, claimed, _effects} = Core.claim(open, claim_attrs())
    claimed
  end

  defp fence(state, now, extra \\ %{}) do
    Map.merge(
      %{
        "fence_token" => state["claim"]["fence_token"],
        "fence_generation" => state["claim"]["fence_generation"] || state["fence_generation"],
        "now" => now
      },
      extra
    )
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
end
