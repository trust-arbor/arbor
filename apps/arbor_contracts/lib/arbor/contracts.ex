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

  ## Contract Categories

  ### Core Types
  - `Arbor.Contracts.Core.Message` - Inter-agent communication
  - `Arbor.Contracts.Core.Capability` - Permission tokens
  - `Arbor.Contracts.Core.Session` - Execution contexts

  ### Security
  - `Arbor.Contracts.Security.AuditEvent` - Security audit trail
  - `Arbor.Contracts.Security.Enforcer` - Authorization enforcement behaviour

  ### Trust
  - `Arbor.Contracts.Trust` - Trust system behaviour and helpers
  - `Arbor.Contracts.Trust.Profile` - Agent trust state
  - `Arbor.Contracts.Trust.Event` - Trust-affecting events

  ### Library Interfaces
  - `Arbor.Contracts.Libraries.Shell` - Command execution interface
  - `Arbor.Contracts.Libraries.Signals` - Event emission interface
  - `Arbor.Contracts.Libraries.Security` - Security facade interface
  - `Arbor.Contracts.Libraries.Trust` - Trust facade interface

  ## Usage

  Contracts are used via `use` or implementation of behaviours:

      defmodule MyEnforcer do
        @behaviour Arbor.Contracts.Security.Enforcer

        @impl true
        def authorize(agent_id, resource, action) do
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
      Arbor.Contracts.Core.Message,
      Arbor.Contracts.Core.Capability,
      Arbor.Contracts.Core.Session,
      # Security
      Arbor.Contracts.Security.AuditEvent,
      Arbor.Contracts.Security.Enforcer,
      # Trust
      Arbor.Contracts.Trust,
      Arbor.Contracts.Trust.Profile,
      Arbor.Contracts.Trust.Event,
      # Library interfaces
      Arbor.Contracts.Libraries.Shell,
      Arbor.Contracts.Libraries.Signals,
      Arbor.Contracts.Libraries.Security,
      Arbor.Contracts.Libraries.Trust
    ]
  end
end
