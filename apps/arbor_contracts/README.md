# Arbor.Contracts

Contracts and type definitions for the Arbor AI agent orchestration system.

## Philosophy: Graduated Contracts

Arbor uses "contracts as graduation, not specification":

1. **Experimental phase** - Build rapidly, no contracts enforced
2. **Graduation** - Human confirms "this works" → generate contract from implementation
3. **Stable phase** - Contract enforced, drift detection enabled

Only interfaces that have proven themselves through real usage become contracts.

## Installation

```elixir
def deps do
  [
    {:arbor_contracts, "~> 2.0"}
  ]
end
```

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

## Usage

Contracts are used via `use` or implementation of behaviours:

```elixir
defmodule MyTrustManager do
  @behaviour Arbor.Contracts.API.Trust

  @impl true
  def create_trust_profile_for_principal(agent_id) do
    # Your implementation
  end
end
```

## License

MIT
