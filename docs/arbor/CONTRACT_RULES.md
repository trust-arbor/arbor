# Arbor Contract Rules

Rules for writing, updating, and consuming contracts in the Arbor ecosystem. Include this in context when working on arbor_contracts or any library that defines or implements behaviours.

---

## 1. What Goes in Contracts

Contracts (`arbor_contracts`) contains three things:

**Shared data types** — Structs that appear in multiple libraries' APIs.
```
Capability, Event, Proposal, Evaluation, CouncilDecision, Trust.Profile, Trust.Event
```

**External dep abstractions** — Behaviours that let implementations swap Horde, Postgres, Redis, etc. without changing consumers.
```
contracts/distributed/  — abstracts Horde, pg, :global
contracts/persistence/  — abstracts Ecto/Postgres, Redis, ETS
```

**Facade behaviours** — Interfaces that define how the Arbor ecosystem consumes libraries. Located in `contracts/libraries/`.
```
Libraries.Shell, Libraries.Signals, Libraries.Security, Libraries.Trust
```

## 2. What Stays in Libraries

**Library-specific behaviours stay in their library.** If a behaviour is named after the library's domain concept, it belongs there — not in contracts.

```
arbor_consensus owns: EvaluatorBackend, Authorizer, Executor, EventSink
arbor_persistence owns: Store, QueryableStore, EventLog
arbor_historian owns: EventLog (its own internal backend interface)
```

**Rule of thumb**: If a developer can use the library without understanding the broader Arbor ecosystem, the behaviour belongs in the library. If it abstracts an external system or defines how Arbor libraries talk to each other, it goes in contracts.

## 3. Contract Callback Naming

Contract `@callback` names use **AI-readable verbose naming** to prevent semantic drift. The function name encodes what the implementation must do, what it operates on, and key constraints.

**Pattern**: `verb_object_qualifier`

```elixir
# YES — verbose, semantically clear
@callback check_if_principal_has_capability_for_resource_action(
  principal_id(), resource_uri(), action(), opts()
) :: {:ok, :authorized} | {:error, :denied | :no_capability | :capability_expired}

@callback grant_capability_to_principal_for_resource(grant_opts()) ::
  {:ok, Capability.t()} | {:error, :invalid_resource | :principal_not_found}

@callback calculate_trust_score_for_principal_from_event_history(principal_id()) ::
  {:ok, trust_score()} | {:error, :not_found}

# NO — ambiguous, allows semantic drift
@callback authorize(principal_id(), resource(), action(), opts()) :: authorization_result()
@callback grant(opts()) :: {:ok, Capability.t()} | {:error, term()}
@callback calculate(principal_id()) :: {:ok, integer()} | {:error, term()}
```

**Implementing libraries wrap with short public API names:**

```elixir
defmodule Arbor.Security do
  @behaviour Arbor.Contracts.Libraries.Security

  # Public API — short, human-friendly
  def authorize(principal_id, resource_uri, action, opts \\ []),
    do: check_if_principal_has_capability_for_resource_action(principal_id, resource_uri, action, opts)

  # Contract implementation — verbose, AI-readable
  @impl true
  def check_if_principal_has_capability_for_resource_action(principal_id, resource_uri, action, opts) do
    # implementation
  end
end
```

**Library-specific behaviours** (those staying in libraries, not contracts) use standard Elixir naming. The verbose naming rule only applies to contract callbacks.

## 4. Return Types

Contract callbacks must enumerate their error cases explicitly. Do not use `{:error, term()}`.

```elixir
# YES — explicit failure modes
:: {:ok, :authorized} | {:error, :denied | :no_capability | :capability_expired}
:: {:ok, Capability.t()} | {:error, :invalid_resource | :principal_not_found}
:: :ok | {:error, :not_found | :already_revoked}

# NO — hides failure semantics
:: {:ok, term()} | {:error, term()}
:: authorization_result()
```

Exception: If the error space is genuinely open-ended (e.g., network errors from external deps), use `{:error, term()}` but document the common cases in `@doc`.

## 5. Struct Rules

**Always use `TypedStruct` with `enforce: true`:**
```elixir
typedstruct enforce: true do
  field(:id, String.t())
  field(:name, String.t())
  field(:metadata, map(), default: %{})  # optional fields use default:
end
```

**Always provide a `new/1` factory function.** Never allow direct `%Struct{}` construction outside the module.

```elixir
@spec new(keyword()) :: {:ok, t()} | {:error, term()}
def new(attrs) do
  # validate and construct
end
```

**Start minimal.** Fewer fields is better. You can add fields (additive, safe). Removing fields is a breaking change that requires coordinated updates.

**Field naming**: Descriptive but standard Elixir. `expires_at` not `exp`. `principal_id` not `pid`. No abbreviations.

## 6. When to Update Contracts

These triggers mean you should evaluate whether a contract needs to change:

| Trigger | Action |
|---------|--------|
| Two libraries define the same struct or behaviour | Extract shared concept to contracts |
| Library depends on another only for a type definition | That type probably belongs in contracts |
| External dep used directly in 2+ libraries | Create abstraction in contracts |
| Struct growing fields only one consumer uses | Split into shared contract + library-internal struct |
| Can't implement a behaviour without pulling unrelated library | Behaviour might belong in contracts |
| Behaviour semantics drifted from its docs | Update docs or split the behaviour |
| Config duplicated across libraries | Document convention (not a new contract) |

**NOT triggers**: Adding a new library, internal refactors, performance work, adding tests.

## 7. Change Safety

| Change | Risk | Process |
|--------|------|---------|
| Add new struct | None | Just do it |
| Add optional field (with `default:`) | None | Just do it |
| Add required field | HIGH | Audit all `new/1` callers first |
| Remove/rename field | HIGH | Compiler catches. Coordinated update across libraries. |
| Add new behaviour | None | No one forced to implement |
| Add callback to existing behaviour | MEDIUM | Use `@optional_callbacks` for backward compat |
| Remove callback | HIGH | All `@impl true` uses break. Coordinated update. |
| Change return type | MEDIUM | Only Dialyzer catches. Audit consumers. |

**For breaking changes**: Update contracts + all consumers in the same commit. Run full umbrella compile + test. Update both repos (arbor + trust-arbor).

## 8. Configuration Convention

Not a contract — a documented convention all libraries follow:

- Each library has `Arbor.<Library>.Config` module
- Reads from `Application.get_env(:<app_name>, key, default)`
- One function per setting with hardcoded default matching current behaviour
- PubSub is always configurable: `Config.pubsub()` defaulting to `Arbor.PubSub`

## 9. Dependencies

```
arbor_contracts depends on: NOTHING (typed_struct + jason only)
All libraries depend on: arbor_contracts (at minimum)
```

Contracts must never depend on any Arbor library. If you find yourself wanting contracts to import from a library, the dependency direction is wrong.

## 10. Organization

```
arbor_contracts/lib/arbor/contracts/
  core/           # Shared data types: Capability, Session, Message
  events/         # Event struct (used by historian, persistence, trust)
  trust/          # Trust.Profile, Trust.Event
  security/       # Enforcer behaviour, AuditEvent
  autonomous/     # Proposal, Evaluation, CouncilDecision, ConsensusEvent
  distributed/    # Behaviours abstracting Horde, pg, :global
  persistence/    # Behaviours abstracting Postgres, Redis (database adapters)
  libraries/      # Facade behaviours: Shell, Signals, Security, Trust
```

`distributed/` and `persistence/` abstract external dependencies. They are NOT the same as `arbor_persistence`'s Store/QueryableStore (which are application-level storage interfaces that stay in that library).
