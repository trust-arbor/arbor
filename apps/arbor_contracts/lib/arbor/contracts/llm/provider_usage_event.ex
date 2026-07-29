defmodule Arbor.Contracts.LLM.ProviderUsageEvent do
  @moduledoc """
  Versioned, closed immutable usage fact for the durable provider ledger.

  One event records a single observed provider operation: stable event
  identity, attribution (provider/account/source/runtime/model_id), operation
  and occurrence time, optional principal/task/goal/correlation scope, token
  counts, and two independently tracked cost dimensions:

  - `marginal_api_cost_usd` — monetary API spend attributable to this event
  - `subscription_usage_units` — provider-specific subscription allowance units

  Using a subscription is never encoded as zero monetary cost. Capacity /
  readiness evidence remains `ProviderObservation`; this contract does not
  restate capacity.

  Closed operations include ReqLLM complete/embed paths and ACP prompt turns
  (`acp_prompt`) so both runtimes can record ledger input without inventing
  free-form operation strings.
  """

  use TypedStruct

  alias Arbor.Contracts.LLM.ControlPlaneSupport, as: Support

  @schema_version 1
  @operations ["complete", "embed_cloud", "embed_local", "acp_prompt"]
  @runtimes ["arbor", "acp", "local", "unknown"]
  @fields [
    :version,
    :event_id,
    :provider,
    :account_id,
    :source,
    :runtime,
    :model_id,
    :operation,
    :occurred_at,
    :principal_id,
    :task_id,
    :goal_id,
    :correlation_id,
    :input_tokens,
    :output_tokens,
    :total_tokens,
    :cached_tokens,
    :marginal_api_cost_usd,
    :subscription_usage_units
  ]
  @max_bytes 32_768
  @max_token_count 1_000_000_000
  @max_event_id_bytes 64

  typedstruct enforce: true do
    field(:version, pos_integer(), default: @schema_version)
    field(:event_id, String.t())
    field(:provider, String.t())
    field(:account_id, String.t() | nil, default: nil)
    field(:source, String.t())
    field(:runtime, String.t() | nil, default: nil)
    field(:model_id, String.t())
    field(:operation, String.t())
    field(:occurred_at, String.t())
    field(:principal_id, String.t() | nil, default: nil)
    field(:task_id, String.t() | nil, default: nil)
    field(:goal_id, String.t() | nil, default: nil)
    field(:correlation_id, String.t() | nil, default: nil)
    field(:input_tokens, non_neg_integer())
    field(:output_tokens, non_neg_integer())
    field(:total_tokens, non_neg_integer())
    field(:cached_tokens, non_neg_integer())
    field(:marginal_api_cost_usd, number() | nil, default: nil)
    field(:subscription_usage_units, number() | nil, default: nil)
  end

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec enums() :: map()
  def enums do
    %{
      "operation" => @operations,
      "runtime" => @runtimes
    }
  end

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, tuple()}
  def new(attrs) do
    with {:ok, attrs} <- Support.normalize_object(attrs, @fields, :invalid_provider_usage_event),
         {:ok, version} <- version(Map.get(attrs, :version, @schema_version)),
         {:ok, event_id} <-
           Support.normalize_identifier(Map.get(attrs, :event_id), :event_id, @max_event_id_bytes),
         {:ok, provider} <- Support.normalize_identifier(Map.get(attrs, :provider), :provider),
         {:ok, account_id} <- optional_identifier(attrs, :account_id),
         {:ok, source} <- Support.normalize_identifier(Map.get(attrs, :source), :source),
         {:ok, runtime} <- Support.optional_enum(attrs, :runtime, @runtimes),
         {:ok, model_id} <- Support.normalize_identifier(Map.get(attrs, :model_id), :model_id),
         {:ok, operation} <-
           Support.normalize_enum(Map.get(attrs, :operation), @operations, :operation),
         {:ok, occurred_at, _occurred_datetime} <-
           Support.required_timestamp(Map.get(attrs, :occurred_at), :occurred_at),
         {:ok, principal_id} <- optional_identifier(attrs, :principal_id),
         {:ok, task_id} <- optional_identifier(attrs, :task_id),
         {:ok, goal_id} <- optional_identifier(attrs, :goal_id),
         {:ok, correlation_id} <- optional_identifier(attrs, :correlation_id),
         {:ok, input_tokens} <- required_nonnegative_integer(attrs, :input_tokens),
         {:ok, output_tokens} <- required_nonnegative_integer(attrs, :output_tokens),
         {:ok, total_tokens} <- required_nonnegative_integer(attrs, :total_tokens),
         {:ok, cached_tokens} <- required_nonnegative_integer(attrs, :cached_tokens),
         :ok <-
           validate_token_consistency(
             input_tokens,
             output_tokens,
             total_tokens,
             cached_tokens
           ),
         {:ok, marginal_api_cost_usd} <-
           Support.optional_nonnegative_number(attrs, :marginal_api_cost_usd),
         {:ok, subscription_usage_units} <-
           Support.optional_nonnegative_number(attrs, :subscription_usage_units) do
      {:ok,
       %__MODULE__{
         version: version,
         event_id: event_id,
         provider: provider,
         account_id: account_id,
         source: source,
         runtime: runtime,
         model_id: model_id,
         operation: operation,
         occurred_at: occurred_at,
         principal_id: principal_id,
         task_id: task_id,
         goal_id: goal_id,
         correlation_id: correlation_id,
         input_tokens: input_tokens,
         output_tokens: output_tokens,
         total_tokens: total_tokens,
         cached_tokens: cached_tokens,
         marginal_api_cost_usd: marginal_api_cost_usd,
         subscription_usage_units: subscription_usage_units
       }}
    end
  rescue
    _ -> {:error, {:invalid_provider_usage_event, :malformed}}
  catch
    _, _ -> {:error, {:invalid_provider_usage_event, :malformed}}
  end

  @spec to_map(t()) :: map() | {:error, tuple()}
  def to_map(%__MODULE__{} = event) do
    %{
      "version" => event.version,
      "event_id" => event.event_id,
      "provider" => event.provider,
      "source" => event.source,
      "model_id" => event.model_id,
      "operation" => event.operation,
      "occurred_at" => event.occurred_at,
      "input_tokens" => event.input_tokens,
      "output_tokens" => event.output_tokens,
      "total_tokens" => event.total_tokens,
      "cached_tokens" => event.cached_tokens
    }
    |> Support.put_optional("account_id", event.account_id)
    |> Support.put_optional("runtime", event.runtime)
    |> Support.put_optional("principal_id", event.principal_id)
    |> Support.put_optional("task_id", event.task_id)
    |> Support.put_optional("goal_id", event.goal_id)
    |> Support.put_optional("correlation_id", event.correlation_id)
    |> Support.put_optional("marginal_api_cost_usd", event.marginal_api_cost_usd)
    |> Support.put_optional("subscription_usage_units", event.subscription_usage_units)
  end

  def to_map(_value), do: {:error, {:invalid_provider_usage_event, :struct_required}}

  @spec normalize(map() | keyword()) :: {:ok, map()} | {:error, tuple()}
  def normalize(attrs) do
    with {:ok, event} <- new(attrs), do: {:ok, to_map(event)}
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = event), do: match?({:ok, _}, new(to_map(event)))
  def valid?(attrs) when is_map(attrs) or is_list(attrs), do: match?({:ok, _}, new(attrs))
  def valid?(_attrs), do: false

  @spec canonical_bytes(t() | map() | keyword()) :: {:ok, binary()} | {:error, tuple()}
  def canonical_bytes(%__MODULE__{} = event) do
    with {:ok, normalized} <- new(to_map(event)),
         {:ok, bytes} <-
           Support.canonical_bytes(
             to_map(normalized),
             @fields,
             :invalid_provider_usage_event,
             @max_bytes
           ) do
      {:ok, bytes}
    end
  end

  def canonical_bytes(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, event} <- new(attrs), do: canonical_bytes(event)
  end

  def canonical_bytes(_value), do: {:error, {:invalid_provider_usage_event, :object_required}}

  @spec digest(t() | map() | keyword()) :: {:ok, String.t()} | {:error, tuple()}
  def digest(value) do
    with {:ok, bytes} <- canonical_bytes(value),
         do: Support.digest(bytes, :invalid_provider_usage_event)
  rescue
    _ -> {:error, {:invalid_provider_usage_event, :malformed}}
  catch
    _, _ -> {:error, {:invalid_provider_usage_event, :malformed}}
  end

  defp version(@schema_version), do: {:ok, @schema_version}
  defp version(_version), do: {:error, {:invalid_field, "version"}}

  defp optional_identifier(attrs, field) do
    case Map.get(attrs, field) do
      nil -> {:ok, nil}
      value -> Support.normalize_identifier(value, field)
    end
  end

  defp required_nonnegative_integer(attrs, field) do
    case Map.get(attrs, field) do
      value when is_integer(value) and value >= 0 and value <= @max_token_count ->
        {:ok, value}

      _ ->
        {:error, {:invalid_field, Atom.to_string(field)}}
    end
  end

  defp validate_token_consistency(input_tokens, output_tokens, total_tokens, cached_tokens) do
    cond do
      cached_tokens > input_tokens ->
        {:error, {:invalid_field, "cached_tokens"}}

      total_tokens < input_tokens + output_tokens ->
        {:error, {:invalid_field, "total_tokens"}}

      true ->
        :ok
    end
  end
end
