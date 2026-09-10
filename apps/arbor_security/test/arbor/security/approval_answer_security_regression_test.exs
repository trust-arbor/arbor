Code.require_file("../../support/approval_answer_fixture.ex", __DIR__)

defmodule Arbor.Security.ApprovalAnswerSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Security
  alias Arbor.Security.SessionToken
  alias Arbor.Security.TestSupport.ApprovalAnswerFixture, as: Fixture

  setup do
    Fixture.setup!()
  end

  test "human approval authority requires current proof, exact scope and active grant", ctx do
    uri = "arbor://approval/answer/#{ctx.agent_id}"
    cap = Fixture.grant!(ctx.human_id, uri)
    assert :ok = Security.authorize_approval_answer(ctx.human_id, uri, ctx.token)

    assert {:error, :approval_answer_required} =
             Security.authorize_approval_answer(ctx.human_id, uri <> "_other", ctx.token)

    assert :ok = Security.revoke(cap.id)

    assert {:error, :approval_answer_required} =
             Security.authorize_approval_answer(ctx.human_id, uri, ctx.token)
  end

  test "security regression: fabricated, mismatched, agent and expired proof cannot answer",
       ctx do
    uri = "arbor://approval/answer/#{ctx.agent_id}"
    Fixture.grant!(ctx.human_id, uri)
    other = Fixture.human!()
    {:ok, wrong} = SessionToken.generate(other)
    {:ok, agent_token} = SessionToken.generate(ctx.agent_id)
    {:ok, expired} = SessionToken.generate(ctx.human_id, ttl: -1)

    for token <- [nil, "", "forged", wrong, agent_token, expired, String.duplicate("x", 4097)] do
      assert {:error, :approval_answer_required} =
               Security.authorize_approval_answer(ctx.human_id, uri, token)
    end

    assert :ok = Security.authorize_approval_answer(ctx.human_id, uri, ctx.token)
    assert :ok = Security.suspend_identity(ctx.human_id, reason: "approval test")

    assert {:error, :approval_answer_required} =
             Security.authorize_approval_answer(ctx.human_id, uri, ctx.token)
  end

  test "approval capability requiring approval is refused without a recursive request", ctx do
    uri = "arbor://approval/answer/#{ctx.agent_id}"
    Fixture.grant!(ctx.human_id, uri, constraints: %{requires_approval: true})

    assert {:error, :approval_answer_required} =
             Security.authorize_approval_answer(ctx.human_id, uri, ctx.token)
  end

  test "closed authority API accepts exact task constraints but no caller bypass options", ctx do
    task = "task_#{System.unique_integer([:positive])}"
    uri = "arbor://approval/answer/task/#{task}"
    Fixture.grant!(ctx.human_id, uri, constraints: %{task_id: task})
    assert :ok = Security.authorize_approval_answer(ctx.human_id, uri, ctx.token, task_id: task)

    for opts <- [
          [task_id: "other"],
          [verify_identity: false],
          [approved_invocation: %{}],
          [session_token: ctx.token],
          [task_id: task, task_id: task]
        ] do
      assert {:error, :approval_answer_required} =
               Security.authorize_approval_answer(ctx.human_id, uri, ctx.token, opts)
    end

    assert {:error, :approval_answer_required} =
             Security.authorize_approval_answer(
               ctx.human_id,
               "arbor://approval/answering",
               ctx.token
             )

    assert {:error, :approval_answer_required} =
             Security.authorize_approval_answer(
               ctx.human_id,
               "arbor://trust/auto_promote/#{ctx.agent_id}",
               ctx.token
             )
  end
end
