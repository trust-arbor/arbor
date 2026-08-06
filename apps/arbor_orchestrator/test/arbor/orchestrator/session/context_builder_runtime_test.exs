defmodule Arbor.Orchestrator.Session.ContextBuilderRuntimeTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Session.ContextBuilder

  # Minimal state shape that session_base_values/1 can chew on. Real
  # Session state is much richer; we only populate what the function reads.
  defp minimal_state(opts \\ []) do
    %{
      session_id: "sess_test",
      agent_id: "agent_test",
      trust_tier: :established,
      session_type: :primary,
      trace_id: nil,
      signal_topic: "session:test",
      tenant_context: nil,
      # session_state values (turn_count, working_memory, goals, etc.) are
      # read through get_*/1 with state.* fallbacks; provide top-level
      # defaults so neither branch crashes.
      turn_count: 0,
      working_memory: %{},
      goals: [],
      cognitive_mode: :pursuit,
      phase: :idle,
      messages: [],
      compactor: nil,
      discovered_tools: MapSet.new(),
      config: Keyword.get(opts, :config, %{})
    }
  end

  describe "session_base_values/1 — runtime axis (Phase 2d)" do
    test "defaults llm_runtime to :arbor when not set in config" do
      values = ContextBuilder.session_base_values(minimal_state())
      assert values["session.llm_runtime"] == :arbor
    end

    test "propagates llm_runtime from config map string key" do
      values =
        ContextBuilder.session_base_values(minimal_state(config: %{"llm_runtime" => :acp}))

      assert values["session.llm_runtime"] == :acp
    end

    test "propagates llm_runtime from config map atom key (legacy callers)" do
      values =
        ContextBuilder.session_base_values(minimal_state(config: %{llm_runtime: :acp}))

      assert values["session.llm_runtime"] == :acp
    end

    test "still publishes llm_provider and llm_model alongside llm_runtime" do
      values =
        ContextBuilder.session_base_values(
          minimal_state(
            config: %{
              "llm_provider" => "anthropic",
              "llm_model" => "claude-opus-4-6",
              "llm_runtime" => :acp
            }
          )
        )

      assert values["session.llm_provider"] == "anthropic"
      assert values["session.llm_model"] == "claude-opus-4-6"
      assert values["session.llm_runtime"] == :acp
    end
  end

  describe "session_base_values/1 — fallback chain (Phase 4+ B3)" do
    test "defaults llm_fallback_chain to [] when not set in config" do
      values = ContextBuilder.session_base_values(minimal_state())
      assert values["session.llm_fallback_chain"] == []
    end

    test "propagates llm_fallback_chain from config map string key" do
      chain = [%{runtime: :acp}, %{model: "claude-sonnet-4-6"}]

      values =
        ContextBuilder.session_base_values(
          minimal_state(config: %{"llm_fallback_chain" => chain})
        )

      assert values["session.llm_fallback_chain"] == chain
    end

    test "propagates llm_fallback_chain from config map atom key" do
      chain = [%{provider: :openai}]

      values =
        ContextBuilder.session_base_values(minimal_state(config: %{llm_fallback_chain: chain}))

      assert values["session.llm_fallback_chain"] == chain
    end
  end

  # Padding a graph past the limit with low-value nodes: an unranked
  # `Enum.take(20)` over 40+ nodes drops the valuable ones on map order alone.
  defp kg_nodes(count, high_value) do
    filler =
      Map.new(1..count, fn i ->
        {"noise_#{i}",
         %{content: "noise #{i}", type: :observation, relevance: 0.1, confidence: 0.1}}
      end)

    Enum.reduce(high_value, filler, fn {id, node}, acc -> Map.put(acc, id, node) end)
  end

  describe "rank_knowledge_nodes/2 — prompt-inclusion ranking" do
    test "keeps the highest-relevance node when the graph exceeds the limit" do
      nodes =
        kg_nodes(40, [
          {"gold",
           %{content: "load-bearing learning", type: :skill, relevance: 0.99, confidence: 0.9}}
        ])

      ranked = ContextBuilder.rank_knowledge_nodes(nodes, 20)

      assert length(ranked) == 20
      assert hd(ranked)["content"] == "load-bearing learning"
    end

    test "pinned nodes outrank higher-relevance unpinned nodes" do
      nodes =
        kg_nodes(40, [
          {"hot", %{content: "hot but unpinned", type: :fact, relevance: 1.0, confidence: 0.9}},
          {"pin",
           %{content: "pinned", type: :trait, relevance: 0.2, confidence: 0.5, pinned: true}}
        ])

      ranked = ContextBuilder.rank_knowledge_nodes(nodes, 20)

      top_two = ranked |> Enum.map(& &1["content"]) |> Enum.take(2)
      assert top_two == ["pinned", "hot but unpinned"]
    end

    test "ranks string-keyed nodes from a JSON round-trip" do
      nodes =
        kg_nodes(40, [
          {"gold",
           %{
             "content" => "json learning",
             "type" => "skill",
             "relevance" => 0.98,
             "confidence" => 0.88
           }}
        ])

      ranked = ContextBuilder.rank_knowledge_nodes(nodes, 20)

      assert hd(ranked) == %{
               "content" => "json learning",
               "type" => "skill",
               "confidence" => 0.88
             }
    end

    test "tolerates nodes missing relevance and confidence" do
      nodes = %{"bare" => %{content: "bare node"}}

      assert [%{"content" => "bare node", "type" => "", "confidence" => 0.5}] =
               ContextBuilder.rank_knowledge_nodes(nodes, 20)
    end
  end
end
