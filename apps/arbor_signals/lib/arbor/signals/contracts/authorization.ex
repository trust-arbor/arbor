defmodule Arbor.Signals.Contracts.Authorization do
  @moduledoc """
  Consumer-owned port for restricted-topic subscription authorization.

  Library-specific to `arbor_signals`. Implementations live above this
  library and are injected via `Arbor.Signals.Config.security_module/0`.

  The port carries only Signals-shaped primitives: principal id, the
  canonical `arbor://signals/subscribe/<topic>` URI, the `:subscribe`
  action, and optional raw `:session_token` entries. It does not verify
  session tokens or apply identity policy.

  Admitted callback results:

  - `{:ok, :authorized}` — the principal may subscribe
  - `{:ok, :pending_approval, String.t()}` — approval is required
  - `{:error, term()}` — the subscription is denied
  """

  @type principal_id :: String.t()
  @type resource_uri :: String.t()
  @type action :: atom()
  @type opts :: keyword()

  @callback authorize(principal_id(), resource_uri(), action(), opts()) ::
              {:ok, :authorized} | {:ok, :pending_approval, String.t()} | {:error, term()}
end
