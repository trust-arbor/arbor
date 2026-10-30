defmodule Arbor.Common.OAuth.Config do
  @moduledoc """
  Configuration authority for the standalone OAuth transport.

  `:arbor_oauth, :http_client` is authoritative when present, including `nil`
  and invalid values. Request dispatch validates the selected provider and
  refuses invalid selections. When the package setting is absent, the existing
  `:arbor_kernel, :common` `:oauth_http_client` setting remains compatible.
  Reading that legacy configuration does not require loading either app.
  """

  @default_adapter Arbor.Common.OAuth.HttpClient.Req

  @doc "Return the authoritative adapter selection without replacing invalid values."
  @spec http_client() :: term()
  def http_client do
    case Application.fetch_env(:arbor_oauth, :http_client) do
      {:ok, configured} -> configured
      :error -> legacy_http_client()
    end
  end

  defp legacy_http_client do
    case Application.fetch_env(:arbor_kernel, :common) do
      :error -> @default_adapter
      {:ok, config} -> legacy_namespace_adapter(config)
    end
  end

  defp legacy_namespace_adapter(config) when is_list(config) do
    if Keyword.keyword?(config) do
      Keyword.get(config, :oauth_http_client, @default_adapter)
    else
      raise ArgumentError, malformed_namespace_message()
    end
  end

  defp legacy_namespace_adapter(%{__struct__: _}) do
    raise ArgumentError, malformed_namespace_message()
  end

  defp legacy_namespace_adapter(%{} = config) do
    Map.get(config, :oauth_http_client, @default_adapter)
  end

  defp legacy_namespace_adapter(_config) do
    raise ArgumentError, malformed_namespace_message()
  end

  defp malformed_namespace_message do
    "Arbor.Common.Config malformed :arbor_kernel :common namespace"
  end
end
