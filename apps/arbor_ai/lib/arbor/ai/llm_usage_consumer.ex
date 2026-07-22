defmodule Arbor.AI.LLMUsageConsumer do
  @moduledoc """
  Supervised owner for `[:arbor, :llm, :usage]` telemetry.

  Validation is synchronous in the telemetry callback. Only authoritative,
  closed events for known providers are cast to `BudgetTracker`; all malformed
  input, unknown providers, disabled trackers, and tracker failures are
  ignored without affecting the originating LLM call.

  Event IDs are intentionally held only by `BudgetTracker` in bounded memory.
  Duplicate events after a tracker restart or cache eviction remain a
  residual at-least-once accounting risk.
  """

  use GenServer

  alias Arbor.AI.BudgetTracker

  @event [:arbor, :llm, :usage]
  @handler_id __MODULE__
  @max_token_count 1_000_000_000
  @max_cost_usd 1_000_000.0
  @max_string_bytes 128
  @operations [:complete, :embed_cloud, :embed_local]
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

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :telemetry.detach(@handler_id)
    :ok = :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil)
    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  def handle_event(@event, measurements, metadata, _config) do
    with {:ok, usage} <- validate_event(measurements, metadata),
         {:ok, provider} <- provider(Map.fetch!(metadata, :provider)) do
      safe_record(provider, usage)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp validate_event(measurements, metadata)
       when is_map(measurements) and is_map(metadata) do
    with :ok <-
           exact_keys(measurements, [:count, :input, :output, :total, :cached, :marginal_cost_usd]),
         :ok <-
           exact_keys(metadata, [:event_id, :source, :operation, :provider, :model, :usage_status]),
         :ok <- validate_metadata(metadata),
         :ok <- validate_measurements(measurements) do
      usage = %{
        event_id: metadata.event_id,
        model: metadata.model,
        input_tokens: measurements.input,
        output_tokens: measurements.output
      }

      {:ok, maybe_cost(usage, measurements)}
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
         true <- metadata.usage_status == :authoritative do
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

  defp exact_keys(map, allowed) do
    if Enum.all?(Map.keys(map), &(&1 in allowed)) and
         Enum.all?(allowed, &(Map.has_key?(map, &1) or &1 == :marginal_cost_usd)) do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp provider(value) when is_binary(value), do: Map.fetch(@providers, value)
  defp provider(_value), do: :error

  defp safe_record(provider, usage) do
    if Application.get_env(:arbor_ai, :enable_budget_tracking, true) do
      BudgetTracker.record_usage(provider, usage)
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp maybe_cost(usage, measurements) do
    case Map.fetch(measurements, :marginal_cost_usd) do
      {:ok, cost} -> Map.put(usage, :cost_usd, cost)
      :error -> usage
    end
  end

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
