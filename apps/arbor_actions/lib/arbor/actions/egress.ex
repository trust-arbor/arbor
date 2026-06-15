defmodule Arbor.Actions.Egress do
  @moduledoc """
  Effect-class and egress-tier resolution for actions (2026-06-14 egress decision).

  Security keys off an action's *declared classification*, not off parsing the
  `arbor://...` URI that addresses it (which is brittle — see the decision doc
  `.arbor/decisions/2026-06-14-uri-addressing-vs-security-classification.md`).
  This module is the reader/projection layer, mirroring `Arbor.Actions.Taint`:
  actions declare classification via optional callbacks, read here reflectively
  with safe defaults.

  ## What actions declare

      defmodule MyEgressingAction do
        use Jido.Action, ...

        # Static: what shape of effect this action has.
        def effect_class, do: :network_egress

        # Runtime: resolve how far the data travels, from this call's params.
        # Return an Arbor.Contracts.Security.Classification.egress_tier/0.
        def egress_tier(params, _context) do
          Arbor.Common.EgressClassifier.locality(params[:url])
          |> case do
            :on_host -> :on_host
            :on_premises -> :on_premises
            :public -> :external_peer
          end
        end
      end

  ## Defaults (fail-closed for egress)

  - An action without `effect_class/0` is `:read` (the safe non-egress default).
  - An action that declares `:network_egress` but does NOT implement
    `egress_tier/2` resolves to `:external_provider` — the *gated* tier — so a
    forgotten resolver fails closed (asks) rather than open. The runtime resolver
    is the backstop; the declaration is the intent.
  - A non-egress action resolves to `:none`.

  ## Gating

  `gate_decision/2` turns a resolved tier into the gate's intent:

  - `:on_host` → `:allow` (never gated)
  - `:on_premises` → `:allow`, unless the operator opts in via
    `config :arbor_actions, :gate_on_premises_egress, true` (default off — the
    homelab/data-sovereignty model)
  - `:external_provider` → `:ask`
  - `:external_peer` → `:advise` (telemetry-only in 1.0; enforcement deferred)
  - `:none` → `:allow`
  """

  alias Arbor.Contracts.Security.Classification

  @type gate :: :allow | :ask | :advise

  @doc """
  Get the declared static effect class for an action module.

  Calls `action_module.effect_class/0` if defined, otherwise `:read`.

  ## Examples

      iex> Arbor.Actions.Egress.effect_class_for(SomeActionWithoutDeclaration)
      :read
  """
  @spec effect_class_for(module()) :: Classification.effect_class()
  def effect_class_for(action_module) do
    Code.ensure_loaded(action_module)

    if function_exported?(action_module, :effect_class, 0) do
      action_module.effect_class()
    else
      :read
    end
  end

  @doc """
  Resolve the egress tier for a specific action invocation.

  For `:network_egress` actions, prefers the action's `egress_tier/2` callback
  (resolves the concrete destination from params/context). If an egressing action
  does not implement it, defaults to `:external_provider` (fail closed — gated).
  Non-egress actions return `:none`.

  ## Examples

      iex> Arbor.Actions.Egress.egress_tier_for(SomeReadAction, %{}, %{})
      :none
  """
  @spec egress_tier_for(module(), map(), map()) :: Classification.egress_tier()
  def egress_tier_for(action_module, params, context \\ %{}) do
    Code.ensure_loaded(action_module)

    cond do
      function_exported?(action_module, :egress_tier, 2) ->
        action_module.egress_tier(params, context)

      effect_class_for(action_module) == :network_egress ->
        # Declared egress but no resolver — fail closed to the gated tier.
        :external_provider

      true ->
        :none
    end
  end

  @doc """
  Resolve the concrete egress destination (host or provider string) for this
  invocation, for destination-scoped egress caps. Reads an optional
  `egress_destination/2` action callback; returns `nil` when the action does not
  declare one (then only tier-level cap matching applies).
  """
  @spec egress_destination_for(module(), map(), map()) :: String.t() | nil
  def egress_destination_for(action_module, params, context \\ %{}) do
    Code.ensure_loaded(action_module)

    if function_exported?(action_module, :egress_destination, 2) do
      action_module.egress_destination(params, context)
    else
      nil
    end
  end

  @doc """
  Turn a resolved egress tier into the gate's enforcement intent.

  Thin convenience over `Arbor.Contracts.Security.Classification.gate_intent/2`
  (the shared, name-independent mapping) that reads the `:on_premises` gating
  flag from config. Pass `gate_on_premises: bool` to override.

  The flag default is `false` (homelab/data-sovereignty model). The enforcer
  (`Arbor.Security` auth path) reads the same `:gate_on_premises_egress` key.
  """
  @spec gate_decision(Classification.egress_tier(), keyword()) :: gate()
  def gate_decision(tier, opts \\ []) do
    Classification.gate_intent(tier, gate_on_premises?(opts))
  end

  defp gate_on_premises?(opts) do
    Keyword.get_lazy(opts, :gate_on_premises, fn ->
      Application.get_env(:arbor_security, :gate_on_premises_egress, false)
    end)
  end
end
