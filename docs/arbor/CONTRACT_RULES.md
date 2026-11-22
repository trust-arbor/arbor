# Arbor Contract Rules

Rules for writing, updating, and consuming contracts in the Arbor ecosystem. Include this in context when working on the `Arbor.Contracts` namespace in `arbor_kernel` or any library that defines or implements behaviours.

---

## 1. Where a Contract Lives

A contract lives with the library that owns its domain. A behaviour lives with
the library that defines the port; a struct lives with the library that
produces it. When a lower library uses a contract, the lowest library that uses
it owns it, or the consumer depends on the port's owner when it implements that
port. The full ownership table is in
`.arbor/decisions/2026-11-21-contracts-owned-by-their-library.md`.

Moved contracts keep their `Arbor.Contracts.*` module names for now, under
`lib/arbor/contracts/` in the owning app or package. Renames are a later,
per-library decision, because some structs are persisted with
`term_to_binary`.

`packages/arbor_kernel` keeps only primitives that two or more unrelated
libraries share: `Arbor.Types`, `Arbor.Identifiers`, the taint labels and
classification, `CanonicalJson`, `SourceInventory`, the persistence store port
and the extension envelope.
The consumer census enforces this:

```bash
./bin/mix arbor.contracts.census --fail-on-violation
```

It counts actual consumer libraries in `apps/` and `packages/`. A contract in
the kernel with fewer than two consumer libraries fails the census. The
grandfather list (`Arbor.Contracts.Census.default_grandfathered/0`) holds one
internal helper of the shared vector contracts; adding to it is tracked debt,
not an admission path.

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

**Rule of thumb**: If a developer can use the library without understanding the broader Arbor ecosystem, the behaviour belongs in the library. A contract belongs in `arbor_kernel` only when two or more libraries that cannot depend on each other consume it.

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

**Additive integration blocks.** Optional contract blocks that declare deferred intent — for example `Coding.Plan`'s `"integration"` block for forge publish — must be additive and defaulted: absence or a local/default mode must preserve byte-identical behavior for all pre-existing consumers. Omit the block from `to_map/1` unless an explicit publish mode is declared; leave compilation and runtime wiring unchanged until that mode is selected. New fields inside the block follow the same rule: only an explicitly supported publish mode (such as `"pull_request"`) may change serialized output or downstream behavior.

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
| Add a shared struct to the kernel | None | Confirm two unrelated consumers with the census, then add it |
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
arbor_kernel depends on: no in-repo application
arbor_kernel_runtime depends on: arbor_kernel
contracts-only consumers depend on: arbor_kernel
active Common / Signals / Monitor consumers depend on: arbor_kernel_runtime
```

A library declares every library it references directly, including
`arbor_kernel` when it uses kernel modules; it does not rely on receiving the
kernel through `arbor_kernel_runtime`. Contract modules depend only on lower
libraries. If a contract needs to import from a higher-level library, the
dependency direction is wrong.

### Compile-only dependencies (`runtime: false`)

The extracted packages (Signals, Capabilities, Trust, Historian, Persistence,
LLM) are started by a host application according to the boot profile, not by
OTP's dependency order. A consumer therefore declares the package
`runtime: false` and takes a normal dependency on its host:

| Package | Host that starts it |
|---|---|
| `arbor_signals` | `arbor_kernel_runtime` |
| `arbor_capabilities`, `arbor_capabilities_oidc`, `arbor_capabilities_signals` | `arbor_security` |
| `arbor_trust` | `arbor_trust_host` |
| `arbor_historian` | `arbor_historian_host` |
| `arbor_persistence` and its adapters | `arbor_persistence_host` |
| `arbor_llm` | `arbor_llm_host` |

Code may call a `runtime: false` dependency only when it is the host, or its
application has a runtime dependency path to the host. The host is then loaded
and started first and brings the package up. Without that path nothing
guarantees the package is present, and the call fails with `undef` in a
release or peer that leaves the host out.

A package under `packages/` cannot depend on a host. So a package never calls
a compile-only dependency: it declares the dependency normally, or it goes
through a configured port (section 9). Matching on a struct is not a call.

[compile_only_dependency_calls_test.exs](../../apps/arbor_commands/test/arbor/repo_guards/compile_only_dependency_calls_test.exs)
enforces this from the compiled import tables and lists the remaining
exceptions. Add a host to its table when a new package gets one.

## 11. Organization

```
packages/arbor_kernel/lib/arbor/contracts/     # shared primitives only
  coding/      canonical_json.ex, source_inventory.ex
  extension/   envelope.ex
  persistence/ the store port: record.ex, store.ex, revision.ex, filter.ex, vector_*.ex
  security/    taint.ex, taint_envelope.ex, tainted_value.ex, classification.ex

<owner>/lib/arbor/contracts/<domain>/          # everything else, in its owning app or package
<owner>/test/arbor/contracts/<domain>/         # its contract tests
```

Facade behaviours (`contracts/api/*.ex`) live with the library whose facade
they describe.
