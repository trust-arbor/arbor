defmodule Arbor.Security.OIDC.Adapter do
  @moduledoc """
  Host-owned invocation boundary for the optional OIDC protocol provider.

  The provider comes only from trusted Security configuration. Disabled,
  missing, invalid or crashed providers return `:oidc_adapter_unavailable`;
  none of those conditions changes configured-provider policy or selects a
  fallback provider. Provider exceptions and exit reasons never cross here.
  """

  alias Arbor.Security.OIDC.Config

  @operations %{
    build_authorize_url: 4,
    exchange_code: 4,
    start_device_flow: 1,
    poll_device_flow: 2,
    refresh_device_flow: 2,
    discover: 2,
    validate_issuer: 2,
    discovery_url: 1,
    prepare_verification: 2,
    verify_prepared: 2,
    fetch_jwks_uncached: 1,
    decode_unverified: 1
  }
  @map_operations [
    :exchange_code,
    :start_device_flow,
    :poll_device_flow,
    :refresh_device_flow,
    :discover,
    :verify_prepared,
    :fetch_jwks_uncached,
    :decode_unverified
  ]

  @doc false
  @spec call(atom(), [term()]) :: term()
  def call(operation, arguments) when is_atom(operation) and is_list(arguments) do
    adapter = Config.protocol_adapter()

    with arity when is_integer(arity) <- Map.get(@operations, operation),
         true <- length(arguments) == arity,
         true <- is_atom(adapter) and adapter not in [nil, false],
         true <- Code.ensure_loaded?(adapter),
         true <- function_exported?(adapter, operation, arity) do
      admit_result(operation, apply(adapter, operation, arguments))
    else
      _ -> unavailable()
    end
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  def call(_operation, _arguments), do: unavailable()

  defp admit_result(:build_authorize_url, {:ok, url, verifier} = result)
       when is_binary(url) and is_binary(verifier),
       do: result

  defp admit_result(:validate_issuer, {:ok, issuer} = result) when is_binary(issuer), do: result
  defp admit_result(:discovery_url, url) when is_binary(url), do: url
  defp admit_result(:prepare_verification, {:ok, _opaque_context} = result), do: result

  defp admit_result(operation, {:ok, value} = result)
       when operation in @map_operations and is_map(value),
       do: result

  defp admit_result(_operation, {:error, _reason} = result), do: result
  defp admit_result(_operation, _unexpected), do: unavailable()

  defp unavailable, do: {:error, :oidc_adapter_unavailable}
end
