defmodule Arbor.Memory.ThinkingTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.Thinking

  @moduletag :fast

  setup do
    agent_id = "test_agent_#{System.unique_integer([:positive])}"
    on_exit(fn -> Thinking.clear(agent_id) end)
    %{agent_id: agent_id}
  end

  describe "record_thinking/3" do
    test "records a thinking entry", %{agent_id: agent_id} do
      assert {:ok, entry} = Thinking.record_thinking(agent_id, "Let me analyze this error...")
      assert entry.agent_id == agent_id
      assert entry.text == "Let me analyze this error..."
      assert entry.significant == false
      assert String.starts_with?(entry.id, "thk_")
    end

    test "records with significance flag", %{agent_id: agent_id} do
      assert {:ok, entry} =
               Thinking.record_thinking(agent_id, "Key insight about the architecture",
                 significant: true
               )

      assert entry.significant == true
    end

    test "records with metadata", %{agent_id: agent_id} do
      assert {:ok, entry} =
               Thinking.record_thinking(agent_id, "Thinking about tests",
                 metadata: %{trigger: "test_failure", tool: "mix_test"}
               )

      assert entry.metadata == %{trigger: "test_failure", tool: "mix_test"}
    end
  end

  describe "recent_thinking/2" do
    test "returns entries in most-recent-first order", %{agent_id: agent_id} do
      Thinking.record_thinking(agent_id, "First thought")
      Process.sleep(1)
      Thinking.record_thinking(agent_id, "Second thought")

      recent = Thinking.recent_thinking(agent_id)
      assert length(recent) == 2
      assert hd(recent).text == "Second thought"
    end

    test "respects limit", %{agent_id: agent_id} do
      for i <- 1..10 do
        Thinking.record_thinking(agent_id, "Thought #{i}")
      end

      assert length(Thinking.recent_thinking(agent_id, limit: 3)) == 3
    end

    test "filters significant only", %{agent_id: agent_id} do
      Thinking.record_thinking(agent_id, "Regular thought")
      Thinking.record_thinking(agent_id, "Important insight", significant: true)
      Thinking.record_thinking(agent_id, "Another regular thought")

      significant = Thinking.recent_thinking(agent_id, significant_only: true)
      assert length(significant) == 1
      assert hd(significant).text == "Important insight"
    end

    test "filters by since", %{agent_id: agent_id} do
      # Record thoughts with different timestamps
      Thinking.record_thinking(agent_id, "Recent thought")

      recent = Thinking.recent_thinking(agent_id, since: ~U[2026-02-01 00:00:00Z])
      assert recent != []
    end

    test "returns empty list when no entries", %{agent_id: agent_id} do
      assert Thinking.recent_thinking(agent_id) == []
    end
  end

  describe "process_stream_chunk/3" do
    test "accumulates chunks then stores on complete", %{agent_id: agent_id} do
      assert :ok = Thinking.process_stream_chunk(agent_id, "Let me think")
      assert :ok = Thinking.process_stream_chunk(agent_id, " about this...")
      assert {:ok, entry} = Thinking.process_stream_chunk(agent_id, "", complete: true)

      assert entry.text == "Let me think about this..."
    end

    test "ignores empty stream on complete", %{agent_id: agent_id} do
      assert :ok = Thinking.process_stream_chunk(agent_id, "", complete: true)

      assert Thinking.recent_thinking(agent_id) == []
    end

    test "accumulated text is stored in recent thinking", %{agent_id: agent_id} do
      Thinking.process_stream_chunk(agent_id, "Part 1 ")
      Thinking.process_stream_chunk(agent_id, "Part 2")
      Thinking.process_stream_chunk(agent_id, "", complete: true)

      recent = Thinking.recent_thinking(agent_id)
      assert length(recent) == 1
      assert hd(recent).text == "Part 1 Part 2"
    end
  end

  describe "ring buffer behavior" do
    test "evicts oldest entries when buffer is full", %{agent_id: agent_id} do
      # Default buffer is 50
      for i <- 1..55 do
        Thinking.record_thinking(agent_id, "Thought #{i}")
      end

      all = Thinking.recent_thinking(agent_id, limit: 100)
      assert length(all) == 50
    end
  end

  describe "clear/1" do
    test "removes all entries for an agent", %{agent_id: agent_id} do
      Thinking.record_thinking(agent_id, "Some thought")
      Thinking.clear(agent_id)
      assert Thinking.recent_thinking(agent_id) == []
    end
  end
end
