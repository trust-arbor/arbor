defmodule Arbor.LLM.Plugs.Usage do
  @moduledoc """
  Emits one bounded `[:arbor, :llm, :usage]` observation for a final,
  non-streaming ReqLLM operation, or for an eagerly completed streaming
  operation after its final Arbor response has passed the response boundary.

  Only canonical evidence from `%ReqLLM.Response{}` and Arbor's bounded
  embedding result tuple is considered authoritative. The plug never emits
  prompts, responses, provider metadata, headers, errors, or arbitrary terms.

  Lazy `stream/2` remains intentionally unaccounted for: it can be partially
  consumed or abandoned before terminal usage exists. Only
  `complete_streaming/3`, which eagerly consumes a bounded stream and returns a
  validated final response, uses the streaming finalizer.
  """

  use Arbor.LLM.Plug

  alias Arbor.LLM.Call
  alias Arbor.LLM.Response

  @max_token_count 1_000_000_000
  @max_cost_usd 1_000_000.0
  @max_string_bytes 128
  @recognized_operations [:complete, :embed_cloud, :embed_local]

  @impl Arbor.LLM.Plug
  def call(%Call{halted: true} = call), do: call

  def call(%Call{operation: operation, result: result, metadata: metadata} = call)
      when operation in @recognized_operations do
    if Map.get(metadata, :usage_emitted, false) do
      call
    else
      event_id = bounded_event_id(Map.get(metadata, :event_id, new_event_id()))
      {measurements, usage_status} = extract_usage(operation, result)
      {provider, model} = model_identity(operation, call.request)

      emit_usage(
        measurements,
        %{event_id: event_id, provider: provider, model: model},
        operation,
        usage_status
      )

      Call.put_metadata(call, %{event_id: event_id, usage_emitted: true})
    end
  rescue
    _ -> call
  catch
    _, _ -> call
  end

  def call(%Call{} = call), do: call

  @doc false
  @spec streaming_provenance(Call.t()) :: map()
  def streaming_provenance(%Call{halted: halted, metadata: metadata, request: request}) do
    {provider, model} = model_identity(:complete, request)

    %{
      event_id: bounded_event_id(Map.get(metadata, :event_id, new_event_id())),
      provider: provider,
      model: model,
      halted?: halted,
      replayed?: halted or replayed?(metadata),
      usage_finalized?: false
    }
  end

  @doc """
  Finalize usage for an eagerly consumed streaming response.

  The caller must invoke this only after the final translated response has
  passed `Arbor.LLM.Boundary.completion/2`. Missing or invalid usage is not an
  observation. The returned bounded state prevents repeated finalization from
  emitting a second event.
  """
  @spec finalize_streaming(Response.t(), map()) :: map()
  def finalize_streaming(%Response{usage: usage}, provenance) when is_map(provenance) do
    cond do
      Map.get(provenance, :usage_finalized?, false) ->
        provenance

      Map.get(provenance, :halted?, false) or Map.get(provenance, :replayed?, false) ->
        Map.put(provenance, :usage_finalized?, true)

      true ->
        finalized = Map.put(provenance, :usage_finalized?, true)

        case usage do
          usage when is_map(usage) and map_size(usage) > 0 ->
            case normalize_usage(:complete, usage) do
              {measurements, :authoritative} ->
                emit_usage(measurements, provenance, :complete)
                Map.put(finalized, :usage_emitted?, true)

              _ ->
                finalized
            end

          _ ->
            finalized
        end
    end
  rescue
    _ -> provenance
  catch
    _, _ -> provenance
  end

  def finalize_streaming(_response, provenance) when is_map(provenance),
    do: Map.put(provenance, :usage_finalized?, true)

  defp extract_usage(operation, result) do
    case usage_map(operation, result) do
      {:ok, usage} -> normalize_usage(operation, usage)
      :missing -> {empty_measurements(), :missing}
    end
  end

  defp emit_usage(measurements, provenance, operation, usage_status \\ :authoritative) do
    emit(
      %{
        count: 1,
        input: measurements.input,
        output: measurements.output,
        total: measurements.total,
        cached: measurements.cached
      }
      |> maybe_put_cost(measurements),
      %{
        event_id: bounded_event_id(Map.get(provenance, :event_id, new_event_id())),
        source: :req_llm,
        operation: operation,
        provider: safe_string(Map.get(provenance, :provider, "unknown")),
        model: safe_string(Map.get(provenance, :model, "unknown")),
        usage_status: usage_status
      }
    )
  end

  defp usage_map(:complete, {:ok, %ReqLLM.Response{stream?: false} = response}) do
    case ReqLLM.Response.usage(response) do
      usage when is_map(usage) and map_size(usage) > 0 -> {:ok, usage}
      _ -> :missing
    end
  end

  defp usage_map(operation, {:ok, _indexed_embeddings, usage})
       when operation in [:embed_cloud, :embed_local] and is_map(usage) and map_size(usage) > 0,
       do: {:ok, usage}

  defp usage_map(_operation, _result), do: :missing

  defp normalize_usage(operation, usage) when is_map(usage) and map_size(usage) <= 64 do
    input =
      recognized_value(usage, [:input_tokens, "input_tokens", :prompt_tokens, "prompt_tokens"])

    output =
      recognized_value(usage, [
        :output_tokens,
        "output_tokens",
        :completion_tokens,
        "completion_tokens"
      ])

    total = recognized_value(usage, [:total_tokens, "total_tokens"])

    cached =
      recognized_value(usage, [
        :cached_tokens,
        "cached_tokens",
        :cache_read_tokens,
        "cache_read_tokens"
      ])

    cost = recognized_value(usage, [:total_cost, "total_cost"])

    with {:ok, input} <- token(input),
         {:ok, output} <- embedding_output(operation, output),
         {:ok, total} <- total_tokens(total, input, output),
         {:ok, cached} <- optional_token(cached),
         true <- cached <= input,
         {:ok, cost} <- optional_cost(cost) do
      {%{input: input, output: output, total: total, cached: cached, cost: cost}, :authoritative}
    else
      _ -> {empty_measurements(), :invalid}
    end
  end

  defp normalize_usage(_operation, _usage), do: {empty_measurements(), :invalid}

  defp embedding_output(operation, nil) when operation in [:embed_cloud, :embed_local],
    do: {:ok, 0}

  defp embedding_output(_operation, value), do: token(value)

  defp total_tokens(nil, input, output), do: token(input + output)

  defp total_tokens(value, input, output) do
    with {:ok, value} <- token(value), true <- value >= input + output do
      {:ok, value}
    else
      _ -> :error
    end
  end

  defp token(value), do: bounded_nonnegative_integer(value)
  defp optional_token(nil), do: {:ok, 0}
  defp optional_token(value), do: token(value)

  defp bounded_nonnegative_integer(value)
       when is_integer(value) and value >= 0 and value <= @max_token_count,
       do: {:ok, value}

  defp bounded_nonnegative_integer(_value), do: :error

  defp optional_cost(nil), do: {:ok, nil}

  defp optional_cost(value) when is_integer(value) and value >= 0 and value <= @max_cost_usd,
    do: {:ok, value * 1.0}

  defp optional_cost(value) when is_float(value) and value >= 0.0 and value < @max_cost_usd do
    if value == value, do: {:ok, value}, else: :error
  end

  defp optional_cost(_value), do: :error

  defp empty_measurements, do: %{input: 0, output: 0, total: 0, cached: 0, cost: nil}

  defp maybe_put_cost(measurements, %{cost: cost}) when is_float(cost),
    do: Map.put(measurements, :marginal_cost_usd, cost)

  defp maybe_put_cost(measurements, _measurements), do: measurements

  defp recognized_value(usage, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(usage, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp model_identity(_operation, {model_spec, _inputs, _opts}) do
    model_identity(model_spec)
  end

  defp model_identity(_operation, _request), do: {"unknown", "unknown"}

  defp model_identity(%LLMDB.Model{provider: provider, id: id}) do
    {safe_provider(provider), safe_string(id)}
  end

  defp model_identity(model_spec) when is_binary(model_spec) do
    case ReqLLM.model(model_spec) do
      {:ok, %LLMDB.Model{provider: provider, id: id}} ->
        {safe_provider(provider), safe_string(id)}

      _ ->
        {"unknown", "unknown"}
    end
  rescue
    _ -> {"unknown", "unknown"}
  end

  defp model_identity(_model_spec), do: {"unknown", "unknown"}

  defp replayed?(metadata) do
    Map.has_key?(metadata, :replayed_from)
  end

  defp safe_provider(provider) when is_atom(provider), do: safe_string(Atom.to_string(provider))
  defp safe_provider(provider) when is_binary(provider), do: safe_string(provider)
  defp safe_provider(_provider), do: "unknown"

  defp safe_string(value)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_string_bytes do
    if String.valid?(value) and String.trim(value) == value, do: value, else: "unknown"
  end

  defp safe_string(_value), do: "unknown"

  defp bounded_event_id(value)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 64,
       do: value

  defp bounded_event_id(_value), do: new_event_id()

  defp new_event_id, do: "llm-" <> Integer.to_string(:erlang.unique_integer([:positive]))

  defp emit(measurements, metadata) do
    :telemetry.execute([:arbor, :llm, :usage], measurements, metadata)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
