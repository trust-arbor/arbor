defmodule Arbor.Memory.ContextWindow.Serialization do
  @moduledoc false
  # Internal serialization/deserialization helpers for ContextWindow.
  # Extracted to reduce parent module size. Not a public API.

  alias Arbor.Memory.ContextWindow

  @default_max_tokens 10_000
  @default_summary_threshold 0.7
  @default_ratios %{
    full_detail: 0.50,
    recent_summary: 0.25,
    distant_summary: 0.15,
    retrieved: 0.10
  }

  # ============================================================================
  # Serialization
  # ============================================================================

  @doc false
  @spec serialize(ContextWindow.t()) :: map()
  def serialize(%{multi_layer: true} = window) do
    %{
      "agent_id" => window.agent_id,
      "multi_layer" => true,
      "version" => window.version,
      "max_tokens" => window.max_tokens,
      "model_id" => window.model_id,
      "distant_summary" => window.distant_summary,
      "recent_summary" => window.recent_summary,
      "full_detail" => window.full_detail,
      "clarity_boundary" => serialize_datetime(window.clarity_boundary),
      "retrieved_context" => window.retrieved_context,
      "distant_tokens" => window.distant_tokens,
      "recent_tokens" => window.recent_tokens,
      "detail_tokens" => window.detail_tokens,
      "retrieved_tokens" => window.retrieved_tokens,
      "ratios" => window.ratios,
      "summarization_enabled" => window.summarization_enabled,
      "summarization_algorithm" => to_string(window.summarization_algorithm),
      "summarization_model" => window.summarization_model,
      "summarization_provider" =>
        if(window.summarization_provider, do: to_string(window.summarization_provider)),
      "fact_extraction_enabled" => window.fact_extraction_enabled,
      "fact_extraction_model" => window.fact_extraction_model,
      "fact_extraction_provider" =>
        if(window.fact_extraction_provider, do: to_string(window.fact_extraction_provider)),
      "min_fact_confidence" => window.min_fact_confidence,
      "last_compression_at" => serialize_datetime(window.last_compression_at),
      "compression_count" => window.compression_count
    }
  end

  def serialize(window) do
    %{
      "agent_id" => window.agent_id,
      "entries" =>
        Enum.map(window.entries, fn {type, content, timestamp} ->
          %{
            "type" => to_string(type),
            "content" => content,
            "timestamp" => DateTime.to_iso8601(timestamp)
          }
        end),
      "max_tokens" => window.max_tokens,
      "summary_threshold" => window.summary_threshold,
      "model_id" => window.model_id
    }
  end

  # ============================================================================
  # Deserialization
  # ============================================================================

  @doc false
  @spec deserialize(map()) :: ContextWindow.t()
  def deserialize(data) when is_map(data) do
    if flex_field(data, :multi_layer) do
      deserialize_multi_layer(data)
    else
      deserialize_legacy(data)
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp deserialize_multi_layer(data) do
    base = deserialize_multi_layer_base(data)
    tokens = deserialize_multi_layer_tokens(data)
    summarization = deserialize_multi_layer_summarization(data)
    fact_extraction = deserialize_multi_layer_fact_extraction(data)

    struct!(ContextWindow, Map.merge(base, tokens) |> Map.merge(summarization) |> Map.merge(fact_extraction))
  end

  defp deserialize_multi_layer_base(data) do
    %{
      agent_id: flex_field(data, :agent_id),
      multi_layer: true,
      version: flex_field(data, :version) || 1,
      max_tokens: flex_field(data, :max_tokens) || @default_max_tokens,
      model_id: flex_field(data, :model_id),
      distant_summary: flex_field(data, :distant_summary) || "",
      recent_summary: flex_field(data, :recent_summary) || "",
      full_detail: flex_field(data, :full_detail) || [],
      clarity_boundary: parse_datetime(flex_field(data, :clarity_boundary)),
      retrieved_context: flex_field(data, :retrieved_context) || [],
      ratios: flex_field(data, :ratios) || @default_ratios,
      last_compression_at: parse_datetime(flex_field(data, :last_compression_at)),
      compression_count: flex_field(data, :compression_count) || 0
    }
  end

  defp deserialize_multi_layer_tokens(data) do
    %{
      distant_tokens: flex_field(data, :distant_tokens) || 0,
      recent_tokens: flex_field(data, :recent_tokens) || 0,
      detail_tokens: flex_field(data, :detail_tokens) || 0,
      retrieved_tokens: flex_field(data, :retrieved_tokens) || 0
    }
  end

  defp deserialize_multi_layer_summarization(data) do
    %{
      summarization_enabled: flex_field(data, :summarization_enabled) || false,
      summarization_algorithm:
        parse_atom(flex_field(data, :summarization_algorithm), :prose),
      summarization_model: flex_field(data, :summarization_model),
      summarization_provider:
        parse_atom(flex_field(data, :summarization_provider), nil)
    }
  end

  defp deserialize_multi_layer_fact_extraction(data) do
    %{
      fact_extraction_enabled: flex_field(data, :fact_extraction_enabled) || false,
      fact_extraction_model: flex_field(data, :fact_extraction_model),
      fact_extraction_provider:
        parse_atom(flex_field(data, :fact_extraction_provider), nil),
      min_fact_confidence: flex_field(data, :min_fact_confidence) || 0.7
    }
  end

  defp deserialize_legacy(data) do
    entries =
      (flex_field(data, :entries) || [])
      |> Enum.map(&deserialize_entry/1)

    %ContextWindow{
      agent_id: flex_field(data, :agent_id),
      entries: entries,
      max_tokens: flex_field(data, :max_tokens) || @default_max_tokens,
      summary_threshold: flex_field(data, :summary_threshold) || @default_summary_threshold,
      model_id: flex_field(data, :model_id)
    }
  end

  defp flex_field(data, key) do
    Map.get(data, key) || Map.get(data, to_string(key))
  end

  defp deserialize_entry(entry) do
    type = parse_entry_type(entry["type"] || Map.get(entry, :type))
    content = entry["content"] || Map.get(entry, :content)
    timestamp = parse_timestamp(entry["timestamp"] || Map.get(entry, :timestamp))
    {type, content, timestamp}
  end

  defp parse_timestamp(nil), do: DateTime.utc_now()
  defp parse_timestamp(%DateTime{} = dt), do: dt
  defp parse_timestamp(ts) when is_binary(ts), do: DateTime.from_iso8601(ts) |> elem(1)

  defp parse_entry_type("message"), do: :message
  defp parse_entry_type("summary"), do: :summary
  defp parse_entry_type(:message), do: :message
  defp parse_entry_type(:summary), do: :summary
  defp parse_entry_type(_), do: :message

  defp serialize_datetime(nil), do: nil
  defp serialize_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp parse_atom(nil, default), do: default
  defp parse_atom(value, _default) when is_atom(value), do: value

  defp parse_atom(value, default) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    _ -> default
  end

  defp parse_atom(_, default), do: default
end
