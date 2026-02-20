defmodule Arbor.Consensus.Authorizer do
  @moduledoc """
  Behaviour for optional authorization checks on proposals.

  The default (when no authorizer is configured) allows all proposals.
  Host apps can inject `arbor_security` or custom authorization logic.

  ## Example Implementation

      defmodule MyApp.SecurityAuthorizer do
        @behaviour Arbor.Consensus.Authorizer

        @impl true
        def authorize_proposal(proposal) do
          case Arbor.Security.authorize(proposal.proposer, "arbor://consensus/propose", :write) do
            {:ok, :authorized} -> :ok
            {:error, _reason} -> {:error, :unauthorized}
          end
        end

        @impl true
        def authorize_execution(proposal, decision) do
          if decision.quorum_met do
            :ok
          else
            {:error, :quorum_not_met}
          end
        end
      end
  """

  alias Arbor.Contracts.Consensus.{CouncilDecision, Proposal}

  @doc """
  Check if a proposal is authorized to be submitted.
  """
  @callback authorize_proposal(proposal :: Proposal.t()) ::
              :ok | {:error, term()}

  @doc """
  Check if an approved proposal is authorized for execution.
  """
  @callback authorize_execution(
              proposal :: Proposal.t(),
              decision :: CouncilDecision.t()
            ) :: :ok | {:error, term()}
end
