defmodule Arbor.Security.Contracts.InteractionRouter do
  @moduledoc """
  Security-owned port for HITL approval routing.

  Library-specific to `arbor_security`. Production injects
  `Arbor.Comms.InteractionRouter` via `Arbor.Security.Config.interaction_router/0`.
  Tests inject a local fake; this library does not compile against arbor_comms.

  Admitted callback results:

  - `request/2` — `{:ok, request_id}` when the router accepted the approval
    request, or `{:error, term()}` when it could not. Common reasons include
    `:invalid_request` and adapter/registry failures from the host router.
  """

  @type request_attrs :: map()
  @type opts :: keyword()
  @type request_id :: String.t()

  @callback request(request_attrs(), opts()) :: {:ok, request_id()} | {:error, term()}
end
