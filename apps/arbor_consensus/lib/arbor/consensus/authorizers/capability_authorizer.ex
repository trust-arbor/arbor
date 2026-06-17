defmodule Arbor.Consensus.Authorizers.CapabilityAuthorizer do
  @moduledoc """
  Default `Arbor.Consensus.Authorizer` implementation backed by
  `Arbor.Security`.

  Checks `arbor://consensus/propose/{topic}` for `authorize_proposal/1` and
  `arbor://consensus/execute/{topic}` for `authorize_execution/2`. Topic
  defaults to `:general` if the proposal doesn't carry one.

  ## Usage

      # config/runtime.exs
      config :arbor_consensus,
        require_authorizer: true

      # In the Coordinator startup
      Arbor.Consensus.Coordinator.start_link(
        authorizer: Arbor.Consensus.Authorizers.CapabilityAuthorizer
      )

  ## Posture

  - Authorizes by the proposal's `proposer` field as the principal.
    Identity verification happens at the action layer; this authorizer
    only checks capability presence.
  - Returns `{:error, {:unauthorized, reason}}` when the caller has no
    cap, the Security subsystem is unavailable, or the result is
    `:pending_approval`. The Coordinator's `maybe_authorize` translates
    those into proposal rejection.

  OQ-5 from the audit remediation: this is the built-in implementation
  so production can flip `:require_authorizer` on without forcing every
  operator to roll their own module.
  """

  @behaviour Arbor.Consensus.Authorizer

  alias Arbor.Contracts.Consensus.{CouncilDecision, Proposal}

  require Logger

  @impl true
  def authorize_proposal(%Proposal{} = proposal) do
    topic = proposal.topic || :general
    resource = "arbor://consensus/propose/#{topic}"
    check(proposal.proposer, resource)
  end

  @impl true
  def authorize_execution(%Proposal{} = proposal, %CouncilDecision{} = _decision) do
    topic = proposal.topic || :general
    resource = "arbor://consensus/execute/#{topic}"
    check(proposal.proposer, resource)
  end

  defp check(principal_id, resource) when is_binary(principal_id) and is_binary(resource) do
    # arbor_security is a hard dep — direct call (was a Code.ensure_loaded?/apply
    # bridge whose missing-module branch already failed closed). rescue/catch
    # still deny on any raise/exit.
    case Arbor.Security.authorize(principal_id, resource, :write, verify_identity: false) do
      {:ok, :authorized} -> :ok
      {:error, reason} -> {:error, {:unauthorized, reason}}
      {:ok, :pending_approval, _} -> {:error, {:unauthorized, :pending_approval}}
      other -> {:error, {:unauthorized, {:unexpected_auth_result, other}}}
    end
  rescue
    e ->
      Logger.warning(
        "[CapabilityAuthorizer] authorize/4 raised — denying: #{Exception.message(e)}"
      )

      {:error, {:unauthorized, :security_unavailable}}
  catch
    :exit, _ ->
      {:error, {:unauthorized, :security_unavailable}}
  end

  defp check(_, _), do: {:error, {:unauthorized, :invalid_principal}}
end
