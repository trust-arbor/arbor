defmodule Arbor.Actions.IdentityPersistenceTest do
  @moduledoc """
  Proves the identity WRITE side works, now that `heartbeat.dot` has a
  `store_identity` node.

  Until 2026-08-06 the live heartbeat asked the model for `identity_insights`
  every beat (`session_llm.ex` prompt schema), parsed them into context
  (`session.ex:186`), and then had no node to persist them. Only the eval-only
  `-full` / `-identity` arms called `session_goals.store_identity`, so the memory
  ablation measured a capability production did not have.

  This guards the producer. The corresponding READ side — surfacing
  self-knowledge in the live prompt — is audit finding F2 and is deliberately
  still open: there is no point porting `self_knowledge_section` until something
  writes the data, which is what this makes true.
  """

  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.SessionGoals.StoreIdentity

  @moduletag :fast

  setup do
    agent_id = "identity_persist_#{System.unique_integer([:positive])}"
    {:ok, _} = Arbor.Memory.init_for_agent(agent_id)
    on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
    {:ok, agent_id: agent_id}
  end

  describe "session_goals.store_identity (heartbeat producer)" do
    test "an insight survives to SelfKnowledge", %{agent_id: agent_id} do
      # Shape the LLM actually emits, as parsed by session.process_results/1.
      insights = [
        %{
          "category" => "capability",
          "content" => "I can trace DOT pipelines",
          "confidence" => 0.8
        }
      ]

      assert {:ok, _} = StoreIdentity.run(%{agent_id: agent_id, insights: insights}, %{})

      sk = Arbor.Memory.get_self_knowledge(agent_id)

      assert sk != nil,
             "store_identity ran but nothing reached SelfKnowledge — the write side is " <>
               "still broken and porting self_knowledge_section would render nothing"

      # Storage differs by category: capabilities keep the raw phrase under
      # :name, while traits and values are slugified. Assert the stored shape,
      # not an assumed one.
      assert sk.capabilities != [], "capability insight did not reach SelfKnowledge.capabilities"
      assert inspect(sk.capabilities) =~ "I can trace DOT pipelines"
    end

    test "reads the context key the heartbeat node actually passes", %{agent_id: agent_id} do
      # heartbeat.dot declares context_keys="session.identity_insights,session.agent_id",
      # so params arrive string-keyed with the session. prefix. If the action
      # stopped honouring that shape the node would silently store nothing.
      params = %{
        "session.agent_id" => agent_id,
        "session.identity_insights" => [
          %{
            "category" => "trait",
            "content" => "I prefer measuring to guessing",
            "confidence" => 0.9
          }
        ]
      }

      assert {:ok, _} = StoreIdentity.run(params, %{})

      sk = Arbor.Memory.get_self_knowledge(agent_id)
      assert sk.personality_traits != [], "the session.-prefixed context shape stored nothing"
      assert inspect(sk.personality_traits) =~ "measuring_to_guessing"
    end

    test "empty insights is a no-op, not an error", %{agent_id: agent_id} do
      # Most beats produce none; this must not fail the pipeline tail.
      assert {:ok, _} = StoreIdentity.run(%{agent_id: agent_id, insights: []}, %{})
    end

    test "a malformed insight does not abort the beat", %{agent_id: agent_id} do
      insights = [
        %{"content" => "no category"},
        %{"category" => "value", "content" => "honesty over reassurance"}
      ]

      assert {:ok, _} = StoreIdentity.run(%{agent_id: agent_id, insights: insights}, %{})

      sk = Arbor.Memory.get_self_knowledge(agent_id)

      assert inspect(sk.values) =~ "honesty_over_reassurance",
             "the well-formed insight must still be stored despite a malformed sibling"
    end
  end
end
