defmodule Arbor.Orchestrator.SessionDisclosureIssueRightSecurityRegressionTest do
  @moduledoc """
  Security regression for the fresh-install chat refusal (2026-11-13).

  An authenticated human turn on an external route needs a one-turn
  disclosure capability, which the Session mints with the agent's own
  authority. A newly created agent held no right to do that, so
  `TurnEgress.issue_disclosure_if_needed/4` returned
  `:capability_mutation_unauthorized` and every chat turn was refused as
  `:turn_preparation_refused` before the LLM call. The P5 suite never saw it:
  its fixture grants the agent the general `arbor://security/grant/<agent>`.

  Here the agent holds only what `Lifecycle.create/2` now grants its creator's
  agents, `arbor://security/disclose/<agent>/<human>`.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Session.TurnAuthority
  alias Arbor.Identifiers
  alias Arbor.Orchestrator.Session.TurnEgress
  alias Arbor.Security

  @route %{
    destination: "opencode.ai",
    provider: "opencode_zen",
    runtime: "arbor",
    model: "test-model-free"
  }

  setup do
    :ok = Security.TestBootstrap.start!()

    {:ok, identity} = Identity.generate(name: "session disclosure-right agent")
    :ok = Security.register_identity_fixture(Identity.public_only(identity))

    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(
        identity.agent_id,
        identity.private_key,
        purpose: :session
      )

    {:ok, authority} = Security.open_ephemeral_signing_authority(proof, identity.private_key)
    human_id = "human_" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

    on_exit(fn ->
      _ = Security.close_signing_authority(authority)
      _ = Security.deregister_identity_fixture(identity.agent_id)
    end)

    state = %{
      agent_id: identity.agent_id,
      session_id: "session_disclosure_right_" <> Base.encode16(:crypto.strong_rand_bytes(6)),
      signing_authority: authority
    }

    {:ok, turn} =
      TurnAuthority.new(
        turn_id: Identifiers.generate_id("turn_"),
        authenticated_principal_id: human_id,
        disclosure_capability_id: nil
      )

    %{state: state, turn: turn, human_id: human_id, authority: authority}
  end

  test "security regression: a fresh agent without the right refuses the external turn",
       %{state: state, turn: turn} do
    assert {:error, :capability_mutation_unauthorized} =
             TurnEgress.issue_disclosure_if_needed(state, turn, @route, :external_provider)
  end

  test "security regression: the creator's disclose right lets the Session mint and revoke",
       %{state: state, turn: turn, human_id: human_id, authority: authority} do
    {:ok, resource} = Security.disclosure_issue_right_uri(state.agent_id, human_id)
    {:ok, right} = Security.grant_fixture(principal: state.agent_id, resource: resource)
    on_exit(fn -> _ = Security.revoke_fixture(right.id) end)

    assert {:ok, bound, cap_id} =
             TurnEgress.issue_disclosure_if_needed(state, turn, @route, :external_provider)

    assert is_binary(cap_id)
    assert bound.disclosure_capability_id == cap_id
    assert bound.authenticated_principal_id == human_id

    assert :ok = TurnEgress.safe_revoke_disclosure(cap_id, authority)
  end

  test "security regression: another human's turn is still refused",
       %{state: state, turn: turn} do
    other = "human_" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
    {:ok, resource} = Security.disclosure_issue_right_uri(state.agent_id, other)
    {:ok, right} = Security.grant_fixture(principal: state.agent_id, resource: resource)
    on_exit(fn -> _ = Security.revoke_fixture(right.id) end)

    assert {:error, :capability_mutation_unauthorized} =
             TurnEgress.issue_disclosure_if_needed(state, turn, @route, :external_provider)
  end
end
