defmodule Arbor.Security.Contracts.RuntimeHost do
  @moduledoc """
  Capabilities-owned port for trusted product startup integration.

  The host selects one static module through `:arbor_capabilities, :runtime_host`.
  It establishes its runtime before Capabilities claims any authority state.
  Standalone consumers leave the selector unset or explicitly `nil` and supply
  their own closed `:runtime, start_profile: :full | :activation_only` setting.

  `prepare_startup/0` returns `:ok` after the host runtime is ready, or an error.
  `start_profile/0` returns the selected closed profile. `boot_profile/0` returns
  a bound snapshot or `:not_bound`; it never creates an authority binding.
  The gate callbacks preserve the host's existing provider-gate child spec and
  OTP startup result, including its actionable provider-startup error reasons.
  Those host/OTP reasons are deliberately open-ended `term()` values. Common
  preparation failures are `:not_bound` and `{application, startup_reason}`;
  gate failures include `{:provider_gate_name_collision, pid}` and
  `{:provider_start_failed, application, startup_reason}`. The invoker separately
  rejects unavailable providers and malformed callback responses.

  Invalid, missing or crashed configured providers fail closed. No callback is
  selected from request input and no unavailable host falls back to standalone.
  """

  @type profile :: :full | :activation_only
  @type host_error :: term()

  @callback prepare_startup() :: :ok | {:error, host_error()}
  @callback start_profile() :: profile() | {:error, host_error()}
  @callback boot_profile() :: {:ok, map()} | {:error, :not_bound}
  @callback provider_gate_child_spec(atom(), [atom()]) ::
              Supervisor.child_spec() | {:error, host_error()}
  @callback start_provider_gate_supervisor([Supervisor.child_spec()], atom(), atom()) ::
              {:ok, pid()} | {:error, host_error()}
end
