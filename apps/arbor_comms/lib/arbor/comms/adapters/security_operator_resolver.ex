defmodule Arbor.Comms.Adapters.SecurityOperatorResolver do
  @moduledoc """
  Bridge Security's operator-resolution port to the public Comms facade.

  The host injects this adapter into Security. Missing or invalid Comms
  operator configuration is returned as an error without an identity fallback.
  """

  @behaviour Arbor.Security.Contracts.OperatorResolver

  @impl true
  def resolve_operator(principal_id), do: Arbor.Comms.resolve_operator_for_agent(principal_id)
end
