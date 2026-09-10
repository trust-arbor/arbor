defmodule Arbor.Orchestrator.Session.PrivateMemory.Embedding do
  @moduledoc false

  alias Arbor.{AI, LLM, Trust}
  alias Arbor.Contracts.Persistence.VectorRecord
  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Orchestrator.Config

  @keys [:enabled, :provider, :model, :base_url, :timeout_ms]
  @max_text_bytes 65_536
  @max_batch_bytes 393_216
  @max_response_bytes 2_097_152

  def validate_inputs(texts), do: validate_texts(texts)

  def route do
    case Config.private_conversation_memory() do
      value when value in [false, nil] ->
        :disabled

      opts ->
        if options?(opts, []) and Keyword.get(opts, :enabled) === false,
          do: :disabled,
          else: resolve_route(opts)
    end
  end

  def authorize(route, scope) do
    case Trust.authorize_egress(scope.agent_id, :on_host,
           egress_taint: TaintEnvelope.missing_fallback(),
           egress_destination: route.base_url,
           egress_provider: route.provider,
           egress_runtime: "arbor",
           egress_model: route.model,
           session_id: scope.session_id,
           task_id: scope.turn_id,
           principal_scope: scope.human_id
         ) do
      :allow -> :ok
      _ -> {:error, :private_memory_embedding_egress_refused}
    end
  end

  # All arguments originate in the Session shell. No admission or owner-selector
  # field is passed to the LLM worker. The facade owns the actual deadline.
  # Enabled route validation is diagnostic; adapter admission revalidates and
  # captures the live single-attempt composition before provider preparation.
  def run(route, texts, remaining_ms) do
    with :ok <- validate_texts(texts),
         true <- is_integer(remaining_ms) and remaining_ms > 0,
         {:ok, base_url} <-
           LLM.validate_endpoint(route.base_url, {:req_llm_base, route.provider}),
         true <- base_url == route.base_url,
         true <- loopback?(route.base_url),
         :on_host <- AI.egress_tier_for(route.provider, route.base_url),
         {:ok, result} <-
           LLM.embed_batch(route.provider, route.model, texts,
             base_url: route.base_url,
             timeout_ms: min(route.timeout_ms, remaining_ms),
             max_response_bytes: @max_response_bytes,
             req_http_options: [retry: false, redirect: false],
             require_live_pipeline: true
           ),
         {:ok, embeddings} <- associated_embeddings(result, route, length(texts)) do
      {:ok, embeddings}
    else
      {:error, :live_embedding_pipeline_unsupported} ->
        {:error, :private_memory_embedding_pipeline_unsupported}

      _ ->
        {:error, :private_memory_embedding_unavailable}
    end
  rescue
    _ -> {:error, :private_memory_embedding_unavailable}
  catch
    _, _ -> {:error, :private_memory_embedding_unavailable}
  end

  defp resolve_route(opts) do
    with true <- options?(opts, []),
         true <- Keyword.get(opts, :enabled) === true,
         {:ok, provider} <- provider(Keyword.get(opts, :provider)),
         model <- Keyword.get(opts, :model),
         true <- label?(model),
         timeout <- Keyword.get(opts, :timeout_ms, 10_000),
         true <- is_integer(timeout) and timeout in 1..30_000,
         {:ok, base_url} <-
           LLM.validate_endpoint(Keyword.get(opts, :base_url), {:req_llm_base, provider}),
         true <- loopback?(base_url),
         :on_host <- AI.egress_tier_for(provider, base_url),
         :ok <- LLM.validate_live_embedding_pipeline() do
      {:ok, %{provider: provider, model: model, base_url: base_url, timeout_ms: timeout}}
    else
      {:error, :live_embedding_pipeline_unsupported} ->
        {:error, :private_memory_embedding_pipeline_unsupported}

      _ ->
        {:error, :private_memory_configuration_unavailable}
    end
  end

  defp associated_embeddings(result, route, count) do
    with %{
           association_version: 1,
           indexed_embeddings: indexed,
           embeddings: vectors,
           provider: provider,
           model: model,
           dimensions: dimensions
         } <- result,
         true <- provider == route.provider and model == route.model,
         true <- dimensions == VectorRecord.dimensions(),
         true <- is_list(indexed) and length(indexed) == count,
         true <- Enum.map(indexed, &Map.get(&1, :index)) == Enum.to_list(0..(count - 1)),
         true <- Enum.map(indexed, &Map.get(&1, :embedding)) == vectors do
      Enum.reduce_while(indexed, {:ok, []}, fn item, {:ok, acc} ->
        case VectorRecord.normalize_vector(item.embedding) do
          {:ok, vector} ->
            if Enum.any?(vector, &(&1 != 0.0)) do
              value = %{
                embedding: vector,
                provider: provider,
                model: model,
                dimensions: dimensions
              }

              {:cont, {:ok, [value | acc]}}
            else
              {:halt, {:error, :private_memory_embedding_unavailable}}
            end

          _ ->
            {:halt, {:error, :private_memory_embedding_unavailable}}
        end
      end)
      |> case do
        {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
        error -> error
      end
    else
      _ -> {:error, :private_memory_embedding_unavailable}
    end
  end

  defp validate_texts(texts), do: validate_texts(texts, 0, 0)
  defp validate_texts([], count, _bytes) when count in 1..6, do: :ok

  defp validate_texts([text | rest], count, bytes)
       when is_binary(text) and byte_size(text) in 1..@max_text_bytes and count < 6 do
    total = bytes + byte_size(text)

    if total <= @max_batch_bytes and String.valid?(text),
      do: validate_texts(rest, count + 1, total),
      else: {:error, :invalid_private_memory_embedding_input}
  end

  defp validate_texts(_, _, _), do: {:error, :invalid_private_memory_embedding_input}

  defp loopback?(base_url) do
    case URI.parse(base_url).host do
      "::1" ->
        true

      host when is_binary(host) ->
        case :inet.parse_address(String.to_charlist(host)) do
          {:ok, {127, _, _, _}} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp provider(value) when value in [:ollama, "ollama"], do: {:ok, "ollama"}
  defp provider(value) when value in [:lm_studio, "lm_studio"], do: {:ok, "lm_studio"}
  defp provider(_), do: {:error, :unsupported_private_memory_provider}

  defp label?(value),
    do:
      is_binary(value) and byte_size(value) in 1..256 and String.valid?(value) and
        String.trim(value) == value

  defp options?([], _seen), do: true

  defp options?([{key, _} | rest], seen),
    do: key in @keys and key not in seen and options?(rest, [key | seen])

  defp options?(_, _), do: false
end
