defmodule Arbor.Memory.ActionPatterns do
  @moduledoc """
  Detect patterns in tool usage history.

  Analyzes sequences of tool calls to identify recurring patterns,
  failure-then-success sequences, and workflow learnings.

  ## Pattern Types

  1. **Repeated Sequences** - Tool combos that occur 3+ times (e.g., Read→Edit→Write)
  2. **Failure-then-Success** - Tool fails, different tool succeeds
  3. **Long Sequences** - 5+ tools in quick succession (within 30-sec windows)

  ## Usage

  Action history is a list of action records, typically from Historian or
  a session log. Each record should have at minimum:
  - `:tool` - Tool name (string)
  - `:status` - `:success` or `:error`
  - `:timestamp` - When the action occurred

  ## Examples

      history = [
        %{tool: "Read", status: :success, timestamp: ~U[2024-01-01 10:00:00Z]},
        %{tool: "Edit", status: :success, timestamp: ~U[2024-01-01 10:00:05Z]},
        %{tool: "Read", status: :success, timestamp: ~U[2024-01-01 10:01:00Z]},
        %{tool: "Edit", status: :success, timestamp: ~U[2024-01-01 10:01:05Z]}
      ]

      patterns = Arbor.Memory.ActionPatterns.analyze(history)
      # => [%{type: :repeated_sequence, tools: ["Read", "Edit"], occurrences: 2, confidence: 0.6}]
  """

  alias Arbor.Memory.{KnowledgeGraph, Proposal, Signals}

  @type action :: %{
          required(:tool) => String.t(),
          required(:status) => :success | :error,
          required(:timestamp) => DateTime.t(),
          optional(:params) => map(),
          optional(:result) => term()
        }

  @type pattern :: %{
          type: :repeated_sequence | :failure_then_success | :long_sequence,
          tools: [String.t()],
          occurrences: non_neg_integer(),
          confidence: float()
        }

  # Pattern detection thresholds
  @min_sequence_length 2
  @max_sequence_length 4
  @min_occurrences 3
  @long_sequence_threshold 5
  @long_sequence_window_seconds 30
  @failure_success_window_seconds 60

  # Graph ETS table
  @graph_ets :arbor_memory_graphs

  # ============================================================================
  # Main Analysis Function
  # ============================================================================

  @doc """
  Analyze action history for patterns.

  Returns a list of detected patterns sorted by confidence.

  ## Options

  - `:min_occurrences` - Minimum times a sequence must occur (default: 3)
  - `:min_sequence_length` - Minimum tools in a sequence (default: 2)
  - `:max_sequence_length` - Maximum tools in a sequence (default: 4)

  ## Examples

      patterns = ActionPatterns.analyze(history)
  """
  @spec analyze([action()], keyword()) :: [pattern()]
  def analyze(action_history, opts \\ []) do
    if length(action_history) < 2 do
      []
    else
      min_occurrences = Keyword.get(opts, :min_occurrences, @min_occurrences)
      min_seq_len = Keyword.get(opts, :min_sequence_length, @min_sequence_length)
      max_seq_len = Keyword.get(opts, :max_sequence_length, @max_sequence_length)

      repeated = detect_repeated_sequences(action_history, min_seq_len, max_seq_len, min_occurrences)
      failures = detect_failure_then_success(action_history)
      long = detect_long_sequences(action_history)

      (repeated ++ failures ++ long)
      |> Enum.sort_by(& &1.confidence, :desc)
    end
  end

  # ============================================================================
  # Repeated Sequence Detection
  # ============================================================================

  @doc """
  Detect repeated tool sequences.

  Finds tool combinations that occur multiple times in the history.
  """
  @spec detect_repeated_sequences([action()], non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          [pattern()]
  def detect_repeated_sequences(history, min_len \\ @min_sequence_length, max_len \\ @max_sequence_length, min_occurs \\ @min_occurrences) do
    tools = Enum.map(history, & &1.tool)

    min_len..max_len
    |> Enum.flat_map(fn seq_len ->
      find_sequences_of_length(tools, seq_len, min_occurs)
    end)
    |> Enum.uniq_by(& &1.tools)
  end

  defp find_sequences_of_length(tools, seq_len, min_occurs) do
    if length(tools) < seq_len do
      []
    else
      # Extract all sequences of the given length
      sequences =
        tools
        |> Enum.chunk_every(seq_len, 1, :discard)
        |> Enum.frequencies()
        |> Enum.filter(fn {_seq, count} -> count >= min_occurs end)
        |> Enum.map(fn {seq, count} ->
          %{
            type: :repeated_sequence,
            tools: seq,
            occurrences: count,
            confidence: calculate_sequence_confidence(count, seq_len, length(tools))
          }
        end)

      sequences
    end
  end

  defp calculate_sequence_confidence(occurrences, seq_len, total_actions) do
    # More occurrences and longer sequences = higher confidence
    base = occurrences / max(1, total_actions / seq_len)
    length_bonus = (seq_len - 1) * 0.1
    Float.round(min(1.0, base + length_bonus), 2)
  end

  # ============================================================================
  # Failure-then-Success Detection
  # ============================================================================

  @doc """
  Detect failure-then-success patterns.

  Finds cases where a tool fails and a different tool succeeds shortly after.
  These patterns often indicate workflow learnings.
  """
  @spec detect_failure_then_success([action()]) :: [pattern()]
  def detect_failure_then_success(history) do
    history
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [first, second] ->
      first.status == :error and
        second.status == :success and
        first.tool != second.tool and
        within_window?(first.timestamp, second.timestamp, @failure_success_window_seconds)
    end)
    |> Enum.map(fn [failed, succeeded] ->
      %{
        type: :failure_then_success,
        tools: [failed.tool, succeeded.tool],
        occurrences: 1,
        confidence: 0.7
      }
    end)
    |> consolidate_failure_patterns()
  end

  defp consolidate_failure_patterns(patterns) do
    patterns
    |> Enum.group_by(& &1.tools)
    |> Enum.map(fn {tools, instances} ->
      count = length(instances)

      %{
        type: :failure_then_success,
        tools: tools,
        occurrences: count,
        confidence: min(1.0, 0.5 + count * 0.15)
      }
    end)
    |> Enum.filter(&(&1.occurrences >= 2))
  end

  # ============================================================================
  # Long Sequence Detection
  # ============================================================================

  @doc """
  Detect long sequences of rapid tool usage.

  Finds bursts of 5+ tools within a short time window, which may
  indicate complex workflows or exploration patterns.
  """
  @spec detect_long_sequences([action()]) :: [pattern()]
  def detect_long_sequences(history) do
    if length(history) < @long_sequence_threshold do
      []
    else
      find_rapid_bursts(history, @long_sequence_threshold, @long_sequence_window_seconds)
    end
  end

  defp find_rapid_bursts(history, min_tools, window_seconds) do
    history
    |> Enum.with_index()
    |> Enum.reduce([], fn {action, idx}, acc ->
      # Look ahead to find sequences starting at this action
      remaining = Enum.drop(history, idx)
      sequence = take_within_window(remaining, action.timestamp, window_seconds)

      if length(sequence) >= min_tools do
        pattern = %{
          type: :long_sequence,
          tools: Enum.map(sequence, & &1.tool),
          occurrences: 1,
          confidence: min(1.0, 0.5 + (length(sequence) - min_tools) * 0.1)
        }

        [pattern | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
    |> deduplicate_overlapping_sequences()
  end

  defp take_within_window(actions, start_time, window_seconds) do
    Enum.take_while(actions, fn action ->
      within_window?(start_time, action.timestamp, window_seconds)
    end)
  end

  defp deduplicate_overlapping_sequences(sequences) do
    # Keep only non-overlapping sequences (prefer longer ones)
    sequences
    |> Enum.sort_by(fn s -> length(s.tools) end, :desc)
    |> Enum.reduce([], fn seq, acc ->
      tools_set = MapSet.new(seq.tools)

      overlaps? =
        Enum.any?(acc, fn kept ->
          kept_set = MapSet.new(kept.tools)
          overlap_size = MapSet.intersection(tools_set, kept_set) |> MapSet.size()
          overlap_size > length(seq.tools) / 2
        end)

      if overlaps?, do: acc, else: [seq | acc]
    end)
    |> Enum.reverse()
  end

  # ============================================================================
  # Learning Synthesis
  # ============================================================================

  @doc """
  Synthesize human-readable learnings from detected patterns.

  ## Options

  - `:use_llm` - Whether to use LLM for synthesis (default: false, falls back to templates)

  ## Examples

      learnings = ActionPatterns.synthesize_learnings(patterns)
      # => ["When editing files, I often Read first then Edit", ...]
  """
  @spec synthesize_learnings([pattern()], keyword()) :: [String.t()]
  def synthesize_learnings(patterns, opts \\ []) do
    use_llm = Keyword.get(opts, :use_llm, false)

    if use_llm do
      synthesize_with_llm(patterns)
    else
      synthesize_with_templates(patterns)
    end
  end

  defp synthesize_with_templates(patterns) do
    Enum.map(patterns, &pattern_to_learning/1)
  end

  defp pattern_to_learning(%{type: :repeated_sequence, tools: tools, occurrences: count}) do
    tool_chain = Enum.join(tools, " → ")

    "Workflow pattern: #{tool_chain} (observed #{count} times). " <>
      "This sequence appears to be a common workflow."
  end

  defp pattern_to_learning(%{type: :failure_then_success, tools: [failed, succeeded], occurrences: count}) do
    "Recovery pattern: When #{failed} fails, #{succeeded} often succeeds (#{count} occurrences). " <>
      "Consider trying #{succeeded} directly in similar situations."
  end

  defp pattern_to_learning(%{type: :long_sequence, tools: tools}) do
    "Complex workflow detected: #{length(tools)} tools used in rapid succession. " <>
      "This may indicate an exploratory or debugging session."
  end

  defp synthesize_with_llm(_patterns) do
    # Placeholder for LLM integration
    # In Phase 5+, this would call arbor_ai to generate more nuanced learnings
    []
  end

  # ============================================================================
  # Integration with Knowledge Graph
  # ============================================================================

  @doc """
  Analyze action history and queue learnings for agent review.

  Main integration point: analyze → synthesize → create proposals.

  ## Examples

      {:ok, proposals} = ActionPatterns.analyze_and_queue("agent_001", history)
  """
  @spec analyze_and_queue(String.t(), [action()], keyword()) ::
          {:ok, [Proposal.t()]} | {:error, term()}
  def analyze_and_queue(agent_id, action_history, opts \\ []) do
    patterns = analyze(action_history, opts)

    if patterns == [] do
      {:ok, []}
    else
      learnings = synthesize_learnings(patterns, opts)

      proposals =
        patterns
        |> Enum.zip(learnings)
        |> Enum.map(fn {pattern, learning} ->
          create_proposal(agent_id, pattern, learning)
        end)
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, proposal} -> proposal end)

      # Emit signal for detected patterns
      Enum.each(patterns, fn pattern ->
        Signals.emit_pattern_detected(agent_id, pattern)
      end)

      {:ok, proposals}
    end
  end

  defp create_proposal(agent_id, pattern, learning) do
    Proposal.create(agent_id, :learning, %{
      content: learning,
      confidence: pattern.confidence,
      source: "action_patterns",
      evidence: [
        "Pattern type: #{pattern.type}",
        "Tools: #{Enum.join(pattern.tools, ", ")}",
        "Occurrences: #{pattern.occurrences}"
      ],
      metadata: %{
        pattern_type: pattern.type,
        tools: pattern.tools,
        occurrences: pattern.occurrences
      }
    })
  end

  # ============================================================================
  # Legacy KnowledgeGraph Integration
  # ============================================================================

  @doc """
  Add learnings directly to KnowledgeGraph pending queue.

  This is the legacy integration path. Prefer `analyze_and_queue/3` which
  uses the unified Proposal system.
  """
  @spec add_to_pending_learnings(String.t(), [pattern()], keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def add_to_pending_learnings(agent_id, patterns, opts \\ []) do
    learnings = synthesize_learnings(patterns, opts)

    case get_graph(agent_id) do
      {:ok, graph} ->
        {final_graph, pending_ids} =
          patterns
          |> Enum.zip(learnings)
          |> Enum.reduce({graph, []}, fn {pattern, learning}, {g, ids} ->
            {:ok, new_g, pending_id} =
              KnowledgeGraph.add_pending_learning(g, %{
                content: learning,
                confidence: pattern.confidence,
                source: "action_patterns",
                metadata: %{
                  pattern_type: pattern.type,
                  tools: pattern.tools
                }
              })

            {new_g, [pending_id | ids]}
          end)

        save_graph(agent_id, final_graph)
        {:ok, Enum.reverse(pending_ids)}

      error ->
        error
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp within_window?(t1, t2, seconds) do
    abs(DateTime.diff(t1, t2, :second)) <= seconds
  end

  defp get_graph(agent_id) do
    case :ets.lookup(@graph_ets, agent_id) do
      [{^agent_id, graph}] -> {:ok, graph}
      [] -> {:error, :graph_not_initialized}
    end
  end

  defp save_graph(agent_id, graph) do
    :ets.insert(@graph_ets, {agent_id, graph})
    :ok
  end
end
