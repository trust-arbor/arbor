defmodule Arbor.Orchestrator.Session.SelfKnowledgeChainTest do
  @moduledoc """
  End-to-end proof that self-knowledge reaches the heartbeat prompt.

  Audit finding F2 said `SelfKnowledge` was written durably but never read back
  into the live prompt. Investigating it turned up something worse: on the live
  path it was never *written* either — `heartbeat.dot` had no `store_identity`
  node, so the model was asked for `identity_insights` every beat and they were
  discarded.

  Both halves landed on 2026-08-06. This test walks the whole chain rather than
  either end of it:

      store identity
        -> Memory.get_self_knowledge/1
        -> ContextBuilder.load_self_knowledge/1   (publishes session.self_knowledge)
        -> SessionLlm.BuildPrompt                 (renders ## Self-Awareness)

  Any link breaking turns this red. Asserting only on the store would repeat the
  original mistake: a component that passes while nothing reaches the model.
  """

  use ExUnit.Case, async: false

  alias Arbor.Actions.SessionLlm.BuildPrompt
  alias Arbor.Orchestrator.Session.ContextBuilder

  @moduletag :fast

  setup do
    agent_id = "sk_chain_#{System.unique_integer([:positive])}"
    {:ok, _} = Arbor.Memory.init_for_agent(agent_id, graph_enabled: false)
    on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
    {:ok, agent_id: agent_id}
  end

  describe "identity -> prompt" do
    test "a stored insight reaches the rendered heartbeat prompt", %{agent_id: agent_id} do
      {:ok, _} =
        Arbor.Actions.SessionGoals.StoreIdentity.run(
          %{
            agent_id: agent_id,
            insights: [
              %{
                "category" => "capability",
                "content" => "I can trace a DOT pipeline end to end",
                "confidence" => 0.9
              }
            ]
          },
          %{}
        )

      summary = ContextBuilder.load_self_knowledge(agent_id)

      assert is_binary(summary) and summary != "",
             "ContextBuilder.load_self_knowledge/1 returned nothing — the reader is " <>
               "disconnected from the writer, which is exactly the F2 failure"

      {:ok, out} = BuildPrompt.run(%{mode: "heartbeat", self_knowledge: summary}, %{})

      assert out[:heartbeat_prompt] =~ "## Self-Awareness",
             "self-knowledge exists and was loaded but never reached the prompt"
    end

    test "an agent with no identity yields no section", %{agent_id: agent_id} do
      # The negative control. Without it this suite could pass on a loader that
      # always returns a non-empty string.
      assert ContextBuilder.load_self_knowledge(agent_id) in [nil, ""]

      {:ok, out} =
        BuildPrompt.run(
          %{mode: "heartbeat", self_knowledge: ContextBuilder.load_self_knowledge(agent_id)},
          %{}
        )

      refute out[:heartbeat_prompt] =~ "## Self-Awareness"
    end

    test "an unknown agent degrades to nil rather than raising" do
      # Heartbeats must not die because the memory store is cold.
      assert ContextBuilder.load_self_knowledge("never_existed_#{System.unique_integer()}") in [
               nil,
               ""
             ]
    end
  end
end
