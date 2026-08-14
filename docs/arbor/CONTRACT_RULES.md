# Arbor Contract Rules

Rules for writing, updating, and consuming contracts in the Arbor ecosystem. Include this in context when working on arbor_contracts or any library that defines or implements behaviours.

---

## 1. What Goes in Contracts

Contracts (`arbor_contracts`) admits only three categories:

**Shared data types** — Structs referenced by two or more umbrella libraries
other than `arbor_contracts`. Exactly one consuming library means the type
belongs to that consumer, not here. The executable consumer census defined by
[`AC-1.0`](../specs/arbor-contracts/AC-1.0.md) decides the question; run
`./bin/mix arbor.contracts.census` rather than inferring consumers from
dependency declarations.
```
Security.Capability, Trust.Profile, Trust.Event
Consensus.Protocol, Consensus.Proposal, Consensus.Evaluation,
Consensus.CouncilDecision, Consensus.ConsensusEvent
```

**Facade behaviours** — Interfaces that define how the Arbor ecosystem consumes libraries. Located in `contracts/api/`.
```
API.Shell, API.Signals, API.Security, API.Trust,
API.Consensus, API.Historian, API.Persistence
```

**Explicitly grandfathered modules** — Temporary exceptions exposed by
`Arbor.Contracts.Census.default_grandfathered/0` and independently asserted by
the admission test, with a justification and linked roadmap item. The shared
runtime inventory ensures the Mix task and test enforce the same policy.
Grandfathering is tracked debt, not an alternative admission path for new
modules.

## 2. What Stays in Libraries

**Library-specific behaviours stay in their library.** If a behaviour is named after the library's domain concept, it belongs there — not in contracts.

```
arbor_consensus owns: Evaluator, Authorizer, Executor, EventSink
arbor_persistence owns: Store, QueryableStore, EventLog
arbor_historian owns: EventLog (its own internal backend interface)
```

Library-owned contract modules use the AC-4 destination convention:
`<AppRootNamespace>.Contracts.<Leaf>`, with a matching path under that app's
`lib/` directory.

**Rule of thumb**: If a developer can use the library without understanding the broader Arbor ecosystem, the behaviour belongs in the library. A contract moves to `arbor_contracts` only when two or more other umbrella libraries consume it, or when it is a facade behaviour under `contracts/api/`.

## 3. Contract Callback Naming

**Facade contract callbacks** (`contracts/api/`) use **AI-readable verbose naming** to prevent semantic drift. The function name encodes what the implementation must do, what it operates on, and key constraints.

**Pattern**: `verb_object_qualifier`

```elixir
# YES — verbose, semantically clear (facade behaviours)
@callback check_if_principal_has_capability_for_resource_action(
  principal_id(), resource_uri(), action(), opts()
) :: {:ok, :authorized} | {:error, :denied | :no_capability | :capability_expired}

@callback grant_capability_to_principal_for_resource(grant_opts()) ::
  {:ok, Capability.t()} | {:error, :invalid_resource | :principal_not_found}

@callback calculate_trust_score_for_principal(principal_id()) ::
  {:ok, trust_score()} | {:error, :not_found}

# NO — ambiguous, allows semantic drift
@callback authorize(principal_id(), resource(), action(), opts()) :: authorization_result()
@callback grant(opts()) :: {:ok, Capability.t()} | {:error, term()}
@callback calculate(principal_id()) :: {:ok, integer()} | {:error, term()}
```

**Implementing libraries wrap with short public API names:**

