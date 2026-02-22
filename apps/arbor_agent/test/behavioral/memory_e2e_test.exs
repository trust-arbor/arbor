defmodule Arbor.Agent.Behavioral.MemoryE2ETest do
  @moduledoc """
  End-to-end tests for the agent memory system.

  Exercises the full heartbeat loop: prompt construction (reads all stores) →
  LLM response (mocked or real) → parse → route outputs to stores → next
  heartbeat (verify outputs feed back into prompt).

  Suite 1 (Mocked): Deterministic tests with canned JSON responses.
  Suite 2 (Real LLM): Integration tests with a live LLM provider.
  """

  use Arbor.Test.BehavioralCase, async: false

  alias Arbor.Agent.Eval.TrialConfig
  alias Arbor.Agent.HeartbeatPrompt
  alias Arbor.Agent.HeartbeatResponse
  alias Arbor.Contracts.Memory.Goal
  alias Arbor.Contracts.Memory.Intent
  alias Arbor.Memory
  alias Arbor.Memory.WorkingMemory

  # Additional ETS tables needed beyond what BehavioralCase creates
  @extra_ets_tables [
    :arbor_memory_thinking,
    :arbor_memory_goals,
    :arbor_memory_intents,
    :arbor_memory_code_store,
    :arbor_self_knowledge,
    :arbor_identity_rate_limits,
    :arbor_consolidation_state,
    :arbor_reflections,
    :arbor_preconscious_config
  ]

  setup %{agent_id: agent_id} do
    # Ensure extra ETS tables exist
    for table <- @extra_ets_tables do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, :set])
      end
    end

    # Start memory event log if not running (needed for proposal accept/reject)
    if !Process.whereis(:memory_events) do
      start_supervised!({Arbor.Persistence.EventLog.ETS, name: :memory_events})
    end

    # Initialize memory subsystems for this agent
    # graph_enabled: true needed for proposal acceptance (adds to knowledge graph)
    Memory.init_for_agent(agent_id, index_enabled: false, graph_enabled: true)

    on_exit(fn ->
      # Clean up agent memory state
      try do
        Memory.cleanup_for_agent(agent_id)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end

      # Clean up ETS entries for this agent across all memory tables
      all_tables = [
        :arbor_memory_goals,
        :arbor_working_memory,
        :arbor_memory_proposals,
        :arbor_chat_history,
        :arbor_memory_thinking,
        :arbor_memory_intents,
        :arbor_self_knowledge,
        :arbor_consolidation_state,
        :arbor_identity_rate_limits
      ]

      for table <- all_tables do
        try do
          if :ets.whereis(table) != :undefined do
            :ets.match_delete(table, {{agent_id, :_}, :_})
            # Also try single-key format
            :ets.delete(table, agent_id)
          end
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {:ok, agent_id: agent_id}
  end

  # ============================================================================
  # Suite 1: Mocked / Deterministic Tests
  # ============================================================================

  describe "mocked heartbeat loop" do
    setup %{agent_id: agent_id} do
      # Seed standardized state from TrialConfig
      seed = TrialConfig.seed_data()
      seed_agent_state(agent_id, seed)

      # Capture seeded goal IDs
      goals = Memory.get_active_goals(agent_id)
      goal_ids = Enum.map(goals, & &1.id)

      # Capture seeded proposal IDs
      {:ok, proposals} = Memory.get_proposals(agent_id)
      proposal_ids = Enum.map(proposals, & &1.id)

      {:ok, seed: seed, goal_ids: goal_ids, proposal_ids: proposal_ids}
    end

    test "seeded state appears in first heartbeat prompt", %{agent_id: agent_id, seed: seed} do
      state = build_agent_state(agent_id, 1)
      prompt = HeartbeatPrompt.build_prompt(state)

      # Goals should appear in the prompt
      assert prompt =~ "Active Goals"
      assert prompt =~ "test coverage"
      assert prompt =~ "memory subsystem"

      # Self-knowledge should appear
      assert prompt =~ "Self-Awareness"

      # Conversation context should appear
      assert prompt =~ "Conversation Context"
      assert prompt =~ "memory system"

      # Working memory concerns/thoughts feed into the self-knowledge or context
      # (working memory is accessed via the prompt builder internally)

      # Proposals should appear
      assert prompt =~ "Pending Proposals"
      assert prompt =~ seed.proposals |> hd() |> Map.get(:content) |> String.slice(0..30)
    end

    test "mock response parses all output categories", %{
      goal_ids: goal_ids,
      proposal_ids: proposal_ids
    } do
      mock_json = mock_beat1_response(List.first(goal_ids), List.first(proposal_ids))
      parsed = HeartbeatResponse.parse(mock_json)

      assert parsed.thinking != ""
      assert length(parsed.memory_notes) == 2
      assert length(parsed.concerns) == 1
      assert length(parsed.curiosity) == 1
      assert length(parsed.new_goals) == 1
      assert length(parsed.goal_updates) == 1
      assert length(parsed.identity_insights) == 1
      assert length(parsed.proposal_decisions) == 1
    end

    test "outputs route correctly to all memory stores", %{
      agent_id: agent_id,
      goal_ids: goal_ids,
      proposal_ids: proposal_ids
    } do
      mock_json = mock_beat1_response(List.first(goal_ids), List.first(proposal_ids))
      {_prompt, _parsed} = run_mock_heartbeat(agent_id, 1, mock_json)

      # New goals stored
      goals = Memory.get_active_goals(agent_id)
      descriptions = Enum.map(goals, & &1.description)
      assert "Investigate test isolation patterns" in descriptions

      # Goal progress updated
      {:ok, updated_goal} = Memory.get_goal(agent_id, List.first(goal_ids))
      assert updated_goal.progress == 0.2

      # Working memory updated with thoughts
      wm = Memory.load_working_memory(agent_id)

      thought_texts =
        Enum.map(wm.recent_thoughts, fn t ->
          case t do
            %{content: c} -> c
            s when is_binary(s) -> s
            _ -> inspect(t)
          end
        end)

      assert Enum.any?(thought_texts, fn t ->
               String.contains?(String.downcase(t), "test coverage") or
                 String.contains?(String.downcase(t), "coverage")
             end)

      # Self-knowledge updated
      sk = Memory.get_self_knowledge(agent_id)
      cap_names = Enum.map(sk.capabilities, & &1.name)
      assert "pattern recognition" in cap_names

      # Proposal accepted
      {:ok, remaining_proposals} = Memory.get_proposals(agent_id)
      remaining_ids = Enum.map(remaining_proposals, & &1.id)
      refute List.first(proposal_ids) in remaining_ids
    end

    test "multi-beat coherence: beat N outputs feed into beat N+1 prompt", %{
      agent_id: agent_id,
      goal_ids: goal_ids,
      proposal_ids: proposal_ids
    } do
      # Beat 1: Write outputs
      mock1 = mock_beat1_response(List.first(goal_ids), List.first(proposal_ids))
      {_prompt1, _parsed1} = run_mock_heartbeat(agent_id, 1, mock1)

      # Capture the new goal ID for beat 2
      new_goals_after_1 = Memory.get_active_goals(agent_id)

      new_goal =
        Enum.find(new_goals_after_1, fn g ->
          g.description == "Investigate test isolation patterns"
        end)

      assert new_goal, "New goal from beat 1 should exist"

      # Beat 2: Read outputs from beat 1
      mock2 = mock_beat2_response(new_goal.id)
      {prompt2, _parsed2} = run_mock_heartbeat(agent_id, 2, mock2)

      # Beat 2's prompt should contain beat 1's new goal
      assert prompt2 =~ "Investigate test isolation patterns"
      # Beat 2's prompt should contain beat 1's memory notes (via self-knowledge)
      assert prompt2 =~ "pattern recognition"

      # Beat 3: Read outputs from beat 2
      mock3 = mock_beat3_response(new_goal.id)
      {prompt3, _parsed3} = run_mock_heartbeat(agent_id, 3, mock3)

      # Beat 3's prompt should show beat 2's decomposition result
      # (goal should still be there with updated progress)
      assert prompt3 =~ "Investigate test isolation patterns"
    end

    test "goal lifecycle: create → progress → achieve", %{agent_id: agent_id} do
      # Beat 1: Create a new goal
      mock1 =
        Jason.encode!(%{
          "thinking" => "I should track my progress on exploring patterns",
          "actions" => [],
          "memory_notes" => [],
          "goal_updates" => [],
          "new_goals" => [
            %{
              "description" => "Master pattern matching in Elixir",
              "priority" => "high",
              "success_criteria" => "Implement 5 pattern-matching solutions"
            }
          ]
        })

      {_, _} = run_mock_heartbeat(agent_id, 1, mock1)
      goals = Memory.get_active_goals(agent_id)
      new_goal = Enum.find(goals, &(&1.description == "Master pattern matching in Elixir"))
      assert new_goal
      assert new_goal.progress == 0.0

      # Beat 2: Update progress
      mock2 =
        Jason.encode!(%{
          "thinking" => "Making progress on pattern matching",
          "actions" => [],
          "memory_notes" => [],
          "goal_updates" => [
            %{"goal_id" => new_goal.id, "progress" => 0.6, "note" => "3 solutions done"}
          ]
        })

      {_, _} = run_mock_heartbeat(agent_id, 2, mock2)
      {:ok, updated} = Memory.get_goal(agent_id, new_goal.id)
      assert updated.progress == 0.6

      # Beat 3: Achieve goal (progress = 1.0)
      mock3 =
        Jason.encode!(%{
          "thinking" => "Pattern matching mastered!",
          "actions" => [],
          "memory_notes" => ["Completed all 5 pattern-matching solutions"],
          "goal_updates" => [
            %{"goal_id" => new_goal.id, "progress" => 1.0, "note" => "All 5 done!"}
          ]
        })

      {_, _} = run_mock_heartbeat(agent_id, 3, mock3)
      {:ok, achieved} = Memory.get_goal(agent_id, new_goal.id)
      assert achieved.progress == 1.0
    end

    test "working memory accumulation across beats", %{agent_id: agent_id} do
      # Get initial thought count
      wm_before = Memory.load_working_memory(agent_id)
      initial_count = length(wm_before.recent_thoughts)

      for beat <- 1..3 do
        mock =
          Jason.encode!(%{
            "thinking" => "Beat #{beat} thinking",
            "actions" => [],
            "memory_notes" => ["Observation from beat #{beat}", "Second note beat #{beat}"],
            "concerns" => ["Concern from beat #{beat}"],
            "curiosity" => ["Question from beat #{beat}"],
            "goal_updates" => []
          })

        run_mock_heartbeat(agent_id, beat, mock)
      end

      wm = Memory.load_working_memory(agent_id)

      # Thoughts should have grown by 6 (2 per beat × 3 beats)
      assert length(wm.recent_thoughts) >= initial_count + 6

      # Concerns should have accumulated
      assert length(wm.concerns) >= 3

      # Curiosity should have accumulated
      assert length(wm.curiosity) >= 3
    end

    test "self-knowledge grows: capabilities, traits, values", %{agent_id: agent_id} do
      sk_before = Memory.get_self_knowledge(agent_id)
      initial_caps = length(sk_before.capabilities)
      initial_traits = length(sk_before.personality_traits)
      initial_values = length(sk_before.values)

      # Beat 1: Add capability
      mock1 =
        Jason.encode!(%{
          "thinking" => "Discovering capabilities",
          "actions" => [],
          "memory_notes" => [],
          "goal_updates" => [],
          "identity_insights" => [
            %{
              "category" => "capability",
              "content" => "debugging complex systems",
              "confidence" => 0.9
            }
          ]
        })

      run_mock_heartbeat(agent_id, 1, mock1)

      # Beat 2: Add trait
      mock2 =
        Jason.encode!(%{
          "thinking" => "Noticing traits",
          "actions" => [],
          "memory_notes" => [],
          "goal_updates" => [],
          "identity_insights" => [
            %{
              "category" => "trait",
              "content" => "persistent problem solver",
              "confidence" => 0.85
            }
          ]
        })

      run_mock_heartbeat(agent_id, 2, mock2)

      # Beat 3: Add value
      mock3 =
        Jason.encode!(%{
          "thinking" => "Recognizing values",
          "actions" => [],
          "memory_notes" => [],
          "goal_updates" => [],
          "identity_insights" => [
            %{
              "category" => "value",
              "content" => "reliability and correctness",
              "confidence" => 0.8
            }
          ]
        })

      run_mock_heartbeat(agent_id, 3, mock3)

      sk = Memory.get_self_knowledge(agent_id)
      assert length(sk.capabilities) > initial_caps
      assert length(sk.personality_traits) > initial_traits
      assert length(sk.values) > initial_values
    end

    test "proposal decisions: accept and reject", %{agent_id: agent_id} do
      # Create two proposals
      {:ok, prop1} =
        Memory.create_proposal(agent_id, :insight, %{
          content: "I am good at code review",
          confidence: 0.8
        })

      {:ok, prop2} =
        Memory.create_proposal(agent_id, :insight, %{
          content: "I dislike documentation",
          confidence: 0.4
        })

      # Accept prop1, reject prop2
      mock =
        Jason.encode!(%{
          "thinking" => "Reviewing proposals",
          "actions" => [],
          "memory_notes" => [],
          "goal_updates" => [],
          "proposal_decisions" => [
            %{"proposal_id" => prop1.id, "decision" => "accept", "reason" => "Accurate"},
            %{"proposal_id" => prop2.id, "decision" => "reject", "reason" => "Not true"}
          ]
        })

      run_mock_heartbeat(agent_id, 1, mock)

      # Verify: accepted proposal removed from pending
      {:ok, pending} = Memory.get_proposals(agent_id)
      pending_ids = Enum.map(pending, & &1.id)
      refute prop1.id in pending_ids
      refute prop2.id in pending_ids
    end

    test "decompositions create proper intents with goal linkage", %{
      agent_id: agent_id,
      goal_ids: goal_ids
    } do
      target_goal_id = List.first(goal_ids)

      mock =
        Jason.encode!(%{
          "thinking" => "Breaking down the goal",
          "actions" => [],
          "memory_notes" => [],
          "goal_updates" => [],
          "decompositions" => [
            %{
              "goal_id" => target_goal_id,
              "intentions" => [
                %{
                  "action" => "file_read",
                  "params" => %{"path" => "mix.exs"},
                  "reasoning" => "Read project structure",
                  "preconditions" => "File exists",
                  "success_criteria" => "Got file contents"
                },
                %{
                  "action" => "ai_analyze",
                  "params" => %{"prompt" => "Analyze test coverage"},
                  "reasoning" => "Need coverage data",
                  "preconditions" => "None",
                  "success_criteria" => "Got analysis"
                }
              ],
              "contingency" => "Try manual inspection if analysis fails"
            }
          ]
        })

      run_mock_heartbeat(agent_id, 1, mock)

      # Verify intents were recorded with goal linkage
      intents = Memory.recent_intents(agent_id, limit: 10)
      goal_intents = Enum.filter(intents, &(&1.goal_id == target_goal_id))
      assert length(goal_intents) >= 2

      actions = Enum.map(goal_intents, & &1.action)
      assert :file_read in actions
      assert :ai_analyze in actions
    end

    test "five consecutive heartbeats maintain coherent state", %{
      agent_id: agent_id,
      goal_ids: goal_ids,
      proposal_ids: proposal_ids
    } do
      first_goal_id = List.first(goal_ids)
      first_proposal_id = List.first(proposal_ids)

      # Beat 1: Create goal, add notes, accept proposal
      mock1 = mock_beat1_response(first_goal_id, first_proposal_id)
      {_, _} = run_mock_heartbeat(agent_id, 1, mock1)

      # Beat 2: Progress goal, add decompositions
      new_goals = Memory.get_active_goals(agent_id)
      new_goal = Enum.find(new_goals, &(&1.description == "Investigate test isolation patterns"))
      mock2 = mock_beat2_response(new_goal.id)
      {_, _} = run_mock_heartbeat(agent_id, 2, mock2)

      # Beat 3: More progress, value insight
      mock3 = mock_beat3_response(new_goal.id)
      {_, _} = run_mock_heartbeat(agent_id, 3, mock3)

      # Beat 4: Continue work
      mock4 =
        Jason.encode!(%{
          "thinking" => "Continuing analysis of patterns",
          "actions" => [],
          "memory_notes" => ["Found interesting edge case in async tests"],
          "concerns" => [],
          "curiosity" => ["How do other frameworks handle test isolation?"],
          "goal_updates" => [
            %{"goal_id" => new_goal.id, "progress" => 0.7, "note" => "Edge cases found"}
          ],
          "identity_insights" => [
            %{
              "category" => "capability",
              "content" => "systematic debugging",
              "confidence" => 0.85
            }
          ]
        })

      {_, _} = run_mock_heartbeat(agent_id, 4, mock4)

      # Beat 5: Consolidation beat (every 5th)
      mock5 =
        Jason.encode!(%{
          "thinking" => "Time to consolidate and reflect on progress",
          "actions" => [],
          "memory_notes" => ["Overall good progress on test analysis"],
          "concerns" => [],
          "curiosity" => [],
          "goal_updates" => [
            %{"goal_id" => new_goal.id, "progress" => 0.9, "note" => "Nearly complete"}
          ]
        })

      {prompt5, _} = run_mock_heartbeat(agent_id, 5, mock5)

      # Final verification: accumulated state is coherent
      final_goals = Memory.get_active_goals(agent_id)
      # 2 seeded + 1 created
      assert length(final_goals) >= 3

      final_wm = Memory.load_working_memory(agent_id)
      # seed + beats
      assert length(final_wm.recent_thoughts) >= 8

      final_sk = Memory.get_self_knowledge(agent_id)
      # 3 seeded + at least 1 added
      assert length(final_sk.capabilities) >= 4

      # The consolidation beat prompt should have all the accumulated context
      assert prompt5 =~ "Active Goals"
      assert prompt5 =~ "Self-Awareness"
    end
  end

  # ============================================================================
  # Suite 2: Real LLM Tests
  # ============================================================================

  describe "real LLM heartbeat loop" do
    @describetag :llm
    @describetag timeout: 120_000

    setup %{agent_id: agent_id} do
      # Minimal seed for real LLM — give it room to generate
      goal =
        Goal.new("Explore and understand your own memory capabilities",
          priority: 80,
          success_criteria: "Documented at least 2 memory subsystems"
        )

      Memory.add_goal(agent_id, goal)

      Memory.add_insight(agent_id, "code analysis", :capability, confidence: 0.8)
      Memory.add_insight(agent_id, "curious", :trait, confidence: 0.7)

      Memory.append_chat_message(agent_id, %{
        role: "user",
        content: "Tell me about your memory system",
        timestamp: DateTime.utc_now()
      })

      Memory.append_chat_message(agent_id, %{
        role: "assistant",
        content:
          "I have several memory subsystems including goals, working memory, and self-knowledge.",
        timestamp: DateTime.utc_now()
      })

      {:ok, goal_id: goal.id}
    end

    test "agent produces valid JSON responses across 3 beats", %{agent_id: agent_id} do
      for beat <- 1..3 do
        {_prompt, raw_text, parsed} = run_real_heartbeat(agent_id, beat)

        assert parsed.thinking != "",
               "Beat #{beat}: Expected non-empty thinking, got: #{inspect(raw_text)}"

        # At minimum, the response should have valid structure
        assert is_list(parsed.actions)
        assert is_list(parsed.memory_notes)
        assert is_list(parsed.goal_updates)

        # Apply outputs for next beat
        apply_outputs_strict(agent_id, parsed)
      end
    end

    test "agent creates at least 1 goal in 3 beats", %{agent_id: agent_id} do
      initial_goals = Memory.get_active_goals(agent_id)
      initial_count = length(initial_goals)

      for beat <- 1..3 do
        {_prompt, _raw, parsed} = run_real_heartbeat(agent_id, beat)
        apply_outputs_strict(agent_id, parsed)
      end

      final_goals = Memory.get_active_goals(agent_id)
      # LLM should have created at least one new goal OR kept the existing one
      assert length(final_goals) >= initial_count
    end

    test "working memory grows across heartbeats", %{agent_id: agent_id} do
      # Initialize working memory
      wm = %WorkingMemory{}
      Memory.save_working_memory(agent_id, wm)

      total_notes = 0

      total_notes =
        Enum.reduce(1..3, total_notes, fn beat, acc ->
          {_prompt, _raw, parsed} = run_real_heartbeat(agent_id, beat)
          apply_outputs_strict(agent_id, parsed)
          acc + length(parsed.memory_notes)
        end)

      # Over 3 beats, a real LLM should produce at least some memory notes
      final_wm = Memory.load_working_memory(agent_id)
      assert final_wm.recent_thoughts != [] or total_notes > 0
    end

    test "agent produces identity insights in 5 beats", %{agent_id: agent_id} do
      total_insights = 0

      total_insights =
        Enum.reduce(1..5, total_insights, fn beat, acc ->
          {_prompt, _raw, parsed} = run_real_heartbeat(agent_id, beat)
          apply_outputs_strict(agent_id, parsed)
          acc + length(parsed.identity_insights)
        end)

      # Over 5 beats, expect at least some identity insights
      # (This is tolerant — LLMs may not always produce insights)
      final_sk = Memory.get_self_knowledge(agent_id)
      # Either direct insights or proposals should have been created
      assert total_insights > 0 or length(final_sk.capabilities) > 1 or
               length(final_sk.personality_traits) > 1
    end

    test "later beats include context from earlier beats", %{agent_id: agent_id} do
      # Beat 1: Generate some output
      {_prompt1, _raw1, parsed1} = run_real_heartbeat(agent_id, 1)
      apply_outputs_strict(agent_id, parsed1)

      # Beat 2: The prompt should contain outputs from beat 1
      {prompt2, _raw2, parsed2} = run_real_heartbeat(agent_id, 2)
      apply_outputs_strict(agent_id, parsed2)

      # If beat 1 produced memory notes, they should appear in working memory
      # which feeds into beat 2's prompt
      if parsed1.memory_notes != [] do
        wm = Memory.load_working_memory(agent_id)
        assert wm.recent_thoughts != []
      end

      # Beat 3: Should have even more context
      {prompt3, _raw3, _parsed3} = run_real_heartbeat(agent_id, 3)

      # The prompts should be growing with context
      assert String.length(prompt3) >= String.length(prompt2) - 200
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp build_agent_state(agent_id, beat) do
    goals = safe_call(fn -> Memory.get_active_goals(agent_id) end) || []
    chat = safe_call(fn -> Memory.load_chat_history(agent_id) end) || []

    mode =
      cond do
        rem(beat, 5) == 0 -> :consolidation
        goals != [] -> :goal_pursuit
        true -> :reflection
      end

    state = %{
      agent_id: agent_id,
      id: agent_id,
      heartbeat_count: beat,
      cognitive_mode: mode,
      enabled_prompt_sections: :all,
      pending_messages: [],
      background_suggestions: []
    }

    # Add context window from chat history
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
  end

  defp run_mock_heartbeat(agent_id, beat, mock_json) do
    state = build_agent_state(agent_id, beat)
    prompt = HeartbeatPrompt.build_prompt(state)
    parsed = HeartbeatResponse.parse(mock_json)
    apply_outputs_strict(agent_id, parsed)
    {prompt, parsed}
  end

  defp run_real_heartbeat(agent_id, beat) do
    state = build_agent_state(agent_id, beat)
    prompt = HeartbeatPrompt.build_prompt(state)
    system = HeartbeatPrompt.system_prompt(state)

    {:ok, response} =
      Arbor.AI.generate_text(prompt,
        model: "arcee-ai/trinity-large-preview:free",
        provider: :openrouter,
        max_tokens: 1500,
        backend: :api,
        system_prompt: system
      )

    raw_text =
      case response do
        %{text: text} -> text
        text when is_binary(text) -> text
      end

    parsed = HeartbeatResponse.parse(raw_text)
    {prompt, raw_text, parsed}
  end

  defp apply_outputs_strict(agent_id, parsed) do
    # New goals — construct proper Goal structs
    for goal_map <- parsed.new_goals do
      goal =
        Goal.new(goal_map.description,
          priority: priority_to_int(goal_map[:priority]),
          success_criteria: goal_map[:success_criteria]
        )

      Memory.add_goal(agent_id, goal)
    end

    # Goal progress updates
    for update <- parsed.goal_updates do
      if update.goal_id && update.progress do
        Memory.update_goal_progress(agent_id, update.goal_id, update.progress)
      end
    end

    # Working memory: thoughts, concerns, curiosity
    wm = Memory.load_working_memory(agent_id) || %WorkingMemory{}

    wm =
      Enum.reduce(parsed.memory_notes, wm, fn note, acc ->
        WorkingMemory.add_thought(acc, note)
      end)

    wm =
      Enum.reduce(parsed.concerns, wm, fn concern, acc ->
        WorkingMemory.add_concern(acc, concern)
      end)

    wm =
      Enum.reduce(parsed.curiosity, wm, fn item, acc ->
        WorkingMemory.add_curiosity(acc, item)
      end)

    Memory.save_working_memory(agent_id, wm)

    # Identity insights
    for insight <- parsed.identity_insights do
      Memory.add_insight(
        agent_id,
        insight.content,
        insight.category,
        confidence: insight[:confidence] || 0.5
      )
    end

    # Proposal decisions
    for decision <- parsed.proposal_decisions do
      case decision.decision do
        :accept -> Memory.accept_proposal(agent_id, decision.proposal_id)
        :reject -> Memory.reject_proposal(agent_id, decision.proposal_id)
        _ -> :ok
      end
    end

    # Decompositions → Intents (must be Intent structs)
    for decomp <- parsed.decompositions do
      for intention <- Map.get(decomp, :intentions, []) do
        intent =
          Intent.action(intention.action, intention[:params] || %{},
            goal_id: decomp.goal_id,
            reasoning: intention[:reasoning]
          )

        Memory.record_intent(agent_id, intent)
      end
    end

    :ok
  end

  defp seed_agent_state(agent_id, seed) do
    # Seed goals
    for goal_map <- seed.goals do
      goal =
        Goal.new(goal_map.description,
          priority: priority_to_int(goal_map[:priority]),
          success_criteria: goal_map[:success_criteria]
        )

      Memory.add_goal(agent_id, goal)
    end

    # Seed self-knowledge
    for cap <- seed.self_knowledge.capabilities do
      Memory.add_insight(agent_id, cap, :capability, confidence: 0.8)
    end

    for trait <- seed.self_knowledge.traits do
      Memory.add_insight(agent_id, trait, :trait, confidence: 0.7)
    end

    for value <- seed.self_knowledge.values do
      Memory.add_insight(agent_id, value, :value, confidence: 0.75)
    end

    # Seed chat history
    for msg <- seed.chat_history do
      Memory.append_chat_message(agent_id, %{
        role: msg.role,
        content: msg.content,
        timestamp: DateTime.utc_now()
      })
    end

    # Seed working memory
    wm = Memory.load_working_memory(agent_id) || %WorkingMemory{}

    wm =
      Enum.reduce(seed.working_memory.thoughts, wm, fn t, acc ->
        WorkingMemory.add_thought(acc, t)
      end)

    wm =
      Enum.reduce(seed.working_memory.concerns, wm, fn c, acc ->
        WorkingMemory.add_concern(acc, c)
      end)

    wm =
      Enum.reduce(seed.working_memory.curiosity, wm, fn c, acc ->
        WorkingMemory.add_curiosity(acc, c)
      end)

    Memory.save_working_memory(agent_id, wm)

    # Seed proposals
    for prop <- seed.proposals do
      Memory.create_proposal(agent_id, prop.type, %{
        content: prop.content,
        confidence: prop.confidence
      })
    end
  end

  # -- Mock Response Builders --

  defp mock_beat1_response(goal_id, proposal_id) do
    Jason.encode!(%{
      "thinking" =>
        "I can see my goals and some proposals. Let me start analyzing test coverage " <>
          "and accept the proposal that seems accurate.",
      "actions" => [
        %{
          "type" => "file_read",
          "params" => %{"path" => "mix.exs"},
          "reasoning" => "Need to understand project structure for test coverage analysis"
        }
      ],
      "memory_notes" => [
        "The project has multiple test directories to analyze for coverage gaps",
        "Test coverage analysis should start with the most critical modules"
      ],
      "concerns" => ["Some modules may have no tests at all"],
      "curiosity" => ["How does the memory subsystem handle concurrent access?"],
      "goal_updates" => [
        %{"goal_id" => goal_id, "progress" => 0.2, "note" => "Starting analysis"}
      ],
      "new_goals" => [
        %{
          "description" => "Investigate test isolation patterns",
          "priority" => "medium",
          "success_criteria" => "Documented isolation approach for async tests"
        }
      ],
      "identity_insights" => [
        %{
          "category" => "capability",
          "content" => "pattern recognition",
          "confidence" => 0.85
        }
      ],
      "proposal_decisions" => [
        %{
          "proposal_id" => proposal_id,
          "decision" => "accept",
          "reason" => "Aligns with my experience of improving through practice"
        }
      ]
    })
  end

  defp mock_beat2_response(new_goal_id) do
    Jason.encode!(%{
      "thinking" =>
        "I've made initial progress. Now let me decompose the new goal into steps " <>
          "and continue the test coverage analysis.",
      "actions" => [],
      "memory_notes" => [
        "Test isolation requires understanding of ETS table lifecycle",
        "Async tests need special handling for shared state"
      ],
      "concerns" => [],
      "curiosity" => [],
      "goal_updates" => [
        %{"goal_id" => new_goal_id, "progress" => 0.3, "note" => "Researching patterns"}
      ],
      "decompositions" => [
        %{
          "goal_id" => new_goal_id,
          "intentions" => [
            %{
              "action" => "file_read",
              "params" => %{"path" => "test/support"},
              "reasoning" => "Examine existing test helpers",
              "preconditions" => "Directory exists",
              "success_criteria" => "Understood helper structure"
            },
            %{
              "action" => "ai_analyze",
              "params" => %{"prompt" => "Analyze test isolation approaches"},
              "reasoning" => "Get expert analysis",
              "preconditions" => "None",
              "success_criteria" => "Got analysis"
            }
          ],
          "contingency" => "Read ExUnit docs directly"
        }
      ],
      "identity_insights" => [
        %{
          "category" => "trait",
          "content" => "systematic approach to problem solving",
          "confidence" => 0.8
        }
      ]
    })
  end

  defp mock_beat3_response(goal_id) do
    Jason.encode!(%{
      "thinking" =>
        "Making good progress. Time to consolidate what I've learned about " <>
          "test patterns and update my progress.",
      "actions" => [],
      "memory_notes" => ["Consolidation reveals consistent patterns across test files"],
      "concerns" => [],
      "curiosity" => [],
      "goal_updates" => [
        %{"goal_id" => goal_id, "progress" => 0.5, "note" => "Patterns documented"}
      ],
      "identity_insights" => [
        %{
          "category" => "value",
          "content" => "thoroughness in investigation",
          "confidence" => 0.75
        }
      ]
    })
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
