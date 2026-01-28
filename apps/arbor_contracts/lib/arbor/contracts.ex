defmodule Arbor.Contracts do
  @moduledoc """
  Contracts and type definitions for Arbor library boundaries.

  This module serves as the entry point for all Arbor contracts. Contracts define
  the stable interfaces between Arbor libraries and external consumers.

  ## Philosophy: Graduated Contracts

  Arbor uses "contracts as graduation, not specification":

  1. **Experimental phase** - Build rapidly, no contracts enforced
  2. **Graduation** - Human confirms "this works" → generate contract from implementation
  3. **Stable phase** - Contract enforced, drift detection enabled

  Only interfaces that have proven themselves through real usage become contracts.
  This prevents over-engineering and keeps the contract surface minimal.

  ## Foundation Modules

  - `Arbor.Types` - Shared type definitions and guards
  - `Arbor.Identifiers` - ID generation, URI parsing, and validation

  ## Contract Categories

  ### Core Types
  - `Arbor.Contracts.Security.Capability` - Permission tokens

  ### Consensus
  - `Arbor.Contracts.Consensus.Protocol` - Consensus protocol types and helpers
  - `Arbor.Contracts.Consensus.Proposal` - Change proposals
  - `Arbor.Contracts.Consensus.Evaluation` - Evaluator assessments
  - `Arbor.Contracts.Consensus.CouncilDecision` - Council decisions
  - `Arbor.Contracts.Consensus.ConsensusEvent` - Consensus audit trail

  ### Trust
  - `Arbor.Contracts.Trust.Profile` - Agent trust state
  - `Arbor.Contracts.Trust.Event` - Trust-affecting events

  ### Library Interfaces
  - `Arbor.Contracts.API.Shell` - Command execution interface
  - `Arbor.Contracts.API.Signals` - Event emission interface
  - `Arbor.Contracts.API.Security` - Security facade interface
  - `Arbor.Contracts.API.Trust` - Trust facade interface
  - `Arbor.Contracts.API.Consensus` - Consensus engine interface
  - `Arbor.Contracts.API.Historian` - Activity stream and audit log interface
  - `Arbor.Contracts.API.Persistence` - Pluggable storage interface

  ## Usage

  Contracts are used via implementation of behaviours:

      defmodule MyTrustManager do
        @behaviour Arbor.Contracts.API.Trust

        @impl true
        def create_trust_profile_for_principal(agent_id) do
          # Your implementation
        end
      end

  ## What Doesn't Belong Here

  - Internal implementation details (cluster coordination, etc.)
  - Experimental features still evolving
  - Dev tooling and code generation
  """

  @doc """
  Returns the version of the contracts package.
  """
  @spec version() :: String.t()
  def version, do: "2.0.0-dev"

  @doc """
  Lists all available contract modules.
  """
  @spec list_contracts() :: [module()]
  def list_contracts do
    [
      # Core types
      Arbor.Contracts.Security.Capability,
      # Consensus
      Arbor.Contracts.Consensus.Protocol,
      Arbor.Contracts.Consensus.Proposal,
      Arbor.Contracts.Consensus.Evaluation,
      Arbor.Contracts.Consensus.CouncilDecision,
      Arbor.Contracts.Consensus.ConsensusEvent,
      # Trust
      Arbor.Contracts.Trust.Profile,
      Arbor.Contracts.Trust.Event,
      # Library interfaces
      Arbor.Contracts.API.Shell,
      Arbor.Contracts.API.Signals,
      Arbor.Contracts.API.Security,
      Arbor.Contracts.API.Trust,
      Arbor.Contracts.API.Consensus,
      Arbor.Contracts.API.Historian,
      Arbor.Contracts.API.Persistence
    ]
  end
end