```elixir
defmodule Arbor.Security do
  @behaviour Arbor.Contracts.API.Security

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

**Scope**: Verbose naming applies to **facade behaviours only** (`API.Shell`, `API.Signals`, `API.Security`, `API.Trust`, `API.Consensus`, `API.Historian`, `API.Persistence`). Domain data types in contracts (`Consensus.Protocol`, `Trust.Profile`, etc.) and library-specific behaviours use standard Elixir naming — they serve different audiences and don't need semantic disambiguation at the ecosystem boundary.

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
| Library depends on another only for a type definition | Move the type to contracts only if a third library also consumes it; otherwise invert the dependency with a behaviour (§9) |
| External dep used directly in 2+ libraries | Create abstraction in contracts |
| Struct has exactly one consuming library | Inadmissible (AC-1). Relocate to that library's `Contracts` namespace |
| Struct growing fields only one consumer uses | Split into shared contract + library-internal struct; see AC-1 |
| Can't implement a behaviour without pulling unrelated library | Behaviour belongs in contracts only if it is a facade behaviour under `api/`; otherwise define it in the consuming library (§2) |
| Behaviour semantics drifted from its docs | Update docs or split the behaviour |
| Config duplicated across libraries | Document convention (not a new contract) |

**NOT triggers**: Adding a new library, internal refactors, performance work, adding tests.

## 7. Change Safety

| Change | Risk | Process |
|--------|------|---------|
| Add newly admitted shared struct | None | Verify AC-1 with the census, then add it |
| Add optional field (with `default:`) | None | Just do it |
| Add required field | HIGH | Audit all `new/1` callers first |
| Remove/rename field | HIGH | Compiler catches. Coordinated update across libraries. |
| Add newly admitted facade behaviour | None | Verify it belongs under `api/`, then add it |
| Add callback to existing behaviour | MEDIUM | Use `@optional_callbacks` for backward compat |
| Remove callback | HIGH | All `@impl true` uses break. Coordinated update. |
| Change return type | MEDIUM | Only Dialyzer catches. Audit consumers. |

**For breaking changes**: Update contracts + all consumers in the same commit. Run full umbrella compile + test.

## 8. Configuration Convention

Not a contract — a documented convention all libraries follow:

- Each library has `Arbor.<Library>.Config` module
- One function per setting with hardcoded default matching current behaviour
- Non-migrated libraries read `Application.get_env(:<app_name>, key, default)`
- Retired owners Common, Signals, and Monitor read only
  `config :arbor_kernel, common|signals|monitor: [...]` through their Config
  facade. Do not `config` or `Application.get_env`/`fetch_env`/`put_env`/
  `delete_env`/`compile_env` `:arbor_common`, `:arbor_signals`,
  `:arbor_monitor`, or `:arbor_contracts`
- There is no generic `Arbor.Kernel` configuration wrapper
- PubSub is always configurable: `Config.pubsub()` defaulting to `Arbor.Core.PubSub`

## 9. Cross-Library Dependencies Use Behaviour Injection

When a library needs to call into another library's internals, use the **behaviour + adapter + config** pattern instead of direct module calls.

```elixir
# 1. Define what you need as a behaviour (in your library)
defmodule Arbor.Trust.Behaviours.CapabilityProvider do
  @callback grant_capability(keyword()) :: {:ok, Capability.t()} | {:error, term()}
  @callback revoke_capability(keyword()) :: :ok | {:error, term()}
  @callback list_capabilities(String.t()) :: {:ok, [Capability.t()]} | {:error, term()}
end

# 2. Default adapter bridges to the other library (in your library)
defmodule Arbor.Trust.Adapters.SecurityCapabilityProvider do
  @behaviour Arbor.Trust.Behaviours.CapabilityProvider
  @impl true
  def grant_capability(opts), do: Arbor.Security.Kernel.grant_capability(opts)
  # ...
end

# 3. Config makes it swappable
defmodule Arbor.Trust.Config do
  def capability_provider,
    do: Application.get_env(:arbor_trust, :capability_provider,
      Arbor.Trust.Adapters.SecurityCapabilityProvider)
end

# 4. Consumer calls through config
capability_provider().grant_capability(opts)
```

**Why**: Coupling is contained in one adapter module. The consuming code only knows about the behaviour. Tests can swap in mocks. If the upstream library changes its API, only the adapter needs updating.

**When to apply**: Whenever a library reaches into another library's internal modules (not its public facade). Direct calls to a library's public facade (`Arbor.Security.authorize/4`) are fine — those are the intended API.

## 10. Dependencies

```
arbor_contracts depends on: NOTHING (typed_struct + jason only)
All libraries depend on: arbor_contracts (at minimum)
```

Contracts must never depend on any Arbor library. If you find yourself wanting contracts to import from a library, the dependency direction is wrong.

## 11. Organization

```
arbor_contracts/lib/arbor/contracts/
  agent/
  ai/
  api/            # Facade behaviours; the only AC-1 multi-consumer exemption
  coding/
  commands/
  comms/
  consensus/
  eval/
  handler/
  healing/
  judge/
  libraries/
  llm/
  memory/
  persistence/
  pipeline/
  security/
  session/
  signal/
  trust/
```

The `api/` directory contains facade behaviours that define how the Arbor ecosystem consumes libraries and is the only directory exempt from the two-consumer rule. Every module in the other directories must satisfy AC-1 or be explicitly grandfathered by the admission test.
