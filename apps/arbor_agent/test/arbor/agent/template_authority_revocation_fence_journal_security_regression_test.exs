defmodule Arbor.Agent.TemplateAuthorityRevocationFenceJournalSecurityRegressionTest do
  @moduledoc """
  Phase 4C C3B4b — durable revocation-fence binding in the template-authority
  reconciliation operation journal.

  CANONICAL SUITE: every `revoke_managed_capability` journal entry must carry an
  exact closed `revocation_fence` admitted by `Arbor.Security`. ID-only revoke
  payloads (schema v3) fail closed. Do not split this invariant without moving
  it here.

  The file is RUNNABLE on the immediate parent
  (`cd19d495e333ff3ac0e0118fe6029518e391148a`): the marquee regression is
  unconditional and uses only APIs that exist on both parent and candidate
  (`TemplateAuthorityPolicy.build/2`, `OperationCore.new/1`, `acknowledge/2`,
  `prepare/2`, `plan_capability_effects/2`). On the parent, plan with only
  capability_id + resource still succeeds (v3), so the assertion that plan is
  refused without `revocation_fence` fails as an ordinary ExUnit assertion —
  never via UndefinedFunctionError / compile / setup failure.

  Candidate-only cases (malformed fence matrix, reobserve payload binding,
  store restart, public redaction) live in the focused operation-core /
  status-projection / store suites.
  """

  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Agent.ProfileAuthorityMutationCore
  alias Arbor.Agent.TemplateAuthorityCapabilityProjection
  alias Arbor.Agent.TemplateAuthorityPolicy
  alias Arbor.Agent.TemplateAuthorityReconciliationOperationCore, as: Core

  @digest String.duplicate("ab", 32)
  @agent "agent_revfence_reg_1"
  @caller "agent_revfence_reg_caller"
  @op_id "op_revfence_reg_1"
  @repo_root "/Users/dev/arbor"

  # Canonical capability id: cap_ + 32 lowercase hex (valid on parent and candidate).
  @cap_id "cap_" <> String.duplicate("c3", 16)

  @template_data %{
    "name" => "coding_agent",
    "required_capabilities" => [
      %{"resource" => "arbor://fs/read", "constraints" => %{"rate_limit" => 10}},
      %{"resource" => "arbor://fs/write"}
    ],
    "trust_preset" => %{
      "baseline" => "block",
      "rules" => %{
        "arbor://fs/read" => "auto",
        "arbor://fs/write" => "ask"
      }
    },
    "template_source" => %{"name" => "coding_agent", "layer" => "shipped"}
  }

  defp t(n), do: 1_000 + n

  defp profile_cas do
    %{"record_id" => "profile_rec_1", "generation" => 1, "revision" => 1}
  end

  defp replay_commitment do
    %{
      "version" => ProfileAuthorityMutationCore.commitment_version(),
      "kind" => ProfileAuthorityMutationCore.commitment_kind(),
      "algorithm" => ProfileAuthorityMutationCore.commitment_algorithm(),
      "encoding" => ProfileAuthorityMutationCore.commitment_encoding(),
      "domain" => ProfileAuthorityMutationCore.commitment_domain(),
      "anchor_digest" => String.duplicate("aa", 32),
      "successor_digest" => String.duplicate("bb", 32)
    }
  end

  defp frozen_authority(record) do
    envelope = record["desired_authority"]["envelope"]
    snap = TemplateAuthorityPolicy.snapshot(envelope)
    declared = TemplateAuthorityPolicy.capabilities(snap)

    assert {:ok, caps} =
             TemplateAuthorityCapabilityProjection.project_normalized(
               declared,
               record["target_agent_id"],
               repo_root: @repo_root
             )

    %{"repo_root" => @repo_root, "effective_capabilities" => caps}
  end

  defp walk_to_runtime_quiesced! do
    assert {:ok, envelope} = TemplateAuthorityPolicy.build("coding_agent", @template_data)

    facts = %{
      "operation_id" => @op_id,
      "target_agent_id" => @agent,
      "authorizing_caller_id" => @caller,
      "expected_preview_reconciliation_digest" => @digest,
      "desired_authority" => %{"envelope" => envelope},
      "scope" => "local_owner",
      "durability" => "node_restart",
      "created_at_unix_ms" => 1_000
    }

    assert {:ok, record, _} = Core.new(facts)

    assert {:ok, record, _} =
             Core.acknowledge(record, %{"phase_intent" => "reserved", "at_unix_ms" => t(1)})

    assert {:ok, record, _} =
             Core.prepare(record, %{
               "at_unix_ms" => t(2),
               "profile_cas" => profile_cas(),
               "frozen_authority" => frozen_authority(record),
               "profile_mutation_replay" => replay_commitment()
             })

    assert {:ok, record, _} =
             Core.acknowledge(record, %{"phase_intent" => "prepared", "at_unix_ms" => t(3)})

    assert {:ok, record, _} =
             Core.acknowledge(record, %{"phase_intent" => "deny_all_intent", "at_unix_ms" => t(4)})

    assert {:ok, record, _} =
             Core.acknowledge(record, %{
               "phase_intent" => "deny_all_installed",
               "at_unix_ms" => t(5),
               "runtime_was_running" => true
             })

    record
  end

  # ============================================================================
  # MARQUEE PARENT-FAILING REGRESSION — ID-only revoke rejected
  # ============================================================================

  describe "revocation fence journal binding (marquee parent-failing regression)" do
    test "security regression: plan_capability_effects refuses ID-only revoke without revocation_fence" do
      record = walk_to_runtime_quiesced!()

      # Candidate (v4): missing revocation_fence fails closed.
      # Parent (v3): plan with only capability_id + resource still succeeds —
      # this assertion is the single intentional ordinary failure on cd19d495e.
      assert match?(
               {:error, _},
               Core.plan_capability_effects(record, %{
                 "at_unix_ms" => t(10),
                 "entries" => [
                   %{
                     "effect_id" => "eff_revoke_nofence",
                     "effect_type" => "revoke_managed_capability",
                     "payload" => %{
                       "capability_id" => @cap_id,
                       "resource" => "arbor://fs/write"
                     }
                   }
                 ]
               })
             ),
             "security regression: ID-only revoke journal entry must fail closed without revocation_fence"
    end
  end
end
