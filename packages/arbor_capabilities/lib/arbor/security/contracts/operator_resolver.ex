defmodule Arbor.Security.Contracts.OperatorResolver do
  @moduledoc """
  Host-owned mapping from an approval's principal to its human operator.

  A resolver returns the exact configured interaction user identifier. It must
  return an error when no operator is known; the requesting principal is never
  an implicit fallback. Resolution must be synchronous and non-blocking.

  Security validates the result before submitting an interaction. Missing or
  invalid providers, callback failures, and malformed identifiers deny the
  selected router path without submitting a request or trying consensus.
  The provider is trusted host configuration, never a request option.
  """

  @type error ::
          :operator_not_configured
          | :invalid_operator_config
          | :invalid_principal
          | :operator_unavailable

  @callback resolve_operator(String.t()) :: {:ok, String.t()} | {:error, error()}
end
