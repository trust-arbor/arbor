defmodule Arbor.Memory.ContextWindow.Compression do
  @moduledoc false
  # Internal compression pipeline helpers for ContextWindow.
  # Handles summarization, fact extraction, deduplication, and signal emission.
  # Extracted to reduce parent module size. Not a public API.

  require Logger

  alias Arbor.Common.LazyLoader
  alias Arbor.Memory.ContextWindow.Formatting
  alias Arbor.Memory.FactExtractor
  alias Arbor.Memory.GraphOps
  alias Arbor.Memory.Signals

  # Threshold for semantic dedup of retrieved context (cosine similarity)
  @retrieved_dedup_threshold 0.85

  @summarization_system_prompt """
  You are a context compression assistant. Your job is to summarize conversation history
  while preserving the most important information.

  Guidelines:
  - Preserve key decisions, outcomes, and facts
  - Keep names, specific values, and technical details that might be referenced later
  - Remove redundant back-and-forth, pleasantries, and filler
  - Use concise bullet points or short paragraphs
  - For tool results, keep only the outcome (success/failure) and key data
  - Maintain chronological order
  - Write in third person past tense

  Output ONLY the summary, no preamble or explanation.
  """

  @incremental_bullet_system_prompt """
  You are a context compression assistant that generates structured bullet point summaries.

  Your output format is ALWAYS bullet points, one per line, starting with "- ".

  Guidelines:
  - Each bullet captures ONE key decision, outcome, or fact
  - Include specific names, values, and technical details
  - Use past tense
  - Be concise - aim for 10-20 words per bullet
  - Focus on what happened and what was decided, not the discussion
  - For tool results, capture only the key outcome

  Output ONLY bullet points, no preamble, headers, or explanation.
  """

  # ============================================================================
  # Compression Pipeline
  # ============================================================================

  # How long to wait for the (LLM-backed) summarization and fact-extraction
  # tasks before degrading to the non-LLM fallback. Slow local providers
  # (e.g. a loaded homelab Ollama) can exceed the default, so it's
  # overridable via `config :arbor_memory, :compression_llm_timeout_ms`.
  @default_compression_llm_timeout_ms :timer.seconds(30)

  @doc false
  def run_compression_pipeline(%{multi_layer: true} = window, messages) do
    timeout = compression_llm_timeout()

    # Always run summarization
    summarize_task = Task.async(fn -> summarize_messages(window, messages) end)

    # Optionally run fact extraction in parallel
    fact_task =
      if window.fact_extraction_enabled do
        Task.async(fn -> extract_facts_from_messages(window, messages) end)
      else
        nil
      end

    # Wait for summarization (required). On timeout, degrade to the
    # non-LLM fallback (formatted messages) rather than crashing the
    # whole compression cycle — a slow/unreachable LLM must never take
    # down the GenServer that drives compression.
    {demoted_text, demoted_tokens} =
      case yield_or_shutdown(summarize_task, timeout) do
        {:ok, result} ->
          result

        :timeout ->
          Logger.warning("Summarization timed out during compression; using fallback",
            agent_id: window.agent_id,
            timeout_ms: timeout
          )

          fallback_summary(messages)
      end

    # Wait for fact extraction (optional). Timeout or error degrades to
    # no extracted facts.
    extracted_facts =
      if fact_task do
        case yield_or_shutdown(fact_task, timeout) do
          {:ok, {:ok, facts}} ->
            facts

          {:ok, {:error, reason}} ->
            Logger.debug("Fact extraction failed during compression",
              reason: inspect(reason),
              agent_id: window.agent_id
            )

            []

          :timeout ->
            Logger.debug("Fact extraction timed out during compression",
              agent_id: window.agent_id,
              timeout_ms: timeout
            )

            []
        end
      else
        []
      end

    {demoted_text, demoted_tokens, extracted_facts}
  end

  # Await a task with a timeout, shutting it down on timeout so the
  # linked task process doesn't leak or later deliver a stray message.
  defp yield_or_shutdown(task, timeout) do
    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      _ -> :timeout
    end
  end

  # Non-LLM fallback summary identical to what summarize_*/3 produce on an
  # LLM error: the formatted messages themselves (non-empty).
  defp fallback_summary(messages) do
    formatted = Formatting.format_messages_for_summary(messages)
    {formatted, estimate_tokens_text(formatted)}
  end

  @doc false
  def split_for_compression(messages, target_tokens) do
    # Messages are in reverse chronological order (newest first)
    # We want to demote from the end (oldest)
    reversed = Enum.reverse(messages)

    {to_demote, to_keep, _} =
      Enum.reduce(reversed, {[], [], 0}, fn msg, {demote, keep, tokens} ->
        msg_tokens = estimate_tokens(msg)

        if tokens < target_tokens do
          {[msg | demote], keep, tokens + msg_tokens}
        else
          {demote, [msg | keep], tokens}
        end
      end)

    # Return in original order (newest first for to_keep)
    {Enum.reverse(to_demote), to_keep}
  end

  @doc false
  def merge_into_recent_summary("", new_text), do: new_text

  def merge_into_recent_summary(existing, new_text) do
    existing_is_bullets = String.starts_with?(String.trim(existing), "- ")
    new_is_bullets = String.starts_with?(String.trim(new_text), "- ")

    cond do
      existing_is_bullets and new_is_bullets ->
        existing <> "\n" <> new_text

      existing_is_bullets ->
        existing <> "\n\n[Additional context]\n" <> new_text

      new_is_bullets ->
        existing <> "\n\n[Key points]\n" <> new_text

      true ->
        existing <> "\n\n" <> new_text
    end
  end

  @doc false
  def flow_to_distant(window, recent, distant, _recent_tokens) do
    distant_budget = distant_summary_budget(window)

    # Split recent in half - older half flows to distant
    lines = String.split(recent, "\n")
    mid = div(length(lines), 2)
    {to_distant, keep_recent} = Enum.split(lines, mid)

    to_distant_text = Enum.join(to_distant, "\n")
    new_recent_text = Enum.join(keep_recent, "\n")

    summarized_distant = maybe_summarize_for_distant(window, to_distant_text)
    updated_distant = merge_distant_content(window, distant, summarized_distant, distant_budget)

    final_distant = enforce_distant_budget(updated_distant, distant_budget)
    new_recent_tokens = estimate_tokens_text(new_recent_text)

    {new_recent_text, final_distant, new_recent_tokens, estimate_tokens_text(final_distant)}
  end

  # ============================================================================
  # Token Estimation (shared with parent)
  # ============================================================================

  @doc false
  def estimate_tokens(message) when is_map(message) do
    content = message[:content] || message["content"] || ""
    estimate_tokens_text(content)
  end

  @doc false
  def estimate_tokens_text(text) when is_binary(text) do
    # Rough approximation: 4 characters per token
    div(String.length(text), 4)
  end

  def estimate_tokens_text(_), do: 0

  @doc false
  def tokens_for_messages(messages) do
    Enum.reduce(messages, 0, fn msg, acc -> acc + estimate_tokens(msg) end)
  end

  # ============================================================================
  # Token Budget Helpers
  # ============================================================================

  @doc false
  def full_detail_budget(%{multi_layer: true, ratios: ratios, max_tokens: max}) do
    trunc(max * Map.get(ratios, :full_detail, 0.50))
  end

  def full_detail_budget(_window), do: 0

  @doc false
  def recent_summary_budget(%{multi_layer: true, ratios: ratios, max_tokens: max}) do
    trunc(max * Map.get(ratios, :recent_summary, 0.25))
  end

  def recent_summary_budget(_window), do: 0

  @doc false
  def distant_summary_budget(%{multi_layer: true, ratios: ratios, max_tokens: max}) do
    trunc(max * Map.get(ratios, :distant_summary, 0.15))
  end

  def distant_summary_budget(_window), do: 0

  @doc false
  def retrieved_budget(%{multi_layer: true, ratios: ratios, max_tokens: max}) do
    trunc(max * Map.get(ratios, :retrieved, 0.10))
  end

  def retrieved_budget(_window), do: 0

  # ============================================================================
  # Signal Emission
  # ============================================================================

  @doc false
  def emit_demotion_signal(%{agent_id: agent_id}, messages, compressed_tokens) do
    original_tokens = tokens_for_messages(messages)

    Signals.emit_context_summarized(agent_id, %{
      from_layer: :full_detail,
      to_layer: :recent_summary,
      original_tokens: original_tokens,
      compressed_tokens: compressed_tokens,
      compression_ratio:
        if(original_tokens > 0, do: compressed_tokens / original_tokens, else: 0),
      messages_demoted: length(messages)
    })

    :ok
  end

  @doc false
  def emit_fact_extraction_signal(%{agent_id: agent_id}, facts) do
    Signals.emit_facts_extracted(agent_id, %{
      count: length(facts),
      categories: Enum.frequencies_by(facts, fn f -> f[:category] || f.category end),
      source: :compression
    })

    :ok
  end

  @doc false
  @spec ingest_extracted_facts(String.t(), [map()]) :: :ok
  def ingest_extracted_facts(_agent_id, []), do: :ok

  def ingest_extracted_facts(agent_id, facts)
      when is_binary(agent_id) and is_list(facts) do
    if GraphOps.has_graph?(agent_id) do
      Enum.each(facts, &ingest_one_extracted_fact(agent_id, &1))
    end

    :ok
  end

  def ingest_extracted_facts(_agent_id, _facts), do: :ok

  # ============================================================================
  # Deduplication
  # ============================================================================

  @doc false
  def semantically_duplicate?(existing_contexts, new_content, source_context \\ nil)

  def semantically_duplicate?([], _content, _source_context), do: false

  def semantically_duplicate?(existing_contexts, new_content, source_context) do
    embedding =
      with {:ok, opts} <- Arbor.LLM.carry_sensitivity(source_context, []) do
        compute_embedding(new_content, opts)
      else
        _ -> nil
      end

    case embedding do
      nil ->
        # No embedding available, fall back to exact match
        Enum.any?(existing_contexts, fn ctx ->
          existing_content = ctx[:content] || ctx["content"] || ""
          existing_content == new_content
        end)

      new_embedding ->
        Enum.any?(existing_contexts, fn ctx ->
          context_exceeds_similarity?(ctx, new_embedding)
        end)
    end
  end

  @doc false
  def maybe_add_embedding(context, content) do
    embedding =
      with {:ok, opts} <- Arbor.LLM.carry_sensitivity(context, []) do
        compute_embedding(content, opts)
      else
        _ -> nil
      end

    case embedding do
      nil -> context
      embedding -> Map.put(context, :embedding, embedding)
    end
  end

  # ============================================================================
  # Private Helpers - Summarization
  # ============================================================================

  defp summarize_messages(%{summarization_enabled: false}, messages) do
    text = Formatting.format_messages_for_summary(messages)
    {text, estimate_tokens_text(text)}
  end

  defp summarize_messages(%{summarization_enabled: true} = window, messages) do
    case Arbor.LLM.carry_sensitivity(messages, summarization_llm_opts(window)) do
      {:ok, llm_opts} ->
        formatted = Formatting.format_messages_for_summary(messages)
        original_tokens = estimate_tokens_text(formatted)

        case window.summarization_algorithm do
          :incremental_bullets ->
            summarize_incremental(formatted, original_tokens, llm_opts)

          _prose ->
            summarize_prose(formatted, original_tokens, llm_opts)
        end

      {:error, _reason} ->
        fallback_summary(messages)
    end
  end

  defp summarize_prose(formatted, original_tokens, llm_opts) do
    target_words = max(100, div(original_tokens, 5))

    prompt =
      "Summarize the following conversation excerpt in approximately #{target_words} words.\n" <>
        "Focus on preserving decisions, outcomes, and important facts.\n\n" <>
        "CONVERSATION TO SUMMARIZE:\n#{formatted}\n\nSUMMARY:"

    case call_summarization_llm(prompt, :prose, llm_opts) do
      {:ok, summary} ->
        summary_tokens = estimate_tokens_text(summary)

        Logger.debug(
          "Context compression (prose): #{original_tokens} -> #{summary_tokens} tokens " <>
            "(#{Float.round(summary_tokens / max(1, original_tokens) * 100, 1)}%)"
        )

        {summary, summary_tokens}

      {:error, _reason} ->
        # Fallback to simple formatting
        {formatted, original_tokens}
    end
  end

  defp summarize_incremental(formatted, original_tokens, llm_opts) do
    target_bullets = max(3, div(original_tokens, 150))

    prompt =
      "Generate #{target_bullets} bullet points summarizing the key information.\n" <>
        "Each bullet should capture one decision, outcome, or important fact.\n\n" <>
        "CONVERSATION TO SUMMARIZE:\n#{formatted}\n\nNEW BULLETS:"

    case call_summarization_llm(prompt, :incremental_bullets, llm_opts) do
      {:ok, bullets} ->
        cleaned = clean_bullet_output(bullets)
        summary_tokens = estimate_tokens_text(cleaned)

        Logger.debug(
          "Context compression (incremental): #{original_tokens} -> #{summary_tokens} tokens " <>
            "(#{Float.round(summary_tokens / max(1, original_tokens) * 100, 1)}%), " <>
            "#{count_bullets(cleaned)} bullets"
        )

        {cleaned, summary_tokens}

      {:error, _reason} ->
        text = Formatting.format_messages_as_bullets(Formatting.messages_from_text(formatted))
        {text, estimate_tokens_text(text)}
    end
  end

  defp summarization_llm_opts(window) do
    opts = [
      agent_id: window.agent_id,
      sensitivity: Map.get(window, :sensitivity, :restricted),
      receive_timeout: compression_llm_timeout()
    ]

    opts =
      if window.summarization_model, do: [{:model, window.summarization_model} | opts], else: opts

    opts =
      if window.summarization_provider,
        do: [{:provider, window.summarization_provider} | opts],
        else: opts

    opts
  end

  defp compression_llm_timeout do
    Application.get_env(
      :arbor_memory,
      :compression_llm_timeout_ms,
      @default_compression_llm_timeout_ms
    )
  end

  defp call_summarization_llm(prompt, algorithm, llm_opts) do
    if LazyLoader.exported?(Arbor.AI, :generate_text, 2) do
      system_prompt =
        case algorithm do
          :incremental_bullets -> @incremental_bullet_system_prompt
          _ -> @summarization_system_prompt
        end

      opts =
        llm_opts
        |> Keyword.take([:taint, :sensitivity, :agent_id, :receive_timeout])
        |> Keyword.merge(system_prompt: system_prompt, max_tokens: 1000)
        |> maybe_add_llm_opt(:model, llm_opts[:model])
        |> maybe_add_llm_opt(:provider, llm_opts[:provider])

      case Arbor.AI.generate_text(prompt, opts) do
        {:ok, %{text: text}} when is_binary(text) ->
          {:ok, String.trim(text)}

        {:ok, response} when is_binary(response) ->
          {:ok, String.trim(response)}

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error, {:unexpected_response, other}}
      end
    else
      {:error, :arbor_ai_not_available}
    end
  end

  defp maybe_add_llm_opt(opts, _key, nil), do: opts
  defp maybe_add_llm_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp clean_bullet_output(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn line ->
      String.starts_with?(line, "- ") or String.starts_with?(line, "* ")
    end)
    |> Enum.map_join("\n", fn line ->
      if String.starts_with?(line, "* ") do
        "- " <> String.slice(line, 2..-1//1)
      else
        line
      end
    end)
  end

  defp count_bullets(text) do
    text
    |> String.split("\n")
    |> Enum.count(fn line -> String.starts_with?(String.trim(line), "- ") end)
  end

  # ============================================================================
  # Private Helpers - Distant Summary Management
  # ============================================================================

  defp maybe_summarize_for_distant(window, text) do
    if window.summarization_enabled and String.length(text) > 500 do
      case summarize_for_distant(window, text) do
        {:ok, summary} -> summary
        {:error, _} -> text
      end
    else
      text
    end
  end

  defp merge_distant_content(_window, "", new_content, _budget), do: new_content

  defp merge_distant_content(window, existing, new_content, budget) do
    combined = existing <> "\n\n" <> new_content

    if estimate_tokens_text(combined) > budget do
      case summarize_for_distant(window, combined) do
        {:ok, summary} -> summary
        {:error, _} -> truncate_to_budget(combined, budget)
      end
    else
      combined
    end
  end

  defp enforce_distant_budget(text, budget) do
    if estimate_tokens_text(text) > budget do
      truncate_to_budget(text, budget)
    else
      text
    end
  end

  defp summarize_for_distant(%{summarization_enabled: false}, _text) do
    {:error, :summarization_disabled}
  end

  defp summarize_for_distant(%{summarization_enabled: true} = window, text) do
    original_tokens = estimate_tokens_text(text)
    target_words = max(50, div(original_tokens, 7))

    prompt =
      "Create a highly condensed summary of this context in approximately #{target_words} words.\n" <>
        "Keep only the most essential facts, decisions, and outcomes.\n" <>
        "This will be used as distant memory, so focus on what might be referenced later.\n\n" <>
        "CONTENT:\n#{text}\n\nCONDENSED SUMMARY:"

    with {:ok, opts} <-
           Arbor.LLM.carry_sensitivity(
             [window.full_detail, window.retrieved_context, text],
             summarization_llm_opts(window)
           ) do
      call_summarization_llm(prompt, :prose, opts)
    end
  end

  defp truncate_to_budget(text, budget_tokens) do
    target_chars = budget_tokens * 4
    String.slice(text, -target_chars, target_chars)
  end

  # ============================================================================
  # Private Helpers - Fact Extraction
  # ============================================================================

  defp extract_facts_from_messages(%{multi_layer: true} = window, messages) do
    texts =
      Enum.map(messages, fn msg ->
        msg[:content] || msg["content"] || ""
      end)
      |> Enum.filter(&(String.length(&1) > 0))

    opts =
      [
        agent_id: window.agent_id,
        sensitivity: Map.get(window, :sensitivity, :restricted),
        source: "compression_cycle_#{window.compression_count}",
        min_confidence: window.min_fact_confidence,
        receive_timeout: compression_llm_timeout(),
        method: fact_extraction_method(window)
      ]
      |> maybe_add_llm_opt(:model, window.fact_extraction_model)
      |> maybe_add_llm_opt(:provider, window.fact_extraction_provider)

    result =
      with {:ok, opts} <- Arbor.LLM.carry_sensitivity(messages, opts) do
        FactExtractor.extract_batch(texts, opts)
      end

    case result do
      facts when is_list(facts) ->
        # Filter by confidence threshold
        filtered =
          Enum.filter(facts, fn f ->
            (f[:confidence] || f.confidence || 1.0) >= window.min_fact_confidence
          end)

        {:ok, filtered}

      _ ->
        {:ok, []}
    end
  rescue
    e -> {:error, {:fact_extraction_error, e}}
  end

  # When no extraction model/provider is configured, stay hermetic and use
  # regex so compression does not silently hit the default LLM lane.
  defp fact_extraction_method(%{fact_extraction_model: nil, fact_extraction_provider: nil}),
    do: :regex

  defp fact_extraction_method(_window), do: :auto

  defp ingest_one_extracted_fact(agent_id, fact) when is_map(fact) do
    content = fact_field(fact, :content)

    if is_binary(content) and content != "" do
      # Knowledge-graph codec rejects atoms outside @semantic_atoms.
      # Extensible metadata must stay JSON-clean (string keys/values).
      fact_data = %{
        content: content,
        confidence: fact_field(fact, :confidence) || 0.5,
        source: stringify_metadata_value(fact_field(fact, :source)) || "compression",
        metadata: %{
          "category" => stringify_metadata_value(fact_field(fact, :category)),
          "entities" => stringify_metadata_list(fact_field(fact, :entities)),
          "ingested_from" => "fact_extractor"
        }
      }

      case GraphOps.add_pending_fact(agent_id, fact_data) do
        {:ok, _pending_id} ->
          :ok

        {:error, reason} ->
          Logger.debug("Fact ingest skipped during compression",
            agent_id: agent_id,
            reason: inspect(reason)
          )

          :ok
      end
    else
      :ok
    end
  end

  defp ingest_one_extracted_fact(_agent_id, _fact), do: :ok

  defp fact_field(fact, key) when is_map(fact) and is_atom(key) do
    Map.get(fact, key) || Map.get(fact, Atom.to_string(key))
  end

  defp stringify_metadata_value(nil), do: nil
  defp stringify_metadata_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_metadata_value(value) when is_binary(value), do: value
  defp stringify_metadata_value(value) when is_number(value) or is_boolean(value), do: value
  defp stringify_metadata_value(_value), do: nil

  defp stringify_metadata_list(values) when is_list(values) do
    Enum.flat_map(values, fn
      value when is_binary(value) -> [value]
      value when is_atom(value) -> [Atom.to_string(value)]
      _ -> []
    end)
  end

  defp stringify_metadata_list(_values), do: []

  # ============================================================================
  # Private Helpers - Deduplication
  # ============================================================================

  defp context_exceeds_similarity?(ctx, new_embedding) do
    embedding = ctx[:embedding] || compute_context_embedding(ctx)

    case embedding do
      nil ->
        false

      existing_embedding ->
        cosine_similarity(new_embedding, existing_embedding) >= @retrieved_dedup_threshold
    end
  end

  defp compute_context_embedding(ctx) do
    existing_content = ctx[:content] || ctx["content"] || ""

    with {:ok, opts} <- Arbor.LLM.carry_sensitivity(ctx, []) do
      compute_embedding(existing_content, opts)
    else
      _ -> nil
    end
  end

  defp compute_embedding(content, opts) when is_binary(content) and byte_size(content) > 0 do
    if embedding_service_available?() do
      case Arbor.AI.embed(content, opts) do
        {:ok, %{embedding: embedding}} -> embedding
        _ -> nil
      end
    else
      nil
    end
  end

  defp compute_embedding(_, _opts), do: nil

  defp embedding_service_available? do
    # Config-gated so the hermetic test lane never reaches a live embedding
    # backend (Ollama); see config :arbor_memory, :embedding_service_enabled.
    Application.get_env(:arbor_memory, :embedding_service_enabled, true) and
      LazyLoader.exported?(Arbor.AI, :embed, 2)
  end

  defp cosine_similarity(emb1, emb2) when is_list(emb1) and is_list(emb2) do
    dot = Enum.zip(emb1, emb2) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    norm1 = :math.sqrt(Enum.reduce(emb1, 0.0, fn x, acc -> acc + x * x end))
    norm2 = :math.sqrt(Enum.reduce(emb2, 0.0, fn x, acc -> acc + x * x end))

    if norm1 > 0 and norm2 > 0 do
      dot / (norm1 * norm2)
    else
      0.0
    end
  end

  defp cosine_similarity(_, _), do: 0.0
end
