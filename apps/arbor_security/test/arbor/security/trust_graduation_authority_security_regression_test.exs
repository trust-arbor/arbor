Code.require_file("../../support/approval_answer_fixture.ex", __DIR__)

defmodule Arbor.Security.TrustGraduationAuthoritySecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Security
  alias Arbor.Security.TestSupport.ApprovalAnswerFixture, as: Fixture

  setup do
    Fixture.setup!()
  end

  test "read authority cannot accept or decline and promotion scope is exact", ctx do
    Fixture.grant!(ctx.human_id, "arbor://trust/read/#{ctx.agent_id}")
    assert :ok = Security.authorize_trust_graduation(ctx.human_id, ctx.agent_id, ctx.token, :read)

    assert {:error, :graduation_authority_required} =
             Security.authorize_trust_graduation(ctx.human_id, ctx.agent_id, ctx.token, :accept)

    cap = Fixture.grant!(ctx.human_id, "arbor://trust/auto_promote/#{ctx.agent_id}")

    for operation <- [:accept, :decline] do
      assert :ok =
               Security.authorize_trust_graduation(
                 ctx.human_id,
                 ctx.agent_id,
                 ctx.token,
                 operation
               )

      assert {:error, :graduation_authority_required} =
               Security.authorize_trust_graduation(
                 ctx.human_id,
                 ctx.agent_id <> "_other",
                 ctx.token,
                 operation
               )
    end

    assert :ok = Security.revoke(cap.id)

    assert {:error, :graduation_authority_required} =
             Security.authorize_trust_graduation(ctx.human_id, ctx.agent_id, ctx.token, :accept)
  end

  test "security regression: current human proof and non-recursive explicit authority are mandatory",
       ctx do
    Fixture.grant!(ctx.human_id, "arbor://trust/auto_promote/#{ctx.agent_id}",
      constraints: %{requires_approval: true}
    )

    for token <- [ctx.token, "forged", nil] do
      assert {:error, :graduation_authority_required} =
               Security.authorize_trust_graduation(ctx.human_id, ctx.agent_id, token, :accept)
    end
  end

  test "target syntax and operation cannot choose a different authority resource", ctx do
    Fixture.grant!(ctx.human_id, "arbor://trust/auto_promote")

    for target <- ["agent_../other", "agent_*", "agent_", "human_other", nil] do
      assert {:error, :graduation_authority_required} =
               Security.authorize_trust_graduation(ctx.human_id, target, ctx.token, :accept)
    end

    assert {:error, :graduation_authority_required} =
             Security.authorize_trust_graduation(ctx.human_id, ctx.agent_id, ctx.token, :write)
  end
end
