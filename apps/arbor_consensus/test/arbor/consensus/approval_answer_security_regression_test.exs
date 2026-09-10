Code.require_file(
  Path.expand("../../../../arbor_security/test/support/approval_answer_fixture.ex", __DIR__)
)

defmodule Arbor.Consensus.ApprovalAnswerSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Consensus
  alias Arbor.Consensus.TestHelpers
  alias Arbor.Security
  alias Arbor.Security.TestSupport.ApprovalAnswerFixture, as: Fixture

  setup do
    ctx = Fixture.setup!()

    {_, server} =
      TestHelpers.start_test_coordinator(
        evaluator_backend: TestHelpers.SlowBackend,
        config: [evaluation_timeout_ms: 60_000]
      )

    Arbor.Consensus.TopicRegistry.register_topic(%{
      topic: :authorization_request,
      min_quorum: :majority,
      match_patterns: ["authorization_request"]
    })

    cap = Fixture.grant!(ctx.human_id, "arbor://approval/answer/#{ctx.agent_id}")

    {:ok, id} =
      Consensus.submit(
        %{
          proposer: ctx.agent_id,
          topic: :authorization_request,
          description: "Approve exact write #{System.unique_integer([:positive])}",
          metadata: %{principal_id: ctx.agent_id, resource_uri: "arbor://code/write/exact.ex"}
        },
        server: server
      )

    Map.merge(ctx, %{server: server, id: id, cap: cap})
  end

  test "security regression: supplied forged proof cannot use a matching approval capability",
       ctx do
    assert {:error, {:unauthorized, :approval_answer_required}} =
             Consensus.answer_authorization_request(ctx.id, :approve, ctx.human_id,
               server: ctx.server,
               session_token: "forged"
             )

    assert {:ok, proposal} = Consensus.get_proposal(ctx.id, ctx.server)
    assert proposal.status == :evaluating
    assert {:error, :not_decided} = Consensus.get_decision(ctx.id, ctx.server)
    assert :ok = answer(ctx, :approve)
    assert {:ok, decision} = Consensus.get_decision(ctx.id, ctx.server)
    assert decision.verified_human_id == ctx.human_id
    refute inspect(decision) =~ ctx.token
  end

  test "only winning answer carries live proof, never a later responder", ctx do
    assert :ok = answer(ctx, :deny)
    assert {:error, :already_decided} = answer(ctx, :approve)
    assert {:ok, decision} = Consensus.get_decision(ctx.id, ctx.server)
    assert decision.requested_decision == :deny
    assert decision.verified_human_id == ctx.human_id
  end

  test "revocation prevents authenticated terminal transition", ctx do
    assert :ok = Security.revoke(ctx.cap.id)
    assert {:error, {:unauthorized, :approval_answer_required}} = answer(ctx, :approve)
    assert {:ok, proposal} = Consensus.get_proposal(ctx.id, ctx.server)
    assert proposal.status == :evaluating
    assert {:error, :not_decided} = Consensus.get_decision(ctx.id, ctx.server)
  end

  defp answer(ctx, decision),
    do:
      Consensus.answer_authorization_request(ctx.id, decision, ctx.human_id,
        server: ctx.server,
        session_token: ctx.token,
        verified_human_id: "human_forged"
      )
end
