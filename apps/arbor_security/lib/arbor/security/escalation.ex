defmodule Arbor.Security.Escalation do
  @moduledoc """
  Handles consensus escalation for capabilities with `requires_approval: true`.

  When a capability requires approval, this module submits a proposal to the
  configured consensus module and returns the proposal ID for async tracking.

  ## Configuration

  The consensus module is injected via config to avoid a hard dependency
  from `arbor_security` to `arbor_consensus`:

      config :arbor_security,
        consensus_module: Arbor.Consensus,      # default
        consensus_escalation_enabled: true       # default

  ## Proposal Format

  Submitted proposals include:

      %{
        proposer: principal_id,
        topic: :authorization_request,
        description: "Authorization request for resource",
        metadata: %{
          principal_id: "agent_...",
          resource_uri: "arbor://...",
          capability_id: "cap_...",
          constraints: %{...}
        }
      }
  """

  alias Arbor.Security.Config

  require Logger

  @doc """
  Check if the capability requires approval and submit for consensus if so.

  Returns:
  - `:ok` — no approval required, proceed with authorization
  - `{:ok, :pending_approval, proposal_id}` — submitted for consensus
  - `{:error, reason}` — consensus submission failed
  """
  @spec maybe_escalate(map(), String.t(), String.t()) ::
          :ok | {:ok, :pending_approval, String.t()} | {:error, term()}
  def maybe_escalate(capability, principal_id, resource_uri) do
    requires_approval? = capability.constraints[:requires_approval] == true
    escalation_enabled? = Config.consensus_escalation_enabled?()
    consensus_module = Config.consensus_module()

    cond do
      not requires_approval? ->
        :ok

      # M2: Log when escalation is bypassed due to disabled config or missing module
      not escalation_enabled? ->
        Logger.warning("Escalation required but disabled: consensus_escalation_enabled is false",
          principal_id: principal_id,
          resource_uri: resource_uri
        )

        {:error, :escalation_disabled}

      is_nil(consensus_module) ->
        Logger.warning("Escalation required but no consensus_module configured",
          principal_id: principal_id,
          resource_uri: resource_uri
        )

        {:error, :no_consensus_module}

      not consensus_available?(consensus_module) ->
        # Consensus module configured but not available — fail closed
        {:error, :consensus_unavailable}

      true ->
        submit_for_approval(consensus_module, capability, principal_id, resource_uri)
    end
  end

  @doc """
  Submit an authorization request to the consensus system.
  """
  @spec submit_for_approval(module(), map(), String.t(), String.t()) ::
          {:ok, :pending_approval, String.t()} | {:error, term()}
  def submit_for_approval(consensus_module, capability, principal_id, resource_uri) do
    proposal = %{
      proposer: principal_id,
      topic: :authorization_request,
      description: "Authorization request for #{resource_uri}",
      metadata: %{
        principal_id: principal_id,
        resource_uri: resource_uri,
        capability_id: capability.id,
        constraints: capability.constraints
      }
    }

    case consensus_module.submit(proposal) do
      {:ok, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, reason} ->
        {:error, {:consensus_submission_failed, reason}}
    end
  end

  # Check if the consensus module is available (process running)
  defp consensus_available?(consensus_module) do
    # Try to check if the consensus system is healthy
    # Fall back to checking if the module is loaded
    if function_exported?(consensus_module, :healthy?, 0) do
      try do
        consensus_module.healthy?()
      rescue
        _ -> false
      catch
        :exit, _ -> false
      end
    else
      Code.ensure_loaded?(consensus_module)
    end
  end
end
