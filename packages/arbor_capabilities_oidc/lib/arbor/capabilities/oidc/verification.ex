defmodule Arbor.Capabilities.OIDC.Verification do
  @moduledoc false

  @enforce_keys [:token, :provider, :header]
  defstruct [:token, :provider, :header]

  @opaque t :: %__MODULE__{token: binary(), provider: map(), header: term()}

  defimpl Inspect do
    def inspect(_context, _opts) do
      "#Arbor.Capabilities.OIDC.Verification<[REDACTED]>"
    end
  end
end
