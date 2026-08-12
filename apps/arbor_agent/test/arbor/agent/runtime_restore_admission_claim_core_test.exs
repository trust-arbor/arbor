defmodule Arbor.Agent.RuntimeRestoreAdmissionClaimCoreTest do
  @moduledoc """
  Pure unit tests for RuntimeRestoreAdmissionClaimCore (C3C1a1).

  Token generation is shell-owned; tests inject fixed valid literals.
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Agent.RuntimeRestoreAdmissionClaimCore, as: Core

  @token "rrt_" <> String.duplicate("t", 22)
  @target "agent_claim_core_test01"
  @op "op_claim_core_1"
  @intent "rai_" <> String.duplicate("i", 22)

  test "mint accepts injected shell token; rejects invalid token" do
    assert {:ok, claim} =
             Core.mint(
               %{
                 "operation_id" => @op,
                 "target_agent_id" => @target,
                 "at_unix_ms" => 1_000
               },
               @token
             )

    assert claim["claim_phase"] == "minted"
    assert claim["token"] == @token
    assert claim["intent_id"] == nil
    assert claim["fingerprint"] == nil

    assert {:error, _} =
             Core.mint(
               %{
                 "operation_id" => @op,
                 "target_agent_id" => @target,
                 "at_unix_ms" => 1_000
               },
               "rrt_short"
             )
  end

  test "fixed-format identities reject oversized input at the public core boundary" do
    oversized_token = @token <> String.duplicate("t", 16_384)

    assert {:error, :invalid_claim} =
             Core.mint(
               %{
                 "operation_id" => @op,
                 "target_agent_id" => @target,
                 "at_unix_ms" => 1_000
               },
               oversized_token
             )

    assert {:ok, minted} =
             Core.mint(
               %{
                 "operation_id" => @op,
                 "target_agent_id" => @target,
                 "at_unix_ms" => 1_000
               },
               @token
             )

    assert {:error, :invalid_claim} =
             Core.bind_intent(
               minted,
               @intent <> String.duplicate("i", 16_384),
               "fp_" <> String.duplicate("0", 64),
               2_000
             )

    assert {:error, :invalid_claim} =
             Core.bind_intent(
               minted,
               @intent,
               "fp_" <> String.duplicate("0", 16_384),
               2_000
             )
  end

  test "fingerprint is deterministic for exact identity" do
    fp1 = Core.fingerprint(@op, @target, @op, @token, @intent)
    fp2 = Core.fingerprint(@op, @target, @op, @token, @intent)
    assert fp1 == fp2
    assert String.match?(fp1, ~r/\Afp_[0-9a-f]{64}\z/)

    fp_other = Core.fingerprint(@op, @target, @op, @token, "rai_" <> String.duplicate("j", 22))
    refute fp1 == fp_other
  end

  test "bind_intent requires store-owned fingerprint match" do
    assert {:ok, minted} =
             Core.mint(
               %{
                 "operation_id" => @op,
                 "target_agent_id" => @target,
                 "at_unix_ms" => 1_000
               },
               @token
             )

    fp = Core.fingerprint(@op, @target, @op, @token, @intent)
    assert {:ok, bound} = Core.bind_intent(minted, @intent, fp, 2_000)
    assert bound["claim_phase"] == "bound"
    assert bound["intent_id"] == @intent
    assert bound["fingerprint"] == fp

    # Exact already-bound is idempotent.
    assert {:ok, ^bound} = Core.bind_intent(bound, @intent, fp, 3_000)

    bad_fp = "fp_" <> String.duplicate("0", 64)
    assert {:error, :stale_claim} = Core.bind_intent(minted, @intent, bad_fp, 2_000)
  end

  test "bind_intent rejects outcome_unknown (not bind success / release permission)" do
    assert {:ok, minted} =
             Core.mint(
               %{
                 "operation_id" => @op,
                 "target_agent_id" => @target,
                 "at_unix_ms" => 1_000
               },
               @token
             )

    fp = Core.fingerprint(@op, @target, @op, @token, @intent)
    assert {:ok, bound} = Core.bind_intent(minted, @intent, fp, 2_000)
    assert {:ok, unknown} = Core.mark_outcome_unknown(bound, 3_000)
    assert unknown["claim_phase"] == "outcome_unknown"

    # Exact identity still must not report bind success for outcome_unknown.
    assert {:error, :restore_phase_illegal} = Core.bind_intent(unknown, @intent, fp, 4_000)
    assert unknown["claim_phase"] == "outcome_unknown"
    assert is_nil(unknown["settlement"])
  end

  test "settle idempotency: same outcome+reason keeps first timestamp; different is already_settled" do
    assert {:ok, minted} =
             Core.mint(
               %{
                 "operation_id" => @op,
                 "target_agent_id" => @target,
                 "at_unix_ms" => 1_000
               },
               @token
             )

    fp = Core.fingerprint(@op, @target, @op, @token, @intent)
    assert {:ok, bound} = Core.bind_intent(minted, @intent, fp, 2_000)

    first = %{
      "outcome" => "applied",
      "reason_code" => "branch_restored",
      "at_unix_ms" => 3_000
    }

    assert {:ok, settled} = Core.settle(bound, first)
    assert settled["settlement"]["at_unix_ms"] == 3_000
    assert settled["claim_phase"] == "settled"

    # Same terminal, different timestamp — logical successor preserves first at.
    retry_later = %{
      "outcome" => "applied",
      "reason_code" => "branch_restored",
      "at_unix_ms" => 9_999
    }

    assert {:ok, again} = Core.settle(settled, retry_later)
    assert again["settlement"]["at_unix_ms"] == 3_000
    assert again["settlement"]["outcome"] == "applied"
    assert again["settlement"]["reason_code"] == "branch_restored"
    assert Core.settlement_same_terminal?(again["settlement"], retry_later)
    # Must not be restore_phase_illegal (the pre-fix unreachable-branch bug).
    refute match?({:error, :restore_phase_illegal}, Core.settle(settled, retry_later))

    # Different reason_code — already_settled, first record unchanged.
    other_reason = %{
      "outcome" => "applied",
      "reason_code" => "other_reason",
      "at_unix_ms" => 4_000
    }

    assert {:error, :already_settled} = Core.settle(settled, other_reason)
    assert {:ok, still} = Core.settle(settled, first)
    assert still["settlement"]["at_unix_ms"] == 3_000

    # Different outcome — already_settled.
    other_outcome = %{
      "outcome" => "failed",
      "reason_code" => "worker_failed",
      "at_unix_ms" => 4_000
    }

    assert {:error, :already_settled} = Core.settle(settled, other_outcome)
  end

  test "settle already-settled: malformed retry rejected before idempotency compare" do
    assert {:ok, minted} =
             Core.mint(
               %{
                 "operation_id" => @op,
                 "target_agent_id" => @target,
                 "at_unix_ms" => 1_000
               },
               @token
             )

    first = %{
      "outcome" => "not_applied",
      "reason_code" => "pre_effect_abort",
      "at_unix_ms" => 2_000
    }

    assert {:ok, settled} = Core.settle(minted, first)
    assert settled["claim_phase"] == "settled"

    # Extra key rejected (exact settlement keyset).
    assert {:error, :invalid_claim} =
             Core.settle(settled, Map.put(first, "extra", true))

    # Missing key rejected.
    assert {:error, :invalid_claim} =
             Core.settle(settled, Map.delete(first, "reason_code"))

    # Invalid outcome rejected.
    assert {:error, :invalid_claim} =
             Core.settle(settled, %{
               "outcome" => "not_a_real_outcome",
               "reason_code" => "pre_effect_abort",
               "at_unix_ms" => 3_000
             })

    # Invalid reason grammar rejected.
    assert {:error, :invalid_claim} =
             Core.settle(settled, %{
               "outcome" => "not_applied",
               "reason_code" => "BAD-REASON",
               "at_unix_ms" => 3_000
             })

    # Negative/non-integer at rejected.
    assert {:error, :invalid_claim} =
             Core.settle(settled, %{
               "outcome" => "not_applied",
               "reason_code" => "pre_effect_abort",
               "at_unix_ms" => -1
             })

    # First record still intact after malformed retries.
    assert {:ok, again} =
             Core.settle(settled, %{
               "outcome" => "not_applied",
               "reason_code" => "pre_effect_abort",
               "at_unix_ms" => 99_999
             })

    assert again["settlement"]["at_unix_ms"] == 2_000
  end

  test "settle rejects atom/string duplicate-alias keys on request settlement" do
    assert {:ok, minted} =
             Core.mint(
               %{
                 "operation_id" => @op,
                 "target_agent_id" => @target,
                 "at_unix_ms" => 1_000
               },
               @token
             )

    # Atom+string alias for the same settlement field must fail closed.
    dup_alias = %{
      "outcome" => "not_applied",
      :outcome => "failed",
      "reason_code" => "pre_effect_abort",
      "at_unix_ms" => 2_000
    }

    assert {:error, :invalid_claim} = Core.settle(minted, dup_alias)

    # Same on already-settled retry path (admit request before phase branch).
    assert {:ok, settled} =
             Core.settle(minted, %{
               "outcome" => "not_applied",
               "reason_code" => "pre_effect_abort",
               "at_unix_ms" => 2_000
             })

    assert {:error, :invalid_claim} =
             Core.settle(settled, %{
               "outcome" => "not_applied",
               :reason_code => "pre_effect_abort",
               "reason_code" => "pre_effect_abort",
               "at_unix_ms" => 3_000
             })

    # Pure atom-key settlement is admitted when exact after normalize (no dups).
    assert {:ok, again} =
             Core.settle(settled, %{
               outcome: "not_applied",
               reason_code: "pre_effect_abort",
               at_unix_ms: 9_999
             })

    assert again["settlement"]["at_unix_ms"] == 2_000
  end

  test "settle already-settled: invalid UTF-8 identity returns invalid_claim without raise" do
    assert {:ok, minted} =
             Core.mint(
               %{
                 "operation_id" => @op,
                 "target_agent_id" => @target,
                 "at_unix_ms" => 1_000
               },
               @token
             )

    assert {:ok, settled} =
             Core.settle(minted, %{
               "outcome" => "not_applied",
               "reason_code" => "pre_effect_abort",
               "at_unix_ms" => 2_000
             })

    # Corrupt token with invalid UTF-8 — admit must not raise on Regex.
    bad = Map.put(settled, "token", <<0xFF, 0xFE>> <> "rrt_" <> String.duplicate("x", 18))

    assert {:error, :invalid_claim} =
             Core.settle(bad, %{
               "outcome" => "not_applied",
               "reason_code" => "pre_effect_abort",
               "at_unix_ms" => 3_000
             })

    # Malformed request settlement with invalid UTF-8 reason.
    assert {:error, :invalid_claim} =
             Core.settle(settled, %{
               "outcome" => "not_applied",
               "reason_code" => <<0xFF, 0xFE, "bad">>,
               "at_unix_ms" => 3_000
             })
  end

  test "settle transition legality applies only to non-settled phases" do
    assert {:ok, minted} =
             Core.mint(
               %{
                 "operation_id" => @op,
                 "target_agent_id" => @target,
                 "at_unix_ms" => 1_000
               },
               @token
             )

    # not_applied illegal from bound (transition legality).
    fp = Core.fingerprint(@op, @target, @op, @token, @intent)
    assert {:ok, bound} = Core.bind_intent(minted, @intent, fp, 2_000)

    assert {:error, :restore_phase_illegal} =
             Core.settle(bound, %{
               "outcome" => "not_applied",
               "reason_code" => "pre_effect_abort",
               "at_unix_ms" => 3_000
             })

    # applied from bound succeeds, then same-terminal retry on settled is OK
    # (must not re-apply settlement_allowed? which rejects phase settled).
    assert {:ok, settled} =
             Core.settle(bound, %{
               "outcome" => "applied",
               "reason_code" => "branch_restored",
               "at_unix_ms" => 3_000
             })

    assert {:ok, again} =
             Core.settle(settled, %{
               "outcome" => "applied",
               "reason_code" => "branch_restored",
               "at_unix_ms" => 8_000
             })

    assert again["settlement"]["at_unix_ms"] == 3_000
  end
end
