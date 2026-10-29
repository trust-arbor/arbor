# Arbor Kernel

Passive contracts, type definitions, identifiers, and protocols for the Arbor
AI agent orchestration system. This application has no OTP callback or active
service tree; runtime Common, Signals, and Monitor services are owned by
`arbor_kernel_runtime`.

The monorepo source of truth is `packages/arbor_kernel`. This package retains
the existing `Arbor.Contracts.*`, `Arbor.Types`, and `Arbor.Identifiers` module
identities. It has no first-party dependencies. Its runtime dependencies are
TypedStruct, Jason, and the OTP Logger and Crypto applications; Crypto supports
the public identity, signed-request, identifier, and digest functions.

Starting Kernel does not start Security, Kernel Runtime, Signals, or a signing
authority broker. SigningAuthority and SigningAuthorityBootstrap are validated,
redacted references. Constructing one does not issue authority or prove that a
broker recognizes its token.

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
    {:arbor_kernel, "~> 2.0.0-dev"}
  ]
end
```

Inside Arbor, consumers resolve the same application through its monorepo path
dependency. Outside Arbor, the project uses ordinary Mix dependency, build, and
configuration paths; no umbrella `build_support`, config, lockfile, or source
checkout is required. Publication remains a separate decision.

See [adoption rationale](docs/ADOPTION.md) for source ownership and compatibility,
and the monorepo's `examples/standalone` directory for an independent cold
SigningAuthority/Bootstrap and crypto smoke fixture.

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
