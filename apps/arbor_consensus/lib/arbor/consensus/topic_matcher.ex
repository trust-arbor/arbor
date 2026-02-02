defmodule Arbor.Consensus.TopicMatcher do
  @moduledoc """
  Matches proposals to topics based on pattern matching with optional LLM fallback.

  Pure functional module (no process). Evaluates a proposal's description
  and context against the registered TopicRules to find the best-fit topic.

  ## Algorithm

  1. For each registered topic, count pattern matches in:
     - The proposal description (case-insensitive word boundary matching)
     - The proposal context keys and values

  2. Calculate confidence as a ratio of matched patterns to total patterns,
     with bonuses for multiple distinct matches.

  3. If the best match confidence exceeds the threshold (0.8), return that topic.

  4. If below threshold and LLM classification is enabled, ask an LLM to classify
     the proposal. If the LLM fails or is disabled, fall through to `:general`.

  ## Options

  - `:llm_enabled` — whether to use LLM fallback (default: `true` when Arbor.AI is available)
  - `:ai_module` — the AI module to use for LLM classification (default: `Arbor.AI`)

  ## Examples

      # Match a security-related proposal
      iex> topics = [
      ...>   %TopicRule{topic: :security, match_patterns: ["security", "vulnerability", "audit"]},
      ...>   %TopicRule{topic: :general, match_patterns: []}
      ...> ]
      iex> TopicMatcher.match("Security audit for authentication module", %{}, topics)
      {:security, 0.33}  # One match out of 3 patterns

      # Fall through to :general
      iex> TopicMatcher.match("Random unrelated change", %{}, topics)
      {:general, 0.0}

  """

  alias Arbor.Consensus.TopicRule

  require Logger

  @confidence_threshold 0.8
  @multi_match_bonus 0.1

  @doc """
  Match a proposal to the best-fit topic in the registry.

  Returns `{topic_atom, confidence}` where confidence is 0.0..1.0.
  Falls through to `:general` if no confident match.

  Uses LLM classification as fallback when pattern matching confidence is below
  the threshold. Pass `llm_enabled: false` to disable.

  ## Parameters

  - `description` - The proposal description text
  - `context` - The proposal context map (may contain relevant keywords)
  - `topics` - List of TopicRule structs to match against
  - `opts` - Options (see module docs)

  ## Returns

  A tuple `{topic_atom, confidence}` where:
  - `topic_atom` is the matched topic (or `:general` as fallback)
  - `confidence` is a float from 0.0 to 1.0 indicating match strength
  """
  @spec match(String.t(), map(), [TopicRule.t()], keyword()) :: {atom(), float()}
  def match(description, context, topics, opts \\ [])

  def match(description, context, topics, opts)
      when is_binary(description) and is_map(context) do
    # Score all topics via pattern matching
    scores =
      topics
      |> Enum.reject(&(&1.topic == :general))
      |> Enum.map(fn topic_rule ->
        {topic_rule.topic, score_topic(description, context, topic_rule)}
      end)
      |> Enum.filter(fn {_topic, score} -> score > 0.0 end)
      |> Enum.sort_by(fn {_topic, score} -> score end, :desc)

    case scores do
      [{topic, confidence} | _] when confidence >= @confidence_threshold ->
        {topic, confidence}

      pattern_result ->
        # Pattern match below threshold — try LLM classification if enabled
        maybe_llm_classify(description, context, topics, pattern_result, opts)
    end
  end

  def match(_description, _context, _topics, _opts), do: {:general, 0.0}

  @doc """
  Score how well a proposal matches a specific topic.

  Returns a float from 0.0 to 1.0.
  """
  @spec score_topic(String.t(), map(), TopicRule.t()) :: float()
  def score_topic(_description, _context, %TopicRule{match_patterns: []}), do: 0.0

  def score_topic(description, context, %TopicRule{match_patterns: patterns})
      when is_list(patterns) do
    # Normalize texts for matching
    normalized_desc = normalize_text(description)
    context_text = context_to_text(context)

    # Count matching patterns
    match_count = count_pattern_matches(patterns, normalized_desc, context_text)
    total_patterns = length(patterns)

    calculate_confidence(match_count, total_patterns)
  end

  defp count_pattern_matches(patterns, normalized_desc, context_text) do
    patterns
    |> Enum.count(fn pattern ->
      normalized_pattern = normalize_text(pattern)

      matches_word?(normalized_desc, normalized_pattern) or
        matches_word?(context_text, normalized_pattern)
    end)
  end

  defp calculate_confidence(0, _total), do: 0.0

  defp calculate_confidence(match_count, total_patterns) do
    # Base confidence from match ratio
    base_confidence = match_count / total_patterns
    # Bonus for multiple matches (cap at 1.0)
    bonus = if match_count > 1, do: (match_count - 1) * @multi_match_bonus, else: 0.0
    min(base_confidence + bonus, 1.0)
  end

  # ============================================================================
  # LLM Classification
  # ============================================================================

  defp maybe_llm_classify(description, context, topics, pattern_result, opts) do
    llm_enabled = Keyword.get(opts, :llm_enabled, llm_available?())

    if llm_enabled do
      case llm_classify(description, context, topics, opts) do
        {:ok, topic, confidence} when confidence >= @confidence_threshold ->
          {topic, confidence}

        {:ok, _topic, _confidence} ->
          # LLM returned low confidence too, use best pattern match or :general
          fallback_from_pattern(pattern_result)

        {:error, _reason} ->
          fallback_from_pattern(pattern_result)
      end
    else
      fallback_from_pattern(pattern_result)
    end
  end

  defp fallback_from_pattern([{topic, confidence} | _]), do: {topic, confidence}
  defp fallback_from_pattern([]), do: {:general, 0.0}

  defp llm_classify(description, context, topics, opts) do
    ai_module = Keyword.get(opts, :ai_module, Arbor.AI)
    non_general_topics = Enum.reject(topics, &(&1.topic == :general))

    if non_general_topics == [] do
      {:error, :no_topics_to_classify}
    else
      prompt = build_classification_prompt(description, context, non_general_topics)

      case ai_module.generate_text(prompt,
             system_prompt: classification_system_prompt(),
             temperature: 0.1,
             max_tokens: 200
           ) do
        {:ok, %{text: text}} ->
          parse_classification_response(text, non_general_topics)

        {:error, reason} ->
          Logger.warning("TopicMatcher LLM classification failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  rescue
    e ->
      Logger.warning("TopicMatcher LLM classification error: #{inspect(e)}")
      {:error, {:exception, e}}
  end

  defp classification_system_prompt do
    """
    You are a topic classifier for a consensus system. Given a proposal description \
    and available topics, determine the best-fit topic. Respond ONLY with a JSON object, \
    no other text. Format: {"topic": "topic_name", "confidence": 0.85, "reasoning": "brief explanation"}\
    """
  end

  defp build_classification_prompt(description, context, topics) do
    topic_descriptions =
      Enum.map_join(topics, "\n", fn rule ->
        patterns = Enum.join(rule.match_patterns, ", ")
        "- #{rule.topic}: keywords=[#{patterns}]"
      end)

    context_str =
      if context == %{} do
        "none"
      else
        Enum.map_join(context, ", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)
      end

    """
    Classify this proposal into the best-fit topic.

    Available topics:
    #{topic_descriptions}

    Proposal description: #{description}
    Proposal context: #{context_str}

    Respond with JSON: {"topic": "topic_name", "confidence": 0.0-1.0, "reasoning": "brief reason"}
    """
  end

  defp parse_classification_response(text, available_topics) do
    # Extract JSON from the response (may have surrounding text)
    case extract_json(text) do
      {:ok, %{"topic" => topic_str, "confidence" => confidence}} when is_number(confidence) ->
        validate_classified_topic(topic_str, confidence, available_topics)

      {:ok, _other} ->
        Logger.warning("TopicMatcher LLM returned unexpected JSON structure")
        {:error, :invalid_response}

      {:error, reason} ->
        Logger.warning("TopicMatcher LLM response parse failed: #{inspect(reason)}")
        {:error, :parse_failed}
    end
  end

  defp validate_classified_topic(topic_str, confidence, available_topics) do
    available_names = Enum.map(available_topics, &Atom.to_string(&1.topic))

    if topic_str in available_names do
      # Safe atom conversion — only convert to atoms that already exist in the topic list
      topic_atom =
        available_topics
        |> Enum.find(&(Atom.to_string(&1.topic) == topic_str))
        |> Map.fetch!(:topic)

      {:ok, topic_atom, min(max(confidence, 0.0), 1.0)}
    else
      Logger.warning("TopicMatcher LLM returned unknown topic: #{topic_str}")
      {:error, :unknown_topic}
    end
  end

  defp extract_json(text) do
    # Try to find JSON object in the text
    case Regex.run(~r/\{[^}]+\}/s, text) do
      [json_str] ->
        case Jason.decode(json_str) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, :json_decode_failed}
        end

      nil ->
        {:error, :no_json_found}
    end
  end

  defp llm_available? do
    Code.ensure_loaded?(Arbor.AI) and function_exported?(Arbor.AI, :generate_text, 2)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Normalize text for matching: lowercase, remove punctuation
  defp normalize_text(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize_text(_), do: ""

  # Convert context map to searchable text
  defp context_to_text(context) when is_map(context) do
    context
    |> Enum.flat_map(fn {key, value} ->
      key_str = to_string(key)
      value_str = value_to_string(value)
      [key_str, value_str]
    end)
    |> Enum.join(" ")
    |> normalize_text()
  end

  defp context_to_text(_), do: ""

  # Convert values to strings for searching
  defp value_to_string(value) when is_binary(value), do: value
  defp value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp value_to_string(value) when is_number(value), do: to_string(value)

  defp value_to_string(value) when is_list(value),
    do: Enum.map_join(value, " ", &value_to_string/1)

  defp value_to_string(value) when is_map(value), do: context_to_text(value)
  defp value_to_string(_), do: ""

  # Word boundary matching
  defp matches_word?(text, pattern) do
    # Use word boundary matching
    pattern_regex = ~r/\b#{Regex.escape(pattern)}\b/i
    Regex.match?(pattern_regex, text)
  end
end
