defmodule Arbor.Contracts.Security.Classification do
  @moduledoc """
  Security classification vocabulary — the declared, name-independent attributes
  that drive authorization, separate from the URI used to *address* an operation.

  Per the 2026-06-14 decision "URI addressing vs. security classification":
  security decisions key off these declared/resolved classifications, NOT off
  parsing an `arbor://...` URI string (which is brittle — the same operation has
  multiple URI shapes, and prefix-string matching has failed open before).

  This module is the single, discoverable home for the classification value
  vocabulary. Actions declare their `effect_class` (and, for egressing actions,
  resolve an `egress_tier` from runtime destination) via optional callbacks read
  reflectively by `Arbor.Actions.Egress`. `CapabilityProfile` references these
  same effect-class types.

  ## Effect class

  The static shape of what an operation *does* — declared per-action, independent
  of any specific invocation:

  - `:read` — observes state, no mutation (default for undeclared actions)
  - `:local_write` — mutates on-host state (filesystem, memory)
  - `:process_spawn` — starts a subprocess / new execution context
  - `:network_egress` — sends data off-process to a network destination
  - `:financial` — moves money or incurs metered cost
  - `:identity_mutating` — changes identity/credentials/capabilities
  - `:governance` — changes cluster/operator governance state
  - `:trust_mutating` — changes trust policy, profiles, or graduation state

  ## Egress tier

  For `:network_egress` operations, *how far* the data travels — this is NOT
  static. The same LLM call is on-host (LM Studio on localhost), on-premises
  (homelab LLM on the LAN), or external (cloud provider) depending on the
  destination resolved at call time:

  - `:on_host` — loopback only; data never leaves the machine. Never gated.
  - `:on_premises` — RFC1918/link-local/ULA; leaves the machine but stays on
    operator-owned hardware (the homelab model). Gated only when the operator
    opts in via config (default off).
  - `:external_provider` — a known third-party service (Anthropic, OpenAI). Gated
    (`:ask`).
  - `:external_peer` — an arbitrary/uncontrolled host or peer (web fetch, ACP).
    Highest risk; advisory + telemetry in 1.0 (enforcement deferred).
  - `:none` — the operation does not egress (used as the resolver's default).
  """

  @type effect_class ::
          :read
          | :local_write
          | :process_spawn
          | :network_egress
          | :financial
          | :identity_mutating
          | :governance
          | :trust_mutating

  @type egress_tier ::
          :on_host
          | :on_premises
          | :external_provider
          | :external_peer
          | :none

  @effect_classes [
    :read,
    :local_write,
    :process_spawn,
    :network_egress,
    :financial,
    :identity_mutating,
    :governance,
    :trust_mutating
  ]

  @egress_tiers [:on_host, :on_premises, :external_provider, :external_peer, :none]

  @doc "The full list of valid effect classes."
  @spec effect_classes() :: [effect_class()]
  def effect_classes, do: @effect_classes

  @doc "The full list of valid egress tiers."
  @spec egress_tiers() :: [egress_tier()]
  def egress_tiers, do: @egress_tiers

  @doc """
  Whether an egress tier crosses the trust boundary off operator-owned hardware.

  `:external_provider` and `:external_peer` are the gated tiers; `:on_host` and
  `:on_premises` are not (on-premises is gated only by explicit operator config —
  see `gate_intent/2`). `:none` is not egress.
  """
  @spec external_egress?(egress_tier()) :: boolean()
  def external_egress?(tier), do: tier in [:external_provider, :external_peer]

  @typedoc """
  What the egress gate should do about a resolved tier:

  - `:allow` — let it through (not gated)
  - `:ask` — require human/cap approval (the ceiling `:ask` path)
  - `:advise` — telemetry-only; allow but emit a signal (enforcement deferred)
  """
  @type gate_intent :: :allow | :ask | :advise

  @doc """
  Pure mapping from a resolved egress tier to the gate's enforcement intent.

  This is the name-independent gate decision both the enforcer
  (`Arbor.Security` auth path) and the action layer (`Arbor.Actions.Egress`)
  share — a single source of truth so they can't drift.

  - `:external_provider` → `:ask`
  - `:external_peer` → `:advise` (telemetry-only in 1.0; enforcement deferred)
  - `:on_premises` → `:ask` only when `gate_on_premises?` is true, else `:allow`
    (the homelab/data-sovereignty default is `false`)
  - `:on_host` / `:none` / anything else → `:allow`

  `gate_on_premises?` is passed in (this stays pure — callers read their own
  config). Note this is the *intent*; whether `:ask`/`:advise` actually escalate
  at runtime is gated separately by the enforcer's enforcing flag, so the gate
  can land dark (telemetry only) before enforcement is switched on.
  """
  @spec gate_intent(egress_tier(), boolean()) :: gate_intent()
  def gate_intent(tier, gate_on_premises? \\ false)
  def gate_intent(:external_provider, _on_prem), do: :ask
  def gate_intent(:external_peer, _on_prem), do: :advise
  def gate_intent(:on_premises, true), do: :ask
  def gate_intent(_tier, _on_prem), do: :allow
end
