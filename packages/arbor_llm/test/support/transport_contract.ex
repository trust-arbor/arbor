defmodule Arbor.LLM.TestSupport.TransportContract do
  @moduledoc """
  Explicit finite host policy for synchronous package transport tests.

  Routes are declared by the owning test, never inferred from a provider name,
  model suffix, locality or request options. This is not the product AI policy.
  """

  @behaviour Arbor.LLM.Contracts.SensitivityPolicy

  @routes_key :test_transport_contract_routes
  @levels [:public, :internal, :confidential, :restricted]
  @destination_keys [:base_url, :model, :provider, :runtime, :sensitivity]

  def route(provider, model, level, url, runtime \\ :arbor)
      when is_binary(provider) and provider != "" and is_binary(model) and
             level in @levels and runtime == :arbor do
    {provider, model, level, runtime, origin!(url)}
  end

  def setup(routes) do
    routes = canonical_routes!(routes)

    previous =
      Enum.map([:sensitivity_policy, @routes_key], fn key ->
        {key, Application.fetch_env(:arbor_llm, key)}
      end)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_llm, key, value)
        {key, :error} -> Application.delete_env(:arbor_llm, key)
      end)
    end)

    Application.put_env(:arbor_llm, @routes_key, routes)
    Application.put_env(:arbor_llm, :sensitivity_policy, __MODULE__)
    :ok
  end

  # A test may add the exact origin of a newly bound private HTTP listener.
  def allow(routes) do
    {:ok, current} = configured_routes()
    Application.put_env(:arbor_llm, @routes_key, canonical_routes!(current ++ routes))
    :ok
  end

  @impl true
  def authorize_llm_sensitivity(destination)
      when is_map(destination) and not is_struct(destination) do
    with true <- Enum.sort(Map.keys(destination)) == @destination_keys,
         {:ok, routes} <- configured_routes() do
      candidate =
        route(
          destination.provider,
          destination.model,
          destination.sensitivity,
          destination.base_url,
          destination.runtime
        )

      if candidate in routes, do: :ok, else: {:error, :destination_disallowed}
    else
      _ -> {:error, :invalid_destination}
    end
  rescue
    _ -> {:error, :invalid_destination}
  end

  def authorize_llm_sensitivity(_), do: {:error, :invalid_destination}

  @impl true
  def llm_sensitivity_identity do
    case configured_routes() do
      {:ok, routes} ->
        bytes = :erlang.term_to_binary(routes, [:deterministic])

        {:ok,
         %{
           "configuration_digest" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
           "implementation" => [
             %{
               "module" => Atom.to_string(__MODULE__),
               "md5" => Base.encode16(__MODULE__.module_info(:md5), case: :lower)
             }
           ]
         }}

      _ ->
        {:error, :policy_unavailable}
    end
  rescue
    _ -> {:error, :policy_unavailable}
  end

  defp configured_routes do
    routes = Application.get_env(:arbor_llm, @routes_key)

    if Application.get_env(:arbor_llm, :sensitivity_policy) == __MODULE__ and
         canonical_routes!(routes) == routes,
       do: {:ok, routes},
       else: {:error, :policy_unavailable}
  rescue
    _ -> {:error, :policy_unavailable}
  end

  defp canonical_routes!(routes) when is_list(routes) and length(routes) in 1..64 do
    true = Enum.all?(routes, &valid_route?/1)
    routes |> Enum.uniq() |> Enum.sort()
  end

  defp canonical_routes!(_), do: raise(ArgumentError, "finite transport routes required")

  defp valid_route?({provider, model, level, :arbor, origin})
       when is_binary(provider) and byte_size(provider) in 1..128 and
              is_binary(model) and byte_size(model) in 0..512 and level in @levels do
    String.valid?(provider) and String.valid?(model) and valid_origin?(origin)
  end

  defp valid_route?(_), do: false
  defp valid_origin?(:unspecified), do: true

  defp valid_origin?({scheme, host, port})
       when scheme in ["http", "https"] and is_binary(host) and host != "" and
              port in 1..65_535,
       do: String.valid?(host) and String.downcase(host) == host

  defp valid_origin?(_), do: false
  defp origin!(nil), do: :unspecified

  defp origin!(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             port in 1..65_535 ->
        {scheme, String.downcase(host), port}

      _ ->
        raise ArgumentError, "exact HTTP origin required"
    end
  end
end
