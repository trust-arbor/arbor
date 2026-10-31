defmodule Arbor.LLM.Contracts.SensitivityPolicy do
  @moduledoc "Host-owned clearance policy for an exact outbound model destination."
  @callback authorize_llm_sensitivity(map()) ::
              :ok | {:error, :destination_disallowed | :invalid_destination}

  @doc "Bind policy implementation and configuration for stock transport attestation."
  @callback llm_sensitivity_identity() :: {:ok, map()} | {:error, :policy_unavailable}
  @optional_callbacks llm_sensitivity_identity: 0
end
