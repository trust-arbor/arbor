defmodule Arbor.Contracts.LLM.ProviderObservation do
  @moduledoc """
  Versioned, closed evidence about one provider/model/runtime route.

  Names such as provider, account, source, and model identifiers are bounded
  data rather than a provider registry. Subscription capacity is represented
  independently from monetary API spend, which is intentionally absent here.
  """

  use TypedStruct

  alias Arbor.Contracts.LLM.ControlPlaneSupport, as: Support

  @schema_version 1
  @availability ["available", "degraded", "unavailable", "unknown"]
  @auth_health ["healthy", "expired", "invalid", "unavailable", "unknown"]
  @catalog_membership ["present", "absent", "unknown"]
  @quota_states ["available", "exhausted", "unknown"]
  @subscription_states ["available", "limited", "exhausted", "unknown", "not_applicable"]
  @runtimes ["arbor", "acp", "local", "unknown"]
  @failure_codes [
    "auth_required",
    "auth_expired",
    "account_exhausted",
    "quota_exhausted",
    "transport_error",
    "protocol_error",
    "model_absent",
    "model_mismatch",
    "concurrency_limited",
    "unknown"
  ]

  @fields [
    :version,
    :provider,
    :account_id,
    :source,
    :runtime,
    :observed_at,
    :expires_at,
    :availability,
    :auth_health,
    :model_catalog_membership,
    :quota_state,
    :quota_resets_at,
    :subscription_capacity_state,
    :subscription_capacity_resets_at,
    :concurrency_limit,
    :concurrency_in_use,
    :requested_model_id,
    :launch_bound_model_id,
    :confirmed_model_id,
    :failure_code,
    :failure_message
  ]
  @max_bytes 32_768
  typedstruct enforce: true do
    field(:version, pos_integer(), default: @schema_version)
    field(:provider, String.t())
    field(:account_id, String.t() | nil, default: nil)
    field(:source, String.t())
    field(:runtime, String.t() | nil, default: nil)
    field(:observed_at, String.t())
    field(:expires_at, String.t() | nil, default: nil)
    field(:availability, String.t() | nil, default: nil)
    field(:auth_health, String.t() | nil, default: nil)
    field(:model_catalog_membership, String.t() | nil, default: nil)
    field(:quota_state, String.t() | nil, default: nil)
    field(:quota_resets_at, String.t() | nil, default: nil)
    field(:subscription_capacity_state, String.t() | nil, default: nil)
    field(:subscription_capacity_resets_at, String.t() | nil, default: nil)
    field(:concurrency_limit, non_neg_integer() | nil, default: nil)
    field(:concurrency_in_use, non_neg_integer() | nil, default: nil)
    field(:requested_model_id, String.t() | nil, default: nil)
    field(:launch_bound_model_id, String.t() | nil, default: nil)
    field(:confirmed_model_id, String.t() | nil, default: nil)
    field(:failure_code, String.t() | nil, default: nil)
    field(:failure_message, String.t() | nil, default: nil)
  end

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec enums() :: map()
  def enums do
    %{
      "availability" => @availability,
      "auth_health" => @auth_health,
      "model_catalog_membership" => @catalog_membership,
      "quota_state" => @quota_states,
      "subscription_capacity_state" => @subscription_states,
      "runtime" => @runtimes,
      "failure_code" => @failure_codes
    }
  end

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, tuple()}
  def new(attrs) do
    with {:ok, attrs} <- Support.normalize_object(attrs, @fields, :invalid_provider_observation),
         {:ok, version} <- version(Map.get(attrs, :version, @schema_version)),
         {:ok, provider} <- Support.normalize_identifier(Map.get(attrs, :provider), :provider),
         {:ok, account_id} <- optional_identifier(attrs, :account_id),
         {:ok, source} <- Support.normalize_identifier(Map.get(attrs, :source), :source),
         {:ok, runtime} <- Support.optional_enum(attrs, :runtime, @runtimes),
         {:ok, observed_at, observed_datetime} <-
           Support.required_timestamp(Map.get(attrs, :observed_at), :observed_at),
         {:ok, expires_at, expires_datetime} <- Support.optional_timestamp(attrs, :expires_at),
         :ok <- Support.validate_expiry(observed_datetime, expires_datetime),
         {:ok, availability} <- Support.optional_enum(attrs, :availability, @availability),
         {:ok, auth_health} <- Support.optional_enum(attrs, :auth_health, @auth_health),
         {:ok, catalog_membership} <-
           Support.optional_enum(attrs, :model_catalog_membership, @catalog_membership),
         {:ok, quota_state} <- Support.optional_enum(attrs, :quota_state, @quota_states),
         {:ok, quota_resets_at, _quota_datetime} <-
           Support.optional_timestamp(attrs, :quota_resets_at),
         {:ok, subscription_state} <-
           Support.optional_enum(attrs, :subscription_capacity_state, @subscription_states),
         {:ok, subscription_resets_at, _subscription_datetime} <-
           Support.optional_timestamp(attrs, :subscription_capacity_resets_at),
         {:ok, concurrency_limit} <-
           Support.optional_nonnegative_integer(attrs, :concurrency_limit),
         {:ok, concurrency_in_use} <-
           Support.optional_nonnegative_integer(attrs, :concurrency_in_use),
         {:ok, requested_model_id} <- optional_identifier(attrs, :requested_model_id),
         {:ok, launch_bound_model_id} <- optional_identifier(attrs, :launch_bound_model_id),
         {:ok, confirmed_model_id} <- optional_identifier(attrs, :confirmed_model_id),
         {:ok, failure_code} <- Support.optional_enum(attrs, :failure_code, @failure_codes),
         {:ok, failure_message} <- optional_failure_message(attrs, failure_code) do
      {:ok,
       %__MODULE__{
         version: version,
         provider: provider,
         account_id: account_id,
         source: source,
         runtime: runtime,
         observed_at: observed_at,
         expires_at: expires_at,
         availability: availability,
         auth_health: auth_health,
         model_catalog_membership: catalog_membership,
         quota_state: quota_state,
         quota_resets_at: quota_resets_at,
         subscription_capacity_state: subscription_state,
         subscription_capacity_resets_at: subscription_resets_at,
         concurrency_limit: concurrency_limit,
         concurrency_in_use: concurrency_in_use,
         requested_model_id: requested_model_id,
         launch_bound_model_id: launch_bound_model_id,
         confirmed_model_id: confirmed_model_id,
         failure_code: failure_code,
         failure_message: failure_message
       }}
    end
  rescue
    _ -> {:error, {:invalid_provider_observation, :malformed}}
  catch
    _, _ -> {:error, {:invalid_provider_observation, :malformed}}
  end

  @spec to_map(t()) :: map() | {:error, tuple()}
  def to_map(%__MODULE__{} = observation) do
    %{
      "version" => observation.version,
      "provider" => observation.provider,
      "source" => observation.source,
      "observed_at" => observation.observed_at
    }
    |> Support.put_optional("account_id", observation.account_id)
    |> Support.put_optional("runtime", observation.runtime)
    |> Support.put_optional("expires_at", observation.expires_at)
    |> Support.put_optional("availability", observation.availability)
    |> Support.put_optional("auth_health", observation.auth_health)
    |> Support.put_optional("model_catalog_membership", observation.model_catalog_membership)
    |> Support.put_optional("quota_state", observation.quota_state)
    |> Support.put_optional("quota_resets_at", observation.quota_resets_at)
    |> Support.put_optional(
      "subscription_capacity_state",
      observation.subscription_capacity_state
    )
    |> Support.put_optional(
      "subscription_capacity_resets_at",
      observation.subscription_capacity_resets_at
    )
    |> Support.put_optional("concurrency_limit", observation.concurrency_limit)
    |> Support.put_optional("concurrency_in_use", observation.concurrency_in_use)
    |> Support.put_optional("requested_model_id", observation.requested_model_id)
    |> Support.put_optional("launch_bound_model_id", observation.launch_bound_model_id)
    |> Support.put_optional("confirmed_model_id", observation.confirmed_model_id)
    |> Support.put_optional("failure_code", observation.failure_code)
    |> Support.put_optional("failure_message", observation.failure_message)
  end

  def to_map(_value), do: {:error, {:invalid_provider_observation, :struct_required}}

  @spec normalize(map() | keyword()) :: {:ok, map()} | {:error, tuple()}
  def normalize(attrs) do
    with {:ok, observation} <- new(attrs), do: {:ok, to_map(observation)}
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = observation), do: match?({:ok, _}, new(to_map(observation)))
  def valid?(attrs) when is_map(attrs) or is_list(attrs), do: match?({:ok, _}, new(attrs))
  def valid?(_attrs), do: false

  @spec canonical_bytes(t() | map() | keyword()) :: {:ok, binary()} | {:error, tuple()}
  def canonical_bytes(%__MODULE__{} = observation) do
    with {:ok, normalized} <- new(to_map(observation)),
         {:ok, bytes} <-
           Support.canonical_bytes(
             to_map(normalized),
             @fields,
             :invalid_provider_observation,
             @max_bytes
           ) do
      {:ok, bytes}
    end
  end

  def canonical_bytes(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, observation} <- new(attrs), do: canonical_bytes(observation)
  end

  def canonical_bytes(_value), do: {:error, {:invalid_provider_observation, :object_required}}

  @spec digest(t() | map() | keyword()) :: {:ok, String.t()} | {:error, tuple()}
  def digest(value) do
    with {:ok, bytes} <- canonical_bytes(value),
         do: Support.digest(bytes, :invalid_provider_observation)
  rescue
    _ -> {:error, {:invalid_provider_observation, :malformed}}
  catch
    _, _ -> {:error, {:invalid_provider_observation, :malformed}}
  end

  defp version(@schema_version), do: {:ok, @schema_version}
  defp version(_version), do: {:error, {:invalid_field, "version"}}

  defp optional_identifier(attrs, field) do
    case Map.get(attrs, field) do
      nil -> {:ok, nil}
      value -> Support.normalize_identifier(value, field)
    end
  end

  defp optional_failure_message(attrs, nil) do
    case Map.get(attrs, :failure_message) do
      nil -> {:ok, nil}
      _ -> {:error, {:invalid_field, "failure_message"}}
    end
  end

  defp optional_failure_message(attrs, _failure_code) do
    case Map.get(attrs, :failure_message) do
      nil -> {:error, {:invalid_field, "failure_message"}}
      message -> Support.normalize_text(message, :failure_message)
    end
  end
end
