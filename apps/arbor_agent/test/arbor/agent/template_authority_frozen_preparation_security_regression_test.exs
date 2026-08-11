defmodule Arbor.Agent.TemplateAuthorityFrozenPreparationSecurityRegressionTest do
  @moduledoc """
  Phase 4C C3B2 — frozen template-authority preparation security regressions.

  CANONICAL SUITE: fenced→prepared must freeze closed `frozen_authority`
  (canonical repo root + exact effective capabilities) alongside `profile_cas`.
  Do not split this invariant without moving it here.

  The file is RUNNABLE on the immediate parent
  (`7cf95ed4886e454f39863dce46213421e85f38da`): the marquee regression is
  unconditional and uses only APIs that exist on both parent and candidate
  (`TemplateAuthorityPolicy.build/2`, `OperationCore.new/1`,
  `acknowledge/2`, `prepare/2`). On the parent, prepare with only profile_cas
  still succeeds (v1), so the assertion that prepare is refused without
  frozen_authority fails as an ordinary ExUnit assertion — never via
  UndefinedFunctionError / compile / setup failure.

  Candidate-only cases live in the focused preview / operation-core suites.
  """

  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Agent.TemplateAuthorityPolicy
  alias Arbor.Agent.TemplateAuthorityReconciliationOperationCore, as: Core

  @digest String.duplicate("ab", 32)
  @agent "agent_frozen_prep_1"
  @caller "agent_frozen_prep_caller"
  @op_id "op_frozen_prep_1"

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

  defp new_fenced! do
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

    record
  end

  # ============================================================================
  # MARQUEE PARENT-FAILING REGRESSION — frozen_authority required
  # ============================================================================

  describe "frozen preparation (marquee parent-failing regression)" do
    test "fenced to prepared refuses transition without closed frozen_authority" do
      record = new_fenced!()

      # Candidate: prepare without frozen_authority must fail closed.
      # Parent (v1): prepare with only profile_cas still succeeds — this
      # assertion is the single intentional ordinary failure on 7cf95ed48.
      assert match?(
               {:error, _},
               Core.prepare(record, %{
                 "at_unix_ms" => t(2),
                 "profile_cas" => profile_cas()
               })
             ),
             "security regression: fenced→prepared must require closed frozen_authority"
    end
  end
end
