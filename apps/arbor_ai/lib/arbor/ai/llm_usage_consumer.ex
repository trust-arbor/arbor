defmodule Arbor.AI.LLMUsageConsumer do
  @moduledoc """
  Supervised owner for `[:arbor, :llm, :usage]` telemetry.

  The telemetry callback validates only, then casts the canonical event map to
  this GenServer. Serialized durable admission through
  `Arbor.AI.record_provider_usage/2` and the subsequent BudgetTracker
  compatibility projection both run in the GenServer mailbox so a slow ledger
  cannot delay the originating model response.

  Ledger target and telemetry handler identity are **immutable init state**.
  Init either accepts an explicit normalized `:ledger_target` override or
  snapshots `Config.provider_usage_ledger_target/0` once. Admission never
  rereads Application config. Invalid explicit overrides fail start; absent
  global config keeps the process alive with a fixed closed error.

  Projection applies only after durable admission returns `{:ok, _}` and only
  for known provider atoms. Exact event-id replay is ledger success; receipts
  do not distinguish insert vs replay, so projection relies on BudgetTracker's
  in-process `event_id` cache. A full tracker restart can re-project an
  already-ledgered id (ledger remains exact-once) — accepted limitation.

  Malformed input, non-authoritative diagnostics, ledger failures, disabled
  trackers, and tracker failures never affect the originating LLM call.
  Unknown providers are still durably stored; only known providers project.
  """

  use GenServer

  require Logger

  alias Arbor.AI
  alias Arbor.AI.BudgetTracker
  alias Arbor.AI.Config
  alias Arbor.Contracts.LLM.ProviderUsageEvent

  @event [:arbor, :llm, :usage]
  @max_token_count 1_000_000_000
  @max_cost_usd 1_000_000.0
  @max_string_bytes 128
  @operations [:complete, :embed_cloud, :embed_local]
  # Closed ledger-failure reason atoms only — never log raw backend terms.
  @ledger_failure_reasons MapSet.new([
                            :provider_usage_ledger_target_unset,
                            :invalid_provider_usage_ledger_target,
                            :event_identity_conflict,
                            :append_indeterminate,
                            :backend_unavailable,
                            :invalid_options,
                            :exception,
                            :unavailable
                          ])
  @providers %{
    "amazon_bedrock" => :amazon_bedrock,
    "anthropic" => :anthropic,
    "azure" => :azure,
    "cerebras" => :cerebras,
    "gemini" => :gemini,
    "google" => :gemini,
    "google_vertex" => :google_vertex,
    "grok" => :grok,
    "groq" => :groq,
    "lm_studio" => :lmstudio,
    "meta" => :meta,
    "openrouter" => :openrouter,
    "ollama" => :ollama,
    "openai" => :openai,
    "opencode" => :opencode,
    "qwen" => :qwen,
    "venice" => :venice,
    "vllm" => :vllm,
    "xai" => :xai,
    "zai" => :zai,
    "zai_coder" => :zai_coder,
    "zai_coding_plan" => :zai_coding_plan,
    "zenmux" => :zenmux
  }

  @doc """
  Start the consumer.

  Options:
  - `:name` — GenServer name (default `__MODULE__`). Telemetry handler id is
    `__MODULE__` for the production singleton (`name == __MODULE__`) so hot
    reload does not strand the legacy bare-module handler; explicitly named
    instances use `{__MODULE__, name}`.
  - `:ledger_target` — explicit closed target. When present, must normalize
    successfully or start fails. When absent, snapshots Config once.
  """
  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    handler_id = telemetry_handler_id(name)

    case resolve_ledger(opts) do
      {:ok, ledger} ->
        state = %{name: name, handler_id: handler_id, ledger: ledger}
        # Detach only this instance's stable id (legacy singleton or named).
        attach_handler(handler_id, self())
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  def init(_opts), do: init([])

  @impl true
  def handle_cast({:admit_usage, event_map}, state) when is_map(event_map) do
    _ = admit_and_project(event_map, state)
    {:noreply, state}
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = safe_detach(Map.get(state, :handler_id))
    :ok
  end

  @doc false
  # Telemetry callback: validate only, then cast to the owning GenServer.
  # Never reads Config, admits to the ledger, or projects BudgetTracker here.
  def handle_event(@event, measurements, metadata, %{owner: owner}) do
    case validate_event(measurements, metadata) do
      {:ok, event_map} ->
        GenServer.cast(owner, {:admit_usage, event_map})

      {:error, reason} ->
        observe_failure(reason, metadata)

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def handle_event(@event, _measurements, _metadata, _config), do: :ok

  defp resolve_ledger(opts) do
    if Keyword.has_key?(opts, :ledger_target) do
      case Config.normalize_provider_usage_ledger_target(Keyword.get(opts, :ledger_target)) do
        {:ok, target} -> {:ok, {:target, target}}
        {:error, reason} -> {:error, reason}
      end
    else
      case Config.provider_usage_ledger_target() do
        {:ok, target} -> {:ok, {:target, target}}
        {:error, reason} -> {:ok, {:error, classify_ledger_reason(reason)}}
      end
    end
  end

  # Production singleton keeps the legacy bare-module handler id so a hot
  # reload/restart does not leave LLMUsageConsumer stranded beside
  # {LLMUsageConsumer, LLMUsageConsumer}. Named test/isolated instances use
  # the tuple form for uniqueness.
  defp telemetry_handler_id(name) when name == __MODULE__, do: __MODULE__
  defp telemetry_handler_id(name), do: {__MODULE__, name}

  defp attach_handler(handler_id, owner) when is_pid(owner) do
    _ = safe_detach(handler_id)
    :ok = :telemetry.attach(handler_id, @event, &__MODULE__.handle_event/4, %{owner: owner})
  end

  defp safe_detach(nil), do: :ok

  defp safe_detach(handler_id) do
    :telemetry.detach(handler_id)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp admit_and_project(event_map, state) do
    case admit_durable(event_map, state) do
      {:ok, _receipt} ->
        case provider_atom(event_map["provider"]) do
          {:ok, provider} -> project_budget(provider, event_map)
          :error -> :ok
        end

      {:error, reason} ->
        observe_failure(reason, %{
          event_id: Map.get(event_map, "event_id"),
          provider: Map.get(event_map, "provider"),
          operation: operation_atom(Map.get(event_map, "operation"))
        })

        :ok
    end
  end

  defp validate_event(measurements, metadata)
       when is_map(measurements) and is_map(metadata) do
    with :ok <-
           exact_keys(measurements, [:count, :input, :output, :total, :cached, :marginal_cost_usd]),
         :ok <-
           exact_keys(metadata, [
             :event_id,
             :source,
             :operation,
             :provider,
             :model,
             :usage_status,
             :event
           ]),
         :ok <- validate_metadata(metadata),
         :ok <- validate_measurements(measurements),
         {:ok, event} <- ProviderUsageEvent.new(Map.fetch!(metadata, :event)),
         event_map when is_map(event_map) <- ProviderUsageEvent.to_map(event),
         :ok <- consistent_event?(event_map, measurements, metadata) do
      {:ok, event_map}
    else
      _ -> {:error, :malformed}
    end
  end

  defp validate_event(_measurements, _metadata), do: {:error, :malformed}

  defp validate_metadata(metadata) do
    with true <- metadata.source == :req_llm,
         true <- metadata.operation in @operations,
         :ok <- bounded_string(metadata.event_id, 64),
         :ok <- bounded_string(metadata.provider),
         :ok <- bounded_string(metadata.model),
         true <- metadata.usage_status == :authoritative,
         true <- is_map(Map.get(metadata, :event)) do
      :ok
    else
      _ -> {:error, :malformed}
    end
  end

  defp validate_measurements(measurements) do
    with true <- measurements.count == 1,
         :ok <- token(measurements.input),
         :ok <- token(measurements.output),
         :ok <- token(measurements.total),
         :ok <- token(measurements.cached),
         true <- measurements.total >= measurements.input + measurements.output,
         true <- measurements.cached <= measurements.input,
         :ok <- optional_cost(Map.get(measurements, :marginal_cost_usd)) do
      :ok
    else
      _ -> {:error, :malformed}
    end
  end

  defp consistent_event?(event_map, measurements, metadata) do
    with true <- event_map["event_id"] == metadata.event_id,
         true <- event_map["provider"] == metadata.provider,
         true <- event_map["model_id"] == metadata.model,
         true <- event_map["source"] == "req_llm",
         true <- event_map["runtime"] == "arbor",
         true <- event_map["operation"] == Atom.to_string(metadata.operation),
         true <- event_map["input_tokens"] == measurements.input,
         true <- event_map["output_tokens"] == measurements.output,
         true <- event_map["total_tokens"] == measurements.total,
         true <- event_map["cached_tokens"] == measurements.cached,
         :ok <- consistent_marginal_cost?(event_map, measurements) do
      :ok
    else
      _ -> {:error, :malformed}
    end
  end

  defp consistent_marginal_cost?(event_map, measurements) do
    event_cost = Map.get(event_map, "marginal_api_cost_usd")
    measurement_cost = Map.get(measurements, :marginal_cost_usd)

    cond do
      is_nil(event_cost) and is_nil(measurement_cost) ->
        :ok

      is_number(event_cost) and is_number(measurement_cost) and event_cost == measurement_cost ->
        :ok

      true ->
        {:error, :malformed}
    end
  end

  defp exact_keys(map, allowed) do
    # `:marginal_cost_usd` is the only optional closed measurement key.
    if Enum.all?(Map.keys(map), &(&1 in allowed)) and
         Enum.all?(allowed, fn key ->
           Map.has_key?(map, key) or key == :marginal_cost_usd
         end) do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp provider_atom(value) when is_binary(value), do: Map.fetch(@providers, value)
  defp provider_atom(_value), do: :error

  defp admit_durable(event_map, state) do
    case ledger_opts(state) do
      {:error, reason} ->
        {:error, {:ledger, reason}}

      opts when is_list(opts) ->
        case AI.record_provider_usage(event_map, opts) do
          {:ok, receipt} -> {:ok, receipt}
          {:error, reason} -> {:error, {:ledger, classify_ledger_reason(reason)}}
          _other -> {:error, {:ledger, :unavailable}}
        end
    end
  rescue
    _ -> {:error, {:ledger, :exception}}
  catch
    _, _ -> {:error, {:ledger, :exception}}
  end

  # Immutable init-snapshotted ledger — never rereads Application/Config.
  defp ledger_opts(%{ledger: {:target, target}}), do: [target: target]
  defp ledger_opts(%{ledger: {:error, reason}}), do: {:error, reason}
  defp ledger_opts(_state), do: {:error, :unavailable}

  defp operation_atom("complete"), do: :complete
  defp operation_atom("embed_cloud"), do: :embed_cloud
  defp operation_atom("embed_local"), do: :embed_local
  defp operation_atom(_), do: :unknown

  defp project_budget(provider, event_map) do
    if Application.get_env(:arbor_ai, :enable_budget_tracking, true) do
      usage =
        %{
          event_id: event_map["event_id"],
          model: event_map["model_id"],
          input_tokens: event_map["input_tokens"],
          output_tokens: event_map["output_tokens"]
        }
        |> maybe_put_cost(event_map)

      BudgetTracker.record_usage(provider, usage)
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp maybe_put_cost(usage, event_map) do
    case Map.get(event_map, "marginal_api_cost_usd") do
      cost when is_number(cost) -> Map.put(usage, :cost_usd, cost)
      _ -> usage
    end
  end

  defp observe_failure(:malformed, _metadata), do: :ok

  defp observe_failure({:ledger, reason}, metadata) when is_map(metadata) do
    Logger.debug("provider usage ledger admission failed",
      event_id: bounded_log_string(Map.get(metadata, :event_id)),
      provider: bounded_log_string(Map.get(metadata, :provider)),
      operation: closed_operation(Map.get(metadata, :operation)),
      reason: closed_ledger_reason(reason)
    )

    :ok
  end

  defp observe_failure(_reason, _metadata), do: :ok

  defp classify_ledger_reason(reason) when is_atom(reason) do
    if MapSet.member?(@ledger_failure_reasons, reason), do: reason, else: :unavailable
  end

  defp classify_ledger_reason({:append_indeterminate, _}), do: :append_indeterminate
  defp classify_ledger_reason(_reason), do: :unavailable

  defp closed_ledger_reason(reason) when is_atom(reason) do
    if MapSet.member?(@ledger_failure_reasons, reason), do: reason, else: :unavailable
  end

  defp closed_ledger_reason(_reason), do: :unavailable

  defp closed_operation(op) when op in @operations, do: op
  defp closed_operation(_), do: :unknown

  defp bounded_log_string(value)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 64,
       do: value

  defp bounded_log_string(_value), do: nil

  defp bounded_string(value, max_bytes \\ @max_string_bytes)

  defp bounded_string(value, max_bytes)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max_bytes do
    if String.valid?(value) and String.trim(value) == value, do: :ok, else: {:error, :malformed}
  end

  defp bounded_string(_value, _max_bytes), do: {:error, :malformed}

  defp token(value)
       when is_integer(value) and value >= 0 and value <= @max_token_count,
       do: :ok

  defp token(_value), do: {:error, :malformed}

  defp optional_cost(nil), do: :ok

  defp optional_cost(value) when is_integer(value) and value >= 0 and value <= @max_cost_usd,
    do: :ok

  defp optional_cost(value) when is_float(value) and value >= 0.0 and value < @max_cost_usd do
    if value == value, do: :ok, else: {:error, :malformed}
  end

  defp optional_cost(_value), do: {:error, :malformed}
end
