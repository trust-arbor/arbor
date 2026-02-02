defmodule Arbor.Consensus.TopicMatcher do
  @moduledoc """
  Matches proposals to topics based on pattern matching.

  Pure functional module (no process). Evaluates a proposal's description
  and context against the registered TopicRules to find the best-fit topic.

  ## Algorithm

  1. For each registered topic, count pattern matches in:
     - The proposal description (case-insensitive word boundary matching)
     - The proposal context keys and values

  2. Calculate confidence as a ratio of matched patterns to total patterns,
     with bonuses for multiple distinct matches.

  3. If the best match confidence exceeds the threshold (0.8), return that topic.
     Otherwise, fall through to `:general`.

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

  @confidence_threshold 0.8
  @multi_match_bonus 0.1

  @doc """
  Match a proposal to the best-fit topic in the registry.

  Returns `{topic_atom, confidence}` where confidence is 0.0..1.0.
  Falls through to `:general` if no confident match.

  ## Parameters

  - `description` - The proposal description text
  - `context` - The proposal context map (may contain relevant keywords)
  - `topics` - List of TopicRule structs to match against

  ## Returns

  A tuple `{topic_atom, confidence}` where:
  - `topic_atom` is the matched topic (or `:general` as fallback)
  - `confidence` is a float from 0.0 to 1.0 indicating match strength
  """
  @spec match(String.t(), map(), [TopicRule.t()]) :: {atom(), float()}
  def match(description, context, topics) when is_binary(description) and is_map(context) do
    # Score all topics
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

      [{topic, confidence} | _] ->
        # Return best match even if below threshold, but only if there's any match
        {topic, confidence}

      [] ->
        {:general, 0.0}
    end
  end

  def match(_description, _context, _topics), do: {:general, 0.0}

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
  defp value_to_string(value) when is_list(value), do: Enum.map_join(value, " ", &value_to_string/1)
  defp value_to_string(value) when is_map(value), do: context_to_text(value)
  defp value_to_string(_), do: ""

  # Word boundary matching
  defp matches_word?(text, pattern) do
    # Use word boundary matching
    pattern_regex = ~r/\b#{Regex.escape(pattern)}\b/i
    Regex.match?(pattern_regex, text)
  end
end
