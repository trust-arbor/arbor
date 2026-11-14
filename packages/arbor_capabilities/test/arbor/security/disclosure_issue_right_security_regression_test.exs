defmodule Arbor.Security.DisclosureIssueRightSecurityRegressionTest do
  @moduledoc """
  Security regression: an agent's Session mints the one-turn disclosure
  capability with the agent's own authority. Production never granted that
  authority, so on a fresh install every authenticated chat turn to an
  external provider failed with `:capability_mutation_unauthorized`, surfaced
  only as `:turn_preparation_refused` (found 2026-11-13).

  The fix is the narrow `arbor://security/disclose/<agent>/<human>` right. These
  tests pin both halves: it admits exactly the agent's own disclosure
  capability for that human (issue and revoke), and it never widens into the
  general `arbor://security/grant/<agent>`.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security

  setup do
    :ok = Security.TestBootstrap.start!()

    {:ok, identity} = Identity.generate(name: "disclosure-issue-right agent")
    :ok = Security.register_identity_fixture(Identity.public_only(identity))

    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(
        identity.agent_id,
        identity.private_key,
        purpose: :session
      )

    {:ok, authority} = Security.open_ephemeral_signing_authority(proof, identity.private_key)

    human = "human_" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
    other_human = "human_" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

    on_exit(fn ->
      _ = Security.close_signing_authority(authority)
      _ = Security.deregister_identity_fixture(identity.agent_id)
    end)

    %{agent_id: identity.agent_id, authority: authority, human: human, other_human: other_human}
  end

  test "security regression: without the right an agent cannot mint its own disclosure",
       ctx do
    assert {:error, :capability_mutation_unauthorized} =
             Security.issue_disclosure_capability(disclosure_opts(ctx, ctx.human))
  end

  test "security regression: the narrow right mints and revokes the agent's own disclosure",
       ctx do
    grant_right!(ctx.agent_id, ctx.human)

    assert {:ok, cap} = Security.issue_disclosure_capability(disclosure_opts(ctx, ctx.human))
    assert cap.principal_id == ctx.agent_id
    assert cap.principal_scope == ctx.human
    assert cap.delegation_depth == 0

    assert :ok = Security.revoke(cap.id, actor_authority: ctx.authority)
  end

  test "security regression: the narrow right is bound to the human it names", ctx do
    grant_right!(ctx.agent_id, ctx.human)

    assert {:error, :capability_mutation_unauthorized} =
             Security.issue_disclosure_capability(disclosure_opts(ctx, ctx.other_human))
  end

  test "security regression: the narrow right does not let an agent grant itself anything else",
       ctx do
    grant_right!(ctx.agent_id, ctx.human)

    assert {:error, :capability_mutation_unauthorized} =
             Security.grant(
               principal: ctx.agent_id,
               resource: "arbor://shell/exec/**",
               actor_authority: ctx.authority
             )

    # Not even a hand-built grant on the disclosure namespace without the
    # disclosure shape (no session/task/human binding, no expiry).
    assert {:error, :capability_mutation_unauthorized} =
             Security.grant(
               principal: ctx.agent_id,
               resource: "arbor://egress/disclose/" <> String.duplicate("a", 32),
               actor_authority: ctx.authority
             )
  end

  test "security regression: the narrow right does not revoke the agent's other capabilities",
       ctx do
    grant_right!(ctx.agent_id, ctx.human)

    {:ok, other} =
      Security.grant_fixture(
        principal: ctx.agent_id,
        resource: "arbor://fs/read/disclosure-issue-right-regression"
      )

    on_exit(fn -> _ = Security.revoke_fixture(other.id) end)

    assert {:error, _} = Security.revoke(other.id, actor_authority: ctx.authority)
  end

  test "the right URI only accepts canonical agent and human ids" do
    agent = "agent_" <> String.duplicate("a", 64)
    human = "human_" <> String.duplicate("b", 40)

    assert {:ok, "arbor://security/disclose/" <> rest} =
             Security.disclosure_issue_right_uri(agent, human)

    assert rest == agent <> "/" <> human

    for {a, h} <- [
          {agent, human <> "/agent_x"},
          {agent, "agent_" <> String.duplicate("c", 64)},
          {agent, "human_"},
          {"human_x", human},
          {agent, nil}
        ] do
      assert {:error, :invalid_binding_field} = Security.disclosure_issue_right_uri(a, h)
    end
  end

  defp grant_right!(agent_id, human) do
    {:ok, resource} = Security.disclosure_issue_right_uri(agent_id, human)
    {:ok, cap} = Security.grant_fixture(principal: agent_id, resource: resource)
    on_exit(fn -> _ = Security.revoke_fixture(cap.id) end)
    cap
  end

  defp disclosure_opts(ctx, human) do
    [
      principal_id: ctx.agent_id,
      session_id: "session-disclosure-issue-right",
      task_id: "turn-disclosure-issue-right",
      principal_scope: human,
      destination: "opencode.ai",
      provider: "opencode_zen",
      runtime: "arbor",
      model: "test-model-free",
      actor_authority: ctx.authority
    ]
  end
end
