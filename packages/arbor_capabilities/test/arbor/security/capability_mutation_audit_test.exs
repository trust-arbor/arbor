defmodule Arbor.Security.CapabilityMutationAuditTest do
  @moduledoc """
  Pure rules of the capability mutation facade's refusal reporting
  (Floor-and-Ledger v3, slice 3). New API: absent on the parent 52a2cc3fa.
  The behavioral regressions through `Security.grant/revoke` are in
  `capability_mutation_audit_refusal_security_regression_test.exs`.
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Security.CapabilityMutationAudit

  test "journal refusal reasons map onto the closed class set" do
    assert CapabilityMutationAudit.reason_class(:soft_capacity_exhausted) == :capacity
    assert CapabilityMutationAudit.reason_class(:capacity_exhausted) == :capacity
    assert CapabilityMutationAudit.reason_class(:operation_terminal) == :identity
    assert CapabilityMutationAudit.reason_class(:retired_version) == :identity

    for other <- [
          :journal_unavailable,
          :journal_poisoned,
          :journal_disabled,
          {:commit_uncertain, :timeout},
          {:not_committed, :torn_tail},
          :malformed,
          :invalid_audit_intent,
          nil
        ] do
      assert CapabilityMutationAudit.reason_class(other) == :unavailable
    end
  end

  test "degraded-reduction warnings: the first 10, then every 100th" do
    warned = Enum.filter(1..1_000, &CapabilityMutationAudit.warn_degraded_reduction?/1)
    assert warned == Enum.to_list(1..10) ++ Enum.to_list(100..1_000//100)
    refute CapabilityMutationAudit.warn_degraded_reduction?(0)
    refute CapabilityMutationAudit.warn_degraded_reduction?(:many)
  end

  test "refused-grant warnings share the degraded-reduction rate limit" do
    warned = Enum.filter(1..1_000, &CapabilityMutationAudit.warn_refused_grant?/1)
    assert warned == Enum.to_list(1..10) ++ Enum.to_list(100..1_000//100)
    refute CapabilityMutationAudit.warn_refused_grant?(0)
    refute CapabilityMutationAudit.warn_refused_grant?(:many)
  end

  test "refusal reasons log as bounded labels, never as raw terms" do
    assert CapabilityMutationAudit.reason_label(:soft_capacity_exhausted) ==
             "soft_capacity_exhausted"

    assert CapabilityMutationAudit.reason_label({:commit_uncertain, :timeout}) ==
             "commit_uncertain:timeout"

    assert CapabilityMutationAudit.reason_label({:not_committed, %{path: "/secret"}}) ==
             "not_committed:other"

    assert CapabilityMutationAudit.reason_label(nil) == "other"
    assert CapabilityMutationAudit.reason_label("free text") == "other"
  end

  test "last_status/0 carries the reason and the degraded count with safe defaults" do
    status = CapabilityMutationAudit.last_status()
    assert status.reason == :none
    assert status.degraded_reductions == 0
    assert status.refused_grants == 0
  end
end
