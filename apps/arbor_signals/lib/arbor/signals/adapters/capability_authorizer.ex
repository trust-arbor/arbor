defmodule Arbor.Signals.Adapters.CapabilityAuthorizer do
  @moduledoc """
  Capability-based subscription authorizer using fast ETS lookups.

  Checks whether a principal has a capability granting access to the
  `arbor://signals/subscribe/{topic}` resource via `Arbor.Security.can?/3`.
  Unlike `SecurityAuthorizer` (which calls `authorize/4` for the full pipeline
  including identity verification, constraints, reflexes, and escalation), this
  authorizer uses the lightweight `can?/3` check — a pure ETS lookup that only
  verifies capability existence.

  This is the recommended authorizer for dev/prod environments where the
  security kernel is running, since signal subscription authorization should
  be fast and non-blocking (no GenServer calls in the hot path).

  ## Runtime Bridge Pattern

  Uses `Code.ensure_loaded?/1` + `apply/3` to resolve `Arbor.Security` at
  runtime. This avoids a compile-time dependency from `arbor_signals` (Level 1)
  on `arbor_security` (Level 1) — same-level horizontal dependencies are
  prohibited by the library hierarchy.

  If the security module is not loaded (e.g., during isolated testing), the
  authorizer falls back to denying the subscription with `{:error, :no_capability}`.

  ## Configuration

  The security facade module can be overridden via:

      config :arbor_signals, :security_module, MyCustomSecurityModule

  Default: `Arbor.Security`
  """

  @behaviour Arbor.Signals.Behaviours.SubscriptionAuthorizer

  require Logger

  @default_security_module Arbor.Security

  @impl true
  def authorize_subscription(principal_id, topic) do
    security_module = security_module()
    resource_uri = "arbor://signals/subscribe/#{topic}"

    if Code.ensure_loaded?(security_module) and
         function_exported?(security_module, :can?, 3) do
      # can?/3 is a fast ETS-only capability check — no GenServer calls,
      # no identity verification, no constraint enforcement. Ideal for
      # subscribe-time gating where delivery-time checks provide the second layer.

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(security_module, :can?, [principal_id, resource_uri, :subscribe]) do
        true -> {:ok, :authorized}
        false -> {:error, :no_capability}
      end
    else
      Logger.warning(
        "CapabilityAuthorizer: security module #{inspect(security_module)} not loaded, " <>
          "denying subscription for #{inspect(principal_id)} to #{inspect(topic)}"
      )

      {:error, :no_capability}
    end
  rescue
    error ->
      Logger.error(
        "CapabilityAuthorizer: error checking capability for #{inspect(principal_id)} " <>
          "on topic #{inspect(topic)}: #{inspect(error)}"
      )

      {:error, :no_capability}
  end

  @doc false
  def security_module do
    Application.get_env(:arbor_signals, :security_module, @default_security_module)
  end
end
