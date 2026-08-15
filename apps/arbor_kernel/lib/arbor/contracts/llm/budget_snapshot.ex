defmodule Arbor.Contracts.LLM.BudgetSnapshot do
  @moduledoc """
  Versioned, closed budget and capacity evidence for a pure model router.

  Spend fields are marginal API spend in USD. Subscription fields are
  provider-specific allowance units and are deliberately separate: using a
  subscription is never encoded as zero monetary cost.

  A configured spend ceiling is evidence for remaining-budget projection, not
  a historical hard cap; recorded current spend may exceed it.
  """

  use TypedStruct

  alias Arbor.Contracts.LLM.ControlPlaneSupport, as: Support

  @schema_version 1
  @quota_states ["available", "exhausted", "unknown"]
  @subscription_states ["available", "limited", "exhausted", "unknown", "not_applicable"]
  @fields [
    :version,
    :provider,
    :account_id,
    :source,
    :observed_at,
    :expires_at,
    :configured_spend_ceiling,
    :current_spend,
    :remaining_spend,
    :request_count,
    :input_tokens,
    :output_tokens,
    :quota_state,
    :quota_remaining_units,
    :quota_resets_at,
    :subscription_capacity_state,
    :subscription_capacity_limit,
    :subscription_capacity_used,
    :subscription_capacity_remaining,
    :subscription_capacity_resets_at,
    :concurrency_limit,
    :concurrency_in_use
  ]
  @max_bytes 32_768
  @consistency_tolerance 0.000001

  typedstruct enforce: true do
    field(:version, pos_integer(), default: @schema_version)
    field(:provider, String.t())
    field(:account_id, String.t() | nil, default: nil)
    field(:source, String.t())
    field(:observed_at, String.t())
    field(:expires_at, String.t() | nil, default: nil)
    field(:configured_spend_ceiling, number() | nil, default: nil)
    field(:current_spend, number() | nil, default: nil)
    field(:remaining_spend, number() | nil, default: nil)
    field(:request_count, non_neg_integer() | nil, default: nil)
    field(:input_tokens, non_neg_integer() | nil, default: nil)
    field(:output_tokens, non_neg_integer() | nil, default: nil)
    field(:quota_state, String.t() | nil, default: nil)
    field(:quota_remaining_units, number() | nil, default: nil)
    field(:quota_resets_at, String.t() | nil, default: nil)
    field(:subscription_capacity_state, String.t() | nil, default: nil)
    field(:subscription_capacity_limit, number() | nil, default: nil)
    field(:subscription_capacity_used, number() | nil, default: nil)
    field(:subscription_capacity_remaining, number() | nil, default: nil)
    field(:subscription_capacity_resets_at, String.t() | nil, default: nil)
    field(:concurrency_limit, non_neg_integer() | nil, default: nil)
    field(:concurrency_in_use, non_neg_integer() | nil, default: nil)
  end

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec consistency_tolerance() :: float()
  def consistency_tolerance, do: @consistency_tolerance

  @spec enums() :: map()
  def enums do
    %{
      "quota_state" => @quota_states,
      "subscription_capacity_state" => @subscription_states
    }
  end

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, tuple()}
  def new(attrs) do
    with {:ok, attrs} <- Support.normalize_object(attrs, @fields, :invalid_budget_snapshot),
         {:ok, version} <- version(Map.get(attrs, :version, @schema_version)),
         {:ok, provider} <- Support.normalize_identifier(Map.get(attrs, :provider), :provider),
         {:ok, account_id} <- optional_identifier(attrs, :account_id),
         {:ok, source} <- Support.normalize_identifier(Map.get(attrs, :source), :source),
         {:ok, observed_at, observed_datetime} <-
           Support.required_timestamp(Map.get(attrs, :observed_at), :observed_at),
         {:ok, expires_at, expires_datetime} <- Support.optional_timestamp(attrs, :expires_at),
         :ok <- Support.validate_expiry(observed_datetime, expires_datetime),
         {:ok, configured_spend_ceiling} <-
           Support.optional_nonnegative_number(attrs, :configured_spend_ceiling),
         {:ok, current_spend} <- Support.optional_nonnegative_number(attrs, :current_spend),
         {:ok, remaining_spend} <- Support.optional_nonnegative_number(attrs, :remaining_spend),
         :ok <- validate_spend(configured_spend_ceiling, current_spend, remaining_spend),
         {:ok, request_count} <- Support.optional_nonnegative_integer(attrs, :request_count),
         {:ok, input_tokens} <- Support.optional_nonnegative_integer(attrs, :input_tokens),
         {:ok, output_tokens} <- Support.optional_nonnegative_integer(attrs, :output_tokens),
         {:ok, quota_state} <- Support.optional_enum(attrs, :quota_state, @quota_states),
         {:ok, quota_remaining_units} <-
           Support.optional_nonnegative_number(attrs, :quota_remaining_units),
         {:ok, quota_resets_at, _quota_datetime} <-
           Support.optional_timestamp(attrs, :quota_resets_at),
         {:ok, subscription_state} <-
           Support.optional_enum(attrs, :subscription_capacity_state, @subscription_states),
         {:ok, subscription_limit} <-
           Support.optional_nonnegative_number(attrs, :subscription_capacity_limit),
         {:ok, subscription_used} <-
           Support.optional_nonnegative_number(attrs, :subscription_capacity_used),
         {:ok, subscription_remaining} <-
           Support.optional_nonnegative_number(attrs, :subscription_capacity_remaining),
         {:ok, subscription_resets_at, _subscription_datetime} <-
           Support.optional_timestamp(attrs, :subscription_capacity_resets_at),
         {:ok, concurrency_limit} <-
           Support.optional_nonnegative_integer(attrs, :concurrency_limit),
         {:ok, concurrency_in_use} <-
           Support.optional_nonnegative_integer(attrs, :concurrency_in_use) do
      {:ok,
       %__MODULE__{
         version: version,
         provider: provider,
         account_id: account_id,
         source: source,
         observed_at: observed_at,
         expires_at: expires_at,
         configured_spend_ceiling: configured_spend_ceiling,
         current_spend: current_spend,
         remaining_spend: remaining_spend,
         request_count: request_count,
         input_tokens: input_tokens,
         output_tokens: output_tokens,
         quota_state: quota_state,
         quota_remaining_units: quota_remaining_units,
         quota_resets_at: quota_resets_at,
         subscription_capacity_state: subscription_state,
         subscription_capacity_limit: subscription_limit,
         subscription_capacity_used: subscription_used,
         subscription_capacity_remaining: subscription_remaining,
         subscription_capacity_resets_at: subscription_resets_at,
         concurrency_limit: concurrency_limit,
         concurrency_in_use: concurrency_in_use
       }}
    end
  rescue
    _ -> {:error, {:invalid_budget_snapshot, :malformed}}
  catch
    _, _ -> {:error, {:invalid_budget_snapshot, :malformed}}
  end

  @spec to_map(t()) :: map() | {:error, tuple()}
  def to_map(%__MODULE__{} = snapshot) do
    %{
      "version" => snapshot.version,
      "provider" => snapshot.provider,
      "source" => snapshot.source,
      "observed_at" => snapshot.observed_at
    }
    |> Support.put_optional("account_id", snapshot.account_id)
    |> Support.put_optional("expires_at", snapshot.expires_at)
    |> Support.put_optional("configured_spend_ceiling", snapshot.configured_spend_ceiling)
    |> Support.put_optional("current_spend", snapshot.current_spend)
    |> Support.put_optional("remaining_spend", snapshot.remaining_spend)
    |> Support.put_optional("request_count", snapshot.request_count)
    |> Support.put_optional("input_tokens", snapshot.input_tokens)
    |> Support.put_optional("output_tokens", snapshot.output_tokens)
    |> Support.put_optional("quota_state", snapshot.quota_state)
    |> Support.put_optional("quota_remaining_units", snapshot.quota_remaining_units)
    |> Support.put_optional("quota_resets_at", snapshot.quota_resets_at)
    |> Support.put_optional("subscription_capacity_state", snapshot.subscription_capacity_state)
    |> Support.put_optional("subscription_capacity_limit", snapshot.subscription_capacity_limit)
    |> Support.put_optional("subscription_capacity_used", snapshot.subscription_capacity_used)
    |> Support.put_optional(
      "subscription_capacity_remaining",
      snapshot.subscription_capacity_remaining
    )
    |> Support.put_optional(
      "subscription_capacity_resets_at",
      snapshot.subscription_capacity_resets_at
    )
    |> Support.put_optional("concurrency_limit", snapshot.concurrency_limit)
    |> Support.put_optional("concurrency_in_use", snapshot.concurrency_in_use)
  end

  def to_map(_value), do: {:error, {:invalid_budget_snapshot, :struct_required}}

  @spec normalize(map() | keyword()) :: {:ok, map()} | {:error, tuple()}
  def normalize(attrs) do
    with {:ok, snapshot} <- new(attrs), do: {:ok, to_map(snapshot)}
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = snapshot), do: match?({:ok, _}, new(to_map(snapshot)))
  def valid?(attrs) when is_map(attrs) or is_list(attrs), do: match?({:ok, _}, new(attrs))
  def valid?(_attrs), do: false

  @spec canonical_bytes(t() | map() | keyword()) :: {:ok, binary()} | {:error, tuple()}
  def canonical_bytes(%__MODULE__{} = snapshot) do
    with {:ok, normalized} <- new(to_map(snapshot)),
         {:ok, bytes} <-
           Support.canonical_bytes(
             to_map(normalized),
             @fields,
             :invalid_budget_snapshot,
             @max_bytes
           ) do
      {:ok, bytes}
    end
  end

  def canonical_bytes(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, snapshot} <- new(attrs), do: canonical_bytes(snapshot)
  end

  def canonical_bytes(_value), do: {:error, {:invalid_budget_snapshot, :object_required}}

  @spec digest(t() | map() | keyword()) :: {:ok, String.t()} | {:error, tuple()}
  def digest(value) do
    with {:ok, bytes} <- canonical_bytes(value),
         do: Support.digest(bytes, :invalid_budget_snapshot)
  rescue
    _ -> {:error, {:invalid_budget_snapshot, :malformed}}
  catch
    _, _ -> {:error, {:invalid_budget_snapshot, :malformed}}
  end

  defp version(@schema_version), do: {:ok, @schema_version}
  defp version(_version), do: {:error, {:invalid_field, "version"}}

  defp optional_identifier(attrs, field) do
    case Map.get(attrs, field) do
      nil -> {:ok, nil}
      value -> Support.normalize_identifier(value, field)
    end
  end

  defp validate_spend(nil, _current, _remaining), do: :ok

  defp validate_spend(ceiling, current, remaining) do
    cond do
      remaining != nil and remaining > ceiling ->
        {:error, {:invalid_field, "remaining_spend"}}

      current != nil and remaining != nil and
          abs(remaining - max(0, ceiling - current)) > @consistency_tolerance ->
        {:error, {:invalid_field, "remaining_spend"}}

      true ->
        :ok
    end
  end
end
