defmodule Arbor.Common.OAuth do
  @moduledoc """
  Provider-neutral OAuth acquisition protocols and bounded HTTP transport.

  The package retains the existing `Arbor.Common.OAuth` module and struct
  identities. It owns this independent top-level boundary; it does not depend
  on Common or Kernel Runtime. Hosts own provider application and pool startup.

  Use `Arbor.Common.OAuth.AuthCode` for authorization-code operations,
  `Arbor.Common.OAuth.DeviceCode` for device-code operations, and
  `Arbor.Common.OAuth.HttpClient` for bounded HTTP requests. The stable
  `Arbor.Common.OAuth.HttpClient.Pool` child specification is explicit.
  """

  use Boundary,
    top_level?: true,
    deps: [Finch, Jason, Logger, Req],
    exports: :all
end
