defmodule Arbor.Common.CapabilityProviders.ActionCapabilityURI do
  @moduledoc """
  Consumer-owned port for canonical action capability URI resolution.

  Library-specific to `arbor_common`. Implementations live above this
  library and are injected via `Arbor.Common.Config.action_capability_uri_module/0`.
  """

  @callback canonical_uri_for(module(), map()) :: String.t()
end
