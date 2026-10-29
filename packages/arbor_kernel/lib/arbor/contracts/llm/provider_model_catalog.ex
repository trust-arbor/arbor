defmodule Arbor.Contracts.LLM.ProviderModelCatalog do
  @moduledoc """
  Versioned, closed provider-reported subscription model-catalog evidence.

  Carries only exact Arbor OAuth route/backend/runtime identity, bounded model
  IDs, observation windows, and the credential generation used for the fetch.
  No token, account id, path, owner, origin, source, raw body, or free-form
  provider text is admitted. Every admitted value canonicalizes under 32768
  bytes.
  """

  use TypedStruct

  alias Arbor.Contracts.LLM.ControlPlaneSupport, as: Support

  @schema_version 1
  @routes ["openai_oauth", "xai_oauth"]
  @backends ["openai", "xai"]
  @runtimes ["arbor"]
  @fields [
    :version,
    :route,
    :backend,
    :runtime,
    :model_ids,
    :observed_at,
    :expires_at,
    :credential_generation
  ]
  @max_bytes 32_768
  @max_models 512
  @max_model_id_bytes 256
  @max_generation 1_000_000_000_000

  @route_backend_runtimes %{
    {"openai_oauth", "openai", "arbor"} => true,
    {"xai_oauth", "xai", "arbor"} => true
  }

  typedstruct enforce: true do
    field(:version, pos_integer(), default: @schema_version)
    field(:route, String.t())
    field(:backend, String.t())
    field(:runtime, String.t())
    field(:model_ids, [String.t()])
    field(:observed_at, String.t())
    field(:expires_at, String.t())
    field(:credential_generation, non_neg_integer())
  end

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec routes() :: [String.t()]
  def routes, do: @routes

  @spec backends() :: [String.t()]
  def backends, do: @backends

  @spec runtimes() :: [String.t()]
  def runtimes, do: @runtimes

  @spec max_models() :: pos_integer()
  def max_models, do: @max_models

  @spec max_model_id_bytes() :: pos_integer()
  def max_model_id_bytes, do: @max_model_id_bytes

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, tuple()}
  def new(attrs) do
    with {:ok, attrs} <- Support.normalize_object(attrs, @fields, :invalid_provider_model_catalog),
         {:ok, version} <- version(Map.get(attrs, :version, @schema_version)),
         {:ok, route} <- Support.normalize_enum(Map.get(attrs, :route), @routes, :route),
         {:ok, backend} <- Support.normalize_enum(Map.get(attrs, :backend), @backends, :backend),
         {:ok, runtime} <- Support.normalize_enum(Map.get(attrs, :runtime), @runtimes, :runtime),
         {:ok, model_ids} <- model_ids(Map.get(attrs, :model_ids)),
         {:ok, observed_at, observed_datetime} <-
           Support.required_timestamp(Map.get(attrs, :observed_at), :observed_at),
         {:ok, expires_at, expires_datetime} <-
           Support.required_timestamp(Map.get(attrs, :expires_at), :expires_at),
         :ok <- Support.validate_expiry(observed_datetime, expires_datetime),
         {:ok, credential_generation} <-
           credential_generation(Map.get(attrs, :credential_generation)),
         :ok <- validate_triple(route, backend, runtime) do
      catalog = %__MODULE__{
        version: version,
        route: route,
        backend: backend,
        runtime: runtime,
        model_ids: model_ids,
        observed_at: observed_at,
        expires_at: expires_at,
        credential_generation: credential_generation
      }

      case Support.canonical_bytes(
             to_map(catalog),
             @fields,
             :invalid_provider_model_catalog,
             @max_bytes
           ) do
        {:ok, _bytes} -> {:ok, catalog}
        {:error, _reason} = error -> error
      end
    end
  rescue
    _ -> {:error, {:invalid_provider_model_catalog, :malformed}}
  catch
    _, _ -> {:error, {:invalid_provider_model_catalog, :malformed}}
  end

  @spec to_map(t()) :: map() | {:error, tuple()}
  def to_map(%__MODULE__{} = catalog) do
    %{
      "version" => catalog.version,
      "route" => catalog.route,
      "backend" => catalog.backend,
      "runtime" => catalog.runtime,
      "model_ids" => catalog.model_ids,
      "observed_at" => catalog.observed_at,
      "expires_at" => catalog.expires_at,
      "credential_generation" => catalog.credential_generation
    }
  end

  def to_map(_value), do: {:error, {:invalid_provider_model_catalog, :struct_required}}

  @spec normalize(map() | keyword()) :: {:ok, map()} | {:error, tuple()}
  def normalize(attrs) do
    with {:ok, catalog} <- new(attrs), do: {:ok, to_map(catalog)}
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = catalog), do: match?({:ok, _}, new(to_map(catalog)))
  def valid?(attrs) when is_map(attrs) or is_list(attrs), do: match?({:ok, _}, new(attrs))
  def valid?(_attrs), do: false

  @spec canonical_bytes(t() | map() | keyword()) :: {:ok, binary()} | {:error, tuple()}
  def canonical_bytes(%__MODULE__{} = catalog) do
    with {:ok, catalog} <- new(to_map(catalog)) do
      Support.canonical_bytes(
        to_map(catalog),
        @fields,
        :invalid_provider_model_catalog,
        @max_bytes
      )
    end
  end

  def canonical_bytes(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, catalog} <- new(attrs), do: canonical_bytes(catalog)
  end

  def canonical_bytes(_value), do: {:error, {:invalid_provider_model_catalog, :object_required}}

  defp version(@schema_version), do: {:ok, @schema_version}
  defp version(_version), do: {:error, {:invalid_field, "version"}}

  defp validate_triple(route, backend, runtime) do
    if Map.has_key?(@route_backend_runtimes, {route, backend, runtime}) do
      :ok
    else
      {:error, {:invalid_provider_model_catalog, :route_backend_runtime_mismatch}}
    end
  end

  defp credential_generation(value)
       when is_integer(value) and value >= 0 and value <= @max_generation,
       do: {:ok, value}

  defp credential_generation(_value), do: {:error, {:invalid_field, "credential_generation"}}

  defp model_ids(ids) when is_list(ids) do
    normalize_model_ids(ids, [], MapSet.new(), 0)
  end

  defp model_ids(_ids), do: {:error, {:invalid_field, "model_ids"}}

  defp normalize_model_ids([], acc, _seen, _count), do: {:ok, Enum.reverse(acc)}

  defp normalize_model_ids(_rest, _acc, _seen, count) when count >= @max_models,
    do: {:error, {:invalid_provider_model_catalog, :catalog_too_large}}

  defp normalize_model_ids([id | rest], acc, seen, count) do
    with {:ok, model_id} <- Support.normalize_identifier(id, :model_ids, @max_model_id_bytes) do
      if MapSet.member?(seen, model_id) do
        {:error, {:invalid_provider_model_catalog, :duplicate_model_id}}
      else
        normalize_model_ids(rest, [model_id | acc], MapSet.put(seen, model_id), count + 1)
      end
    end
  end

  defp normalize_model_ids(_improper, _acc, _seen, _count),
    do: {:error, {:invalid_provider_model_catalog, :improper_list}}
end
