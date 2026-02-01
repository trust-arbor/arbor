defmodule Arbor.Memory.ReflectionProcessor do
  @moduledoc """
  Structured self-analysis for agents.

  ReflectionProcessor enables agents to perform structured reflection on their
  behavior, decisions, and growth. It uses LLM calls (via configurable module)
  to generate insights from the agent's context.

  ## LLM Integration

  The LLM module is configurable:

      config :arbor_memory, :reflection_llm_module, MyApp.LLMClient

  By default, a mock module is used that returns structured test data.

  ## Usage

      # Perform reflection with a prompt
      {:ok, reflection} = ReflectionProcessor.reflect("agent_001", "What patterns do I see in my recent work?")

      # Periodic reflection (called during heartbeats)
      {:ok, reflection} = ReflectionProcessor.periodic_reflection("agent_001")

      # Get past reflections
      {:ok, history} = ReflectionProcessor.history("agent_001")
  """

  alias Arbor.Memory.{Events, IdentityConsolidator, Signals}

  @type reflection :: %{
          id: String.t(),
          agent_id: String.t(),
          prompt: String.t(),
          analysis: String.t(),
          insights: [String.t()],
          self_assessment: map(),
          timestamp: DateTime.t()
        }

  # ETS table for reflection storage
  @reflections_ets :arbor_reflections

  # Maximum reflections to store per agent
  @max_reflections 100

  # ============================================================================
  # Main API
  # ============================================================================

  @doc """
  Perform a reflection with a specific prompt.

  This:
  1. Builds a reflection context from agent's SelfKnowledge and recent activity
  2. Calls the configured LLM module
  3. Parses the structured response
  4. Extracts insights
  5. Stores and returns the reflection

  ## Options

  - `:include_self_knowledge` - Include SelfKnowledge in context (default: true)
  - `:include_recent_activity` - Include recent activity summary (default: true)

  ## Examples

      {:ok, reflection} = ReflectionProcessor.reflect("agent_001", "How can I improve?")
  """
  @spec reflect(String.t(), String.t(), keyword()) :: {:ok, reflection()} | {:error, term()}
  def reflect(agent_id, prompt, opts \\ []) do
    include_sk = Keyword.get(opts, :include_self_knowledge, true)
    include_activity = Keyword.get(opts, :include_recent_activity, true)

    # Build context
    context = build_reflection_context(agent_id, include_sk, include_activity)

    # Get LLM module
    llm_module = get_llm_module()

    # Call LLM
    case llm_module.reflect(prompt, context) do
      {:ok, response} ->
        reflection = %{
          id: generate_id(),
          agent_id: agent_id,
          prompt: prompt,
          analysis: response.analysis,
          insights: response.insights,
          self_assessment: response.self_assessment,
          timestamp: DateTime.utc_now()
        }

        # Store reflection
        store_reflection(agent_id, reflection)

        # Emit events
        Signals.emit_cognitive_adjustment(agent_id, :reflection_completed, %{
          reflection_id: reflection.id,
          insight_count: length(reflection.insights)
        })

        Events.record_reflection_completed(agent_id, %{
          reflection_id: reflection.id,
          prompt: prompt,
          insight_count: length(reflection.insights)
        })

        {:ok, reflection}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Perform a periodic reflection based on recent activity.

  This is called during deeper heartbeats to reflect on recent work.
  Uses a standardized prompt focused on patterns and growth.

  ## Examples

      {:ok, reflection} = ReflectionProcessor.periodic_reflection("agent_001")
  """
  @spec periodic_reflection(String.t()) :: {:ok, reflection()} | {:error, term()}
  def periodic_reflection(agent_id) do
    prompt = """
    Reflect on my recent activity and patterns. Consider:
    - What tasks have I been focused on?
    - What patterns do I notice in my approach?
    - What have I learned or improved?
    - Are there areas where I could do better?
    """

    reflect(agent_id, prompt)
  end

  @doc """
  Get reflection history for an agent.

  ## Options

  - `:limit` - Maximum reflections to return (default: 10)
  - `:since` - Only reflections after this DateTime

  ## Examples

      {:ok, reflections} = ReflectionProcessor.history("agent_001")
      {:ok, recent} = ReflectionProcessor.history("agent_001", limit: 5)
  """
  @spec history(String.t(), keyword()) :: {:ok, [reflection()]}
  def history(agent_id, opts \\ []) do
    ensure_ets_exists()
    limit = Keyword.get(opts, :limit, 10)
    since = Keyword.get(opts, :since)

    reflections =
      case :ets.lookup(@reflections_ets, agent_id) do
        [{^agent_id, stored}] -> stored
        [] -> []
      end

    filtered =
      reflections
      |> maybe_filter_since(since)
      |> Enum.take(limit)

    {:ok, filtered}
  end

  # ============================================================================
  # Context Building
  # ============================================================================

  defp build_reflection_context(agent_id, include_sk, include_activity) do
    context = %{agent_id: agent_id}

    context =
      if include_sk do
        case IdentityConsolidator.get_self_knowledge(agent_id) do
          nil ->
            context

          sk ->
            Map.merge(context, %{
              capabilities:
                Enum.map(sk.capabilities, fn c ->
                  %{name: c.name, proficiency: c.proficiency}
                end),
              traits:
                Enum.map(sk.personality_traits, fn t ->
                  %{trait: t.trait, strength: t.strength}
                end),
              values:
                Enum.map(sk.values, fn v ->
                  %{value: v.value, importance: v.importance}
                end),
              recent_growth: Enum.take(sk.growth_log, 5)
            })
        end
      else
        context
      end

    context =
      if include_activity do
        # In a full implementation, this would query recent activity
        # For now, just note that activity is included
        Map.put(context, :activity_included, true)
      else
        context
      end

    context
  end

  # ============================================================================
  # Storage
  # ============================================================================

  defp store_reflection(agent_id, reflection) do
    ensure_ets_exists()

    existing =
      case :ets.lookup(@reflections_ets, agent_id) do
        [{^agent_id, stored}] -> stored
        [] -> []
      end

    updated =
      [reflection | existing]
      |> Enum.take(@max_reflections)

    :ets.insert(@reflections_ets, {agent_id, updated})
    :ok
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp get_llm_module do
    Application.get_env(:arbor_memory, :reflection_llm_module, __MODULE__.MockLLM)
  end

  defp generate_id do
    "refl_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp maybe_filter_since(reflections, nil), do: reflections

  defp maybe_filter_since(reflections, since) do
    Enum.filter(reflections, fn r ->
      DateTime.compare(r.timestamp, since) == :gt
    end)
  end

  defp ensure_ets_exists do
    if :ets.whereis(@reflections_ets) == :undefined do
      try do
        :ets.new(@reflections_ets, [:named_table, :public, :set])
      rescue
        ArgumentError -> :ok
      end
    end
  end

  # ============================================================================
  # Mock LLM Module
  # ============================================================================

  defmodule MockLLM do
    @moduledoc """
    Mock LLM module for testing and development.

    Returns structured test data without making actual LLM calls.
    """

    @doc """
    Mock reflection call that returns structured test data.
    """
    @spec reflect(String.t(), map()) :: {:ok, map()} | {:error, term()}
    def reflect(prompt, context) do
      # Generate mock response based on prompt content
      analysis = generate_mock_analysis(prompt, context)
      insights = generate_mock_insights(prompt, context)
      self_assessment = generate_mock_self_assessment(context)

      {:ok,
       %{
         analysis: analysis,
         insights: insights,
         self_assessment: self_assessment
       }}
    end

    defp generate_mock_analysis(prompt, context) do
      agent_id = Map.get(context, :agent_id, "unknown")

      cond do
        String.contains?(prompt, "pattern") ->
          "Analyzing patterns for agent #{agent_id}. " <>
            "The recent activity shows consistent engagement with structured tasks. " <>
            "There is a clear preference for methodical approaches."

        String.contains?(prompt, "improve") ->
          "Reflecting on improvement areas for agent #{agent_id}. " <>
            "Current strengths are being leveraged effectively. " <>
            "Some areas could benefit from increased attention to detail."

        true ->
          "General reflection for agent #{agent_id}. " <>
            "Current state is stable with ongoing growth in key areas."
      end
    end

    defp generate_mock_insights(prompt, _context) do
      base_insights = [
        "Consistent engagement with tasks shows dedication",
        "Pattern of thorough analysis before action"
      ]

      cond do
        String.contains?(prompt, "pattern") ->
          base_insights ++ ["Strong preference for structured approaches"]

        String.contains?(prompt, "improve") ->
          base_insights ++ ["Opportunity to expand capability range"]

        true ->
          base_insights
      end
    end

    defp generate_mock_self_assessment(context) do
      capabilities = Map.get(context, :capabilities, [])
      traits = Map.get(context, :traits, [])

      %{
        capability_confidence:
          if(length(capabilities) > 0,
            do: 0.7 + length(capabilities) * 0.02,
            else: 0.5
          ),
        trait_alignment:
          if(length(traits) > 0,
            do: 0.8,
            else: 0.6
          ),
        growth_trajectory: :stable,
        areas_for_focus: ["depth over breadth", "consistency"]
      }
    end
  end
end
