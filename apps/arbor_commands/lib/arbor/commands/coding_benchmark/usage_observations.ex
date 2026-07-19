defmodule Arbor.Commands.CodingBenchmark.UsageObservations do
  @moduledoc false

  # Closed projection of Arbor-supplied ACP usage into report-row observations.
  # Volatile provider usage is an observation, not a semantic-parity field.

  # Signed 64-bit ceiling matches Arbor.LLM.finite_number?/1 integer bounds.
  @max_integer 9_223_372_036_854_775_807
  @max_encoded_bytes 16_384

  # Canonical snake_case output key => accepted input aliases (prefer first match).
  # Provider-native cost is projected as cost_ticks only — never labeled as USD.
  @fields [
    {"input_tokens",
     [
       "input_tokens",
       :input_tokens,
       "inputTokens",
       "prompt_tokens",
       :prompt_tokens,
       "promptTokens"
     ]},
    {"output_tokens",
     [
       "output_tokens",
       :output_tokens,
       "outputTokens",
       "completion_tokens",
       :completion_tokens,
       "completionTokens"
     ]},
    {"total_tokens", ["total_tokens", :total_tokens, "totalTokens"]},
    {"cache_read_input_tokens",
     [
       "cache_read_input_tokens",
       :cache_read_input_tokens,
       "cacheReadInputTokens"
     ]},
    {"cache_creation_input_tokens",
     [
       "cache_creation_input_tokens",
       :cache_creation_input_tokens,
       "cacheCreationInputTokens"
     ]},
    {"cost_ticks", ["cost_ticks", :cost_ticks, "costTicks", "cost", :cost]}
  ]

  @context_aliases ["context_tokens", :context_tokens, "contextTokens"]

  @doc """
  Project closed usage observations from a coding result (or metrics map).

  Returns a JSON-clean map of accepted non-negative finite numeric fields.
  Malformed, negative, non-finite, nested, or oversized values are omitted.
  """
  @spec from_result(term()) :: map()
  def from_result(result) when is_map(result) and not is_struct(result) do
    metrics = first_metrics(result)
    usage = first_usage(result, metrics)
    context = first_context_tokens(metrics)

    usage
    |> from_usage()
    |> maybe_put_context_tokens(context)
    |> bound_encoded()
  end

  def from_result(_result), do: %{}

  @doc "Project closed usage observations from a metrics or raw usage map."
  @spec from_metrics(term()) :: map()
  def from_metrics(metrics) when is_map(metrics) and not is_struct(metrics) do
    usage = map_value(metrics, "usage", :usage)
    context = first_context_tokens(metrics)

    usage
    |> from_usage()
    |> maybe_put_context_tokens(context)
    |> bound_encoded()
  end

  def from_metrics(_metrics), do: %{}

  @doc "Project closed usage observations from a raw usage map."
  @spec from_usage(term()) :: map()
  def from_usage(usage) when is_map(usage) and not is_struct(usage) do
    Enum.reduce(@fields, %{}, fn {canonical, aliases}, acc ->
      case first_numeric(usage, aliases) do
        nil -> acc
        value -> Map.put(acc, canonical, value)
      end
    end)
  end

  def from_usage(_usage), do: %{}

  defp first_metrics(result) do
    sources = result_sources(result)

    Enum.find_value(sources, %{}, fn source ->
      case map_value(source, "metrics", :metrics) do
        metrics when is_map(metrics) and not is_struct(metrics) -> metrics
        _ -> nil
      end
    end)
  end

  defp first_usage(result, metrics) do
    case map_value(metrics, "usage", :usage) do
      usage when is_map(usage) and not is_struct(usage) ->
        usage

      _ ->
        Enum.find_value(result_sources(result), fn source ->
          case map_value(source, "usage", :usage) do
            usage when is_map(usage) and not is_struct(usage) -> usage
            _ -> nil
          end
        end)
    end
  end

  defp first_context_tokens(metrics) when is_map(metrics) do
    first_numeric(metrics, @context_aliases)
  end

  defp first_context_tokens(_metrics), do: nil

  defp result_sources(result) do
    payload = map_value(result, "payload", :payload)
    report = if is_map(payload), do: map_value(payload, "report", :report), else: nil
    raw = map_value(result, "raw", :raw)
    Enum.filter([report, payload, raw, result], &(is_map(&1) and not is_struct(&1)))
  end

  defp maybe_put_context_tokens(observations, nil), do: observations

  defp maybe_put_context_tokens(observations, value)
       when is_map(observations) and not is_map_key(observations, "context_tokens") do
    Map.put(observations, "context_tokens", value)
  end

  defp maybe_put_context_tokens(observations, _value), do: observations

  defp first_numeric(map, aliases) when is_map(map) do
    Enum.find_value(aliases, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> normalize_numeric(value)
        :error -> nil
      end
    end)
  end

  defp first_numeric(_map, _aliases), do: nil

  # Token and tick counts must be non-negative finite numbers within signed-64.
  # Floats are only retained when they are finite and convert cleanly; cost maps
  # and other nested shapes are rejected (fail-closed per field).
  defp normalize_numeric(value) when is_integer(value) do
    if value >= 0 and value <= @max_integer, do: value, else: nil
  end

  defp normalize_numeric(value) when is_float(value) do
    cond do
      not finite_float?(value) -> nil
      value < 0.0 -> nil
      value > @max_integer * 1.0 -> nil
      true -> value
    end
  end

  defp normalize_numeric(_value), do: nil

  defp finite_float?(value) when is_float(value), do: value == value and value - value == 0.0
  defp finite_float?(_value), do: false

  defp bound_encoded(observations) when is_map(observations) do
    case Jason.encode(observations) do
      {:ok, encoded} when byte_size(encoded) <= @max_encoded_bytes -> observations
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp bound_encoded(_observations), do: %{}

  defp map_value(map, string_key, atom_key) when is_map(map) do
    case Map.fetch(map, string_key) do
      {:ok, value} -> value
      :error -> Map.get(map, atom_key)
    end
  end

  defp map_value(_map, _string_key, _atom_key), do: nil
end
