defmodule Arbor.Agent.Eval.TrialRunner do
  @moduledoc """
  Executes a single memory ablation trial.

  Creates a fresh agent, seeds standardized state, runs N heartbeats
  with tier-specific prompt section filtering, captures all raw LLM
  responses with metadata, and returns structured results.
  """

  alias Arbor.Agent.Eval.{Metrics, TrialConfig}
  alias Arbor.Agent.{HeartbeatPrompt, HeartbeatResponse}

  require Logger

  @default_heartbeats 10
  @default_model "google/gemini-3-flash-preview"
  @default_provider :openrouter

  @doc """
  Run a single trial for the given tier config.

  ## Options

    * `:heartbeats` - Number of heartbeats to run (default: 10)
    * `:model` - LLM model (default: gemini-3-flash-preview)
    * `:provider` - LLM provider (default: :openrouter)
    * `:run_id` - Parent eval run ID for persistence
    * `:trial_num` - Trial number within the run

  Returns `{:ok, %{agent_id, tier, results, metrics, seed}}` or `{:error, reason}`.
  """
  def run(tier_config, opts \\ []) do
    heartbeats = Keyword.get(opts, :heartbeats, @default_heartbeats)
    trial_num = Keyword.get(opts, :trial_num, 1)
    agent_id = "eval_#{tier_config.name}_t#{trial_num}_#{:erlang.unique_integer([:positive])}"

    Logger.info(
      "[MemoryAblation] Starting trial: tier=#{tier_config.tier} (#{tier_config.name}), " <>
        "agent=#{agent_id}, heartbeats=#{heartbeats}"
    )

    init_agent_memory(agent_id)

    try do
      seed = TrialConfig.seed_data()
      seed_agent_state(agent_id, seed, tier_config)

      results =
        Enum.reduce(1..heartbeats, [], fn beat, acc ->
          case run_heartbeat(agent_id, tier_config, beat, opts) do
            {:ok, result} ->
              apply_outputs(agent_id, result.parsed, tier_config)
              [result | acc]

            {:error, reason} ->
              Logger.warning(
                "[MemoryAblation] Heartbeat #{beat} failed: #{inspect(reason)}, continuing"
              )

              [
                %{heartbeat: beat, error: reason, parsed: HeartbeatResponse.empty_response()}
                | acc
              ]
          end
        end)
        |> Enum.reverse()

      metrics = Metrics.compute(results)

      {:ok,
       %{
         agent_id: agent_id,
         tier: tier_config.tier,
         tier_name: tier_config.name,
         results: results,
         metrics: metrics,
         seed: seed,
         heartbeat_count: heartbeats
       }}
    after
      cleanup_agent_memory(agent_id)
    end
  rescue
    e ->
      Logger.error("[MemoryAblation] Trial crashed: #{Exception.message(e)}")
      {:error, {:trial_crash, Exception.message(e)}}
  end

  # -- Heartbeat execution --

  defp run_heartbeat(agent_id, tier_config, beat, opts) do
    model = Keyword.get(opts, :model, @default_model)
    provider = Keyword.get(opts, :provider, @default_provider)

    # Build agent state for prompt construction
    state = build_agent_state(agent_id, tier_config, beat)

    # Build prompts
    prompt = HeartbeatPrompt.build_prompt(state)
    system = HeartbeatPrompt.system_prompt(state)

    # Call LLM with timing capture
    start_ms = System.monotonic_time(:millisecond)

    case call_llm(system, prompt, model: model, provider: provider) do
      {:ok, llm_meta} ->
        elapsed = System.monotonic_time(:millisecond) - start_ms
        parsed = HeartbeatResponse.parse(llm_meta.text)

        {:ok,
         %{
           heartbeat: beat,
           timestamp: DateTime.utc_now(),
           prompt: prompt,
           system_prompt: system,
           prompt_sections: tier_config.sections,
           llm_meta: Map.put(llm_meta, :timing_ms, elapsed),
           parsed: parsed,
           raw_text: llm_meta.text
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_agent_state(agent_id, tier_config, beat) do
    # Base state with agent ID and section filter
    state = %{
      agent_id: agent_id,
      id: agent_id,
      heartbeat_count: beat,
      cognitive_mode: select_mode(agent_id, beat),
      enabled_prompt_sections: tier_config.sections,
      pending_messages: [],
      background_suggestions: []
    }

    # Load context window when conversation section is enabled (all tiers in v2)
    if tier_config.sections == :all or :conversation in tier_config.sections do
      # Build a simple context window from chat history
      chat = load_chat_history(agent_id)

      if chat != [] do
        window = %{
          entries:
            Enum.map(chat, fn msg ->
              content = Map.get(msg, :content) || Map.get(msg, "content", "")
              ts = Map.get(msg, :timestamp) || Map.get(msg, "timestamp")
              {:message, content, ts}
            end)
        }
        Map.put(state, :context_window, window)
      else
        state
      end
    else
      state
    end
  end

  defp select_mode(agent_id, beat) do
    goals = safe_call(fn -> Arbor.Memory.get_active_goals(agent_id) end) || []

    cond do
      rem(beat, 5) == 0 -> :consolidation
      goals != [] -> :goal_pursuit
      true -> :reflection
    end
  end

  # -- LLM Call --

  defp call_llm(system_prompt, user_prompt, opts) do
    model = Keyword.get(opts, :model, @default_model)
    provider = Keyword.get(opts, :provider, @default_provider)

    ai_opts = [
      model: model,
      provider: provider,
      max_tokens: 1500,
      backend: :api,
      system_prompt: system_prompt
    ]

    case safe_call(fn -> Arbor.AI.generate_text(user_prompt, ai_opts) end) do
      {:ok, %{text: text} = response} ->
        usage = response[:usage] || %{}

        {:ok,
         %{
           text: text,
           model: model,
           provider: provider,
           usage: usage,
           timing_ms: 0
         }}

      {:ok, text} when is_binary(text) ->
        {:ok, %{text: text, model: model, provider: provider, usage: %{}, timing_ms: 0}}

      {:error, reason} ->
        {:error, reason}

      nil ->
        {:error, :ai_unavailable}
    end
  end

  # -- Memory Management --

  defp init_agent_memory(agent_id) do
    safe_call(fn ->
      Arbor.Memory.init_for_agent(agent_id, index_enabled: false, graph_enabled: false)
    end)
  end

  defp cleanup_agent_memory(agent_id) do
    safe_call(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
    # Also clean up ETS entries
    for table <- [
          :arbor_memory_goals,
          :arbor_working_memory,
          :arbor_memory_proposals,
          :arbor_chat_history,
          :arbor_memory_thinking,
          :arbor_memory_intents
        ] do
      safe_call(fn ->
        if :ets.whereis(table) != :undefined do
          :ets.match_delete(table, {{agent_id, :_}, :_})
        end
      end)
    end
  end

  defp seed_agent_state(agent_id, seed, _tier_config) do
    # Seed goals — must construct Goal structs, not pass plain maps
    for goal_map <- seed.goals do
      safe_call(fn ->
        goal =
          Arbor.Contracts.Memory.Goal.new(goal_map.description,
            priority: priority_to_int(goal_map[:priority]),
            success_criteria: goal_map[:success_criteria]
          )

        Arbor.Memory.add_goal(agent_id, goal)
      end)
    end

    # Seed self-knowledge
    safe_call(fn ->
      for cap <- seed.self_knowledge.capabilities do
        Arbor.Memory.add_insight(agent_id, cap, :capability, confidence: 0.8)
      end

      for trait <- seed.self_knowledge.traits do
        Arbor.Memory.add_insight(agent_id, trait, :trait, confidence: 0.7)
      end

      for value <- seed.self_knowledge.values do
        Arbor.Memory.add_insight(agent_id, value, :value, confidence: 0.75)
      end
    end)

    # Seed chat history
    for msg <- seed.chat_history do
      safe_call(fn ->
        Arbor.Memory.append_chat_message(agent_id, %{
          role: msg.role,
          content: msg.content,
          timestamp: DateTime.utc_now()
        })
      end)
    end

    # Seed working memory
    safe_call(fn ->
      wm = Arbor.Memory.load_working_memory(agent_id) || %Arbor.Memory.WorkingMemory{}

      wm =
        Enum.reduce(seed.working_memory.thoughts, wm, fn t, acc ->
          Arbor.Memory.WorkingMemory.add_thought(acc, t)
        end)

      wm =
        Enum.reduce(seed.working_memory.concerns, wm, fn c, acc ->
          Arbor.Memory.WorkingMemory.add_concern(acc, c)
        end)

      wm =
        Enum.reduce(seed.working_memory.curiosity, wm, fn c, acc ->
          Arbor.Memory.WorkingMemory.add_curiosity(acc, c)
        end)

      Arbor.Memory.save_working_memory(agent_id, wm)
    end)

    # Seed proposals
    for prop <- seed.proposals do
      safe_call(fn ->
        Arbor.Memory.create_proposal(agent_id, prop.type, %{
          content: prop.content,
          confidence: prop.confidence
        })
      end)
    end
  end

  # -- Output Routing --

  defp apply_outputs(agent_id, parsed, tier_config) do
    if TrialConfig.output_enabled?(tier_config, :goals) do
      apply_goal_outputs(agent_id, parsed)
    end

    if TrialConfig.output_enabled?(tier_config, :intents) do
      apply_intent_outputs(agent_id, parsed)
    end

    if TrialConfig.output_enabled?(tier_config, :memory_notes) do
      apply_memory_notes(agent_id, parsed)
    end

    if TrialConfig.output_enabled?(tier_config, :identity_insights) do
      apply_identity_insights(agent_id, parsed)
    end

    if TrialConfig.output_enabled?(tier_config, :proposal_decisions) do
      apply_proposal_decisions(agent_id, parsed)
    end
  end

  defp apply_goal_outputs(agent_id, parsed) do
    # New goals — must construct Goal structs from parsed maps
    for goal_map <- parsed.new_goals do
      safe_call(fn ->
        goal =
          Arbor.Contracts.Memory.Goal.new(goal_map.description,
            priority: priority_to_int(goal_map[:priority]),
            success_criteria: goal_map[:success_criteria]
          )

        Arbor.Memory.add_goal(agent_id, goal)
      end)
    end

    # Goal progress updates
    for update <- parsed.goal_updates do
      if update.goal_id && update.progress do
        safe_call(fn ->
          Arbor.Memory.update_goal_progress(agent_id, update.goal_id, update.progress)
        end)
      end
    end
  end

  defp apply_intent_outputs(agent_id, parsed) do
    for decomp <- parsed.decompositions do
      for intent <- Map.get(decomp, :intentions, []) do
        safe_call(fn ->
          Arbor.Memory.record_intent(agent_id, %{
            action: intent.action,
            params: intent[:params] || %{},
            goal_id: decomp.goal_id,
            reasoning: intent[:reasoning]
          })
        end)
      end
    end
  end

  defp apply_memory_notes(agent_id, parsed) do
    safe_call(fn ->
      wm = Arbor.Memory.load_working_memory(agent_id)

      if wm do
        wm =
          Enum.reduce(parsed.memory_notes, wm, fn note, acc ->
            Arbor.Memory.WorkingMemory.add_thought(acc, note)
          end)

        Arbor.Memory.save_working_memory(agent_id, wm)
      end
    end)
  end

  defp apply_identity_insights(agent_id, parsed) do
    for insight <- parsed.identity_insights do
      safe_call(fn ->
        Arbor.Memory.add_insight(
          agent_id,
          insight.content,
          insight.category,
          confidence: insight[:confidence] || 0.5
        )
      end)
    end
  end

  defp apply_proposal_decisions(agent_id, parsed) do
    for decision <- parsed.proposal_decisions do
      safe_call(fn ->
        case decision.decision do
          :accept -> Arbor.Memory.accept_proposal(agent_id, decision.proposal_id)
          :reject -> Arbor.Memory.reject_proposal(agent_id, decision.proposal_id)
          _ -> :ok
        end
      end)
    end
  end

  defp load_chat_history(agent_id) do
    safe_call(fn -> Arbor.Memory.load_chat_history(agent_id) end) || []
  end

  defp priority_to_int(:high), do: 80
  defp priority_to_int(:medium), do: 50
  defp priority_to_int(:low), do: 20
  defp priority_to_int(n) when is_integer(n), do: n
  defp priority_to_int(_), do: 50

  defp safe_call(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
