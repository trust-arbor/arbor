defmodule Arbor.Consensus.Coordinator.TopicRouting do
  @moduledoc """
  Topic-driven routing and organic topic creation for the Coordinator.

  Handles matching proposals to topics via TopicMatcher, resolving council
  configuration from TopicRegistry, and organic topic detection from routing
  statistics.
  """

  alias Arbor.Consensus.Coordinator.Voting
  alias Arbor.Consensus.{TopicMatcher, TopicRegistry, TopicRule}
  alias Arbor.Contracts.Consensus.Proposal

  require Logger

  # ============================================================================
  # Topic Matching & Routing
  # ============================================================================

  @doc """
  Route proposals via TopicMatcher when topic is :general or not explicitly set.
  If the proposal already has a specific topic AND TopicRegistry has a rule for it,
  use that topic directly. Otherwise, run TopicMatcher to find best fit.
  """
  def maybe_route_via_topic_matcher(proposal) do
    # If topic is explicitly set (not :general) and exists in registry, use it
    if proposal.topic != :general and topic_exists_in_registry?(proposal.topic) do
      {:ok, proposal}
    else
      # Run TopicMatcher to find best-fit topic
      {matched_topic, confidence} = match_topic(proposal)

      # Update proposal with matched topic and store routing metadata
      updated_proposal = %{
        proposal
        | topic: matched_topic,
          metadata:
            Map.merge(proposal.metadata, %{
              routing_confidence: confidence,
              original_topic: proposal.topic,
              routed_by: :topic_matcher
            })
      }

      {:ok, updated_proposal}
    end
  end

  @doc """
  Resolve council configuration from TopicRegistry.
  Advisory mode proposals get quorum of nil (collect all perspectives).
  Returns {evaluators, quorum} where evaluators is a list of modules.
  """
  def resolve_council_config(proposal, _config) do
    topic = proposal.topic

    case TopicRegistry.get(topic) do
      {:ok, rule} ->
        resolve_from_topic_rule(proposal, rule)

      {:error, :not_found} ->
        # Topic not in registry -- use default evaluator (RuleBased)
        Logger.warning("Topic #{inspect(topic)} not found in TopicRegistry, using defaults")
        default_evaluators_and_quorum(proposal)
    end
  rescue
    # TopicRegistry not running -- fall back to defaults
    _ ->
      default_evaluators_and_quorum(proposal)
  end

  @doc """
  Get quorum for a proposal by recalculating from its topic.
  """
  def get_proposal_quorum(state, proposal_id) do
    case Map.get(state.proposals, proposal_id) do
      nil ->
        nil

      proposal ->
        {_evaluators, quorum} = resolve_council_config(proposal, state.config)
        quorum
    end
  end

  # ============================================================================
  # Organic Topic Creation (Phase 5)
  # ============================================================================

  @organic_topic_threshold 5
  @organic_check_interval 10
  @max_tracked_patterns 100
  @stats_max_age_days 30
  @max_descriptions_per_pattern 10

  @doc """
  Track when proposals route to :general for organic topic detection.
  """
  def track_routing_stats(state, proposal) do
    if proposal.topic == :general do
      keywords = extract_keywords(proposal.description)
      now = DateTime.utc_now()

      routing_stats =
        Enum.reduce(keywords, state.routing_stats, fn keyword, stats ->
          Map.update(
            stats,
            keyword,
            %{count: 1, last_seen: now, descriptions: [proposal.description]},
            &update_routing_stat_entry(&1, now, proposal.description)
          )
        end)

      # Prune old and excess entries
      routing_stats = prune_routing_stats(routing_stats, now)

      new_count = state.general_route_count + 1

      state = %{state | routing_stats: routing_stats, general_route_count: new_count}

      # Check for organic topic patterns periodically
      if rem(new_count, @organic_check_interval) == 0 do
        check_organic_topics(state)
      else
        state
      end
    else
      state
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Check if topic exists in TopicRegistry
  defp topic_exists_in_registry?(topic) do
    case TopicRegistry.get(topic) do
      {:ok, _rule} -> true
      {:error, :not_found} -> false
    end
  rescue
    # TopicRegistry may not be running
    _ -> false
  end

  # Match proposal to topic via TopicMatcher
  defp match_topic(proposal) do
    topics = get_all_topic_rules()

    if topics == [] do
      # No registry available, keep existing topic
      {proposal.topic, 0.0}
    else
      TopicMatcher.match(
        proposal.description,
        proposal.context,
        topics
      )
    end
  end

  # Get all topic rules from registry
  defp get_all_topic_rules do
    TopicRegistry.list()
  rescue
    # TopicRegistry may not be running
    _ -> []
  end

  defp default_evaluators_and_quorum(proposal) do
    # Use RuleBased as the default evaluator (preserves existing behavior)
    evaluators = [Arbor.Consensus.Evaluator.RuleBased]

    quorum =
      if proposal.mode == :advisory,
        do: nil,
        else: Arbor.Contracts.Consensus.Protocol.standard_quorum()

    {evaluators, quorum}
  end

  # Resolve council config from TopicRule
  defp resolve_from_topic_rule(proposal, rule) do
    # Get evaluators from the rule, or fall back to RuleBased
    evaluators =
      case rule.required_evaluators do
        [] ->
          # No evaluators specified in rule, use default
          [Arbor.Consensus.Evaluator.RuleBased]

        required ->
          required
      end

    # Calculate quorum based on the total perspectives from all evaluators
    perspectives =
      Voting.resolve_perspectives_from_evaluators(evaluators)

    quorum =
      if proposal.mode == :advisory do
        nil
      else
        council_size = length(perspectives)
        TopicRule.quorum_to_number(rule.min_quorum, council_size)
      end

    {evaluators, quorum}
  end

  defp update_routing_stat_entry(entry, now, description) do
    descriptions =
      Enum.take(
        [description | entry.descriptions],
        @max_descriptions_per_pattern
      )

    %{entry | count: entry.count + 1, last_seen: now, descriptions: descriptions}
  end

  # Extract significant keywords from a description
  defp extract_keywords(description) do
    stop_words = ~w(the a an is are was were be been being have has had do does did
                     will would shall should may might can could of in to for on with
                     at by from this that it and or but not as if then than)

    description
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 in stop_words or String.length(&1) < 3))
    |> Enum.uniq()
  end

  # Prune routing stats: remove old entries and cap size
  defp prune_routing_stats(stats, now) do
    cutoff = DateTime.add(now, -@stats_max_age_days, :day)

    stats
    |> Enum.reject(fn {_keyword, entry} ->
      DateTime.compare(entry.last_seen, cutoff) == :lt
    end)
    |> Enum.sort_by(fn {_keyword, entry} -> entry.count end, :desc)
    |> Enum.take(@max_tracked_patterns)
    |> Map.new()
  end

  # Analyze routing stats for potential new topics
  defp check_organic_topics(state) do
    # Find keywords that appear frequently in :general-routed proposals
    candidates =
      state.routing_stats
      |> Enum.filter(fn {_keyword, entry} -> entry.count >= @organic_topic_threshold end)
      |> Enum.sort_by(fn {_keyword, entry} -> entry.count end, :desc)

    case candidates do
      [] ->
        state

      candidates ->
        # Group related keywords (those appearing in the same descriptions)
        topic_candidate = build_topic_candidate(candidates)
        propose_organic_topic(state, topic_candidate)
    end
  end

  # Build a topic candidate from frequently co-occurring keywords
  defp build_topic_candidate(candidates) do
    # Take top keywords as match patterns
    keywords = Enum.map(candidates, fn {keyword, _entry} -> keyword end)
    top_keywords = Enum.take(keywords, 5)

    # Build a suggested topic name as a string -- actual atom creation happens
    # if/when governance approves the topic via TopicRegistry
    {primary_keyword, _entry} = hd(candidates)
    topic_name = "organic_#{primary_keyword}"

    %{
      topic: topic_name,
      match_patterns: top_keywords,
      keyword_counts: Enum.map(Enum.take(candidates, 5), fn {k, e} -> {k, e.count} end)
    }
  end

  # Submit topic creation proposal to :topic_governance
  defp propose_organic_topic(state, candidate) do
    description =
      "Organic topic creation: #{candidate.topic}. " <>
        "Keywords #{inspect(candidate.match_patterns)} appeared frequently in " <>
        ":general-routed proposals (counts: #{inspect(candidate.keyword_counts)}). " <>
        "Suggesting dedicated topic for better routing."

    proposal_attrs = %{
      proposer: "coordinator:#{state.coordinator_id}",
      topic: :topic_governance,
      mode: :advisory,
      description: description,
      context: %{
        organic_topic: true,
        suggested_topic: candidate.topic,
        match_patterns: candidate.match_patterns,
        keyword_counts: candidate.keyword_counts
      },
      metadata: %{source: :organic_topic_detection}
    }

    # Submit internally via a Task to avoid blocking.
    # Capture the coordinator pid before spawning the Task.
    coordinator_pid = self()

    Task.start(fn ->
      case Proposal.new(proposal_attrs) do
        {:ok, proposal} ->
          try do
            GenServer.call(coordinator_pid, {:submit, proposal, []})
          catch
            :exit, _ ->
              Logger.debug("Organic topic proposal submission failed (coordinator busy)")
          end

        {:error, reason} ->
          Logger.warning("Failed to create organic topic proposal: #{inspect(reason)}")
      end
    end)

    # Reset the general route count to avoid re-proposing
    %{state | general_route_count: 0}
  rescue
    e ->
      Logger.warning("Organic topic creation error: #{inspect(e)}")
      state
  end
end
