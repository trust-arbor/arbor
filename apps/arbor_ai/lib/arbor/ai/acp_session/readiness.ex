defmodule Arbor.AI.AcpSession.Readiness do
  @moduledoc false

  alias Arbor.AI.AcpSession.Readiness.Internal

  @spec observe(atom() | String.t(), String.t() | nil) :: map()
  def observe(provider, requested_model \\ nil) do
    Internal.observe(provider, requested_model, [])
  end
end
