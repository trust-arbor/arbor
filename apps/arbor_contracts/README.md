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

```elixir
defmodule MyEnforcer do
  @behaviour Arbor.Contracts.Security.Enforcer

  @impl true
  def authorize(agent_id, resource, action) do
    # Your implementation
  end
end
```

## License

MIT
