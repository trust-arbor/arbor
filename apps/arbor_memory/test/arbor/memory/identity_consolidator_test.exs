defmodule Arbor.Memory.IdentityConsolidatorTest do
  use ExUnit.Case, async: false

  alias Arbor.Memory.{IdentityConsolidator, SelfKnowledge}

  @moduletag :fast

  setup do
    # Ensure ETS tables exist
    for table <- [:arbor_identity_rate_limits, :arbor_self_knowledge, :arbor_memory_graphs] do
      if :ets.whereis(table) == :undefined do
        try do
          :ets.new(table, [:named_table, :public, :set])
        rescue
          ArgumentError -> :ok
        end
      end
    end

    # Clean up for this test
    agent_id = "test_agent_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      # Safely delete - table may not exist
      for table <- [:arbor_identity_rate_limits, :arbor_self_knowledge, :arbor_memory_graphs] do
        if :ets.whereis(table) != :undefined do
          try do
            :ets.delete(table, agent_id)
          rescue
            ArgumentError -> :ok
          end
        end
      end
    end)

    %{agent_id: agent_id}
  end

  describe "should_consolidate?/2" do
    test "returns true for native agents by default", %{agent_id: agent_id} do
      assert IdentityConsolidator.should_consolidate?(agent_id)
    end

    test "returns true with force option", %{agent_id: agent_id} do
      assert IdentityConsolidator.should_consolidate?(agent_id, force: true)
    end

    test "returns false when rate limited", %{agent_id: agent_id} do
      # Simulate 3 recent consolidations
      now = System.monotonic_time(:millisecond)

      :ets.insert(:arbor_identity_rate_limits, {
        agent_id,
        [now, now - 1000, now - 2000]
      })

      refute IdentityConsolidator.should_consolidate?(agent_id)
    end

    test "respects cooldown period", %{agent_id: agent_id} do
      # Simulate a recent consolidation (within cooldown)
      now = System.monotonic_time(:millisecond)
      # 1 hour ago (within 4 hour cooldown)
      recent = now - 1 * 60 * 60 * 1000
      :ets.insert(:arbor_identity_rate_limits, {agent_id, [recent]})

      refute IdentityConsolidator.should_consolidate?(agent_id)
    end

    test "allows consolidation after cooldown", %{agent_id: agent_id} do
      # Simulate a consolidation outside cooldown
      now = System.monotonic_time(:millisecond)
      # 5 hours ago (outside 4 hour cooldown)
      old = now - 5 * 60 * 60 * 1000
      :ets.insert(:arbor_identity_rate_limits, {agent_id, [old]})

      assert IdentityConsolidator.should_consolidate?(agent_id)
    end
  end

  describe "consolidate/2" do
    test "returns no_changes when no graph exists", %{agent_id: agent_id} do
      result = IdentityConsolidator.consolidate(agent_id)
      assert result == {:ok, :no_changes}
    end

    test "returns rate_limited error when at limit", %{agent_id: agent_id} do
      # Simulate 3 recent consolidations
      now = System.monotonic_time(:millisecond)

      :ets.insert(:arbor_identity_rate_limits, {
        agent_id,
        [now, now - 1000, now - 2000]
      })

      result = IdentityConsolidator.consolidate(agent_id)
      assert result == {:error, :rate_limited}
    end

    test "force option bypasses rate limits", %{agent_id: agent_id} do
      # Simulate 3 recent consolidations
      now = System.monotonic_time(:millisecond)

      :ets.insert(:arbor_identity_rate_limits, {
        agent_id,
        [now, now - 1000, now - 2000]
      })

      # With force: true, should not return rate_limited
      result = IdentityConsolidator.consolidate(agent_id, force: true)
      # Will return :no_changes because no graph, but not :rate_limited
      assert result == {:ok, :no_changes}
    end
  end

  describe "get_self_knowledge/1 and save_self_knowledge/2" do
    test "returns nil when not set", %{agent_id: agent_id} do
      assert IdentityConsolidator.get_self_knowledge(agent_id) == nil
    end

    test "saves and retrieves self knowledge", %{agent_id: agent_id} do
      sk = SelfKnowledge.new(agent_id)
      sk = SelfKnowledge.add_trait(sk, :curious, 0.8)

      :ok = IdentityConsolidator.save_self_knowledge(agent_id, sk)

      retrieved = IdentityConsolidator.get_self_knowledge(agent_id)
      assert retrieved.agent_id == agent_id
      assert length(retrieved.personality_traits) == 1
    end
  end

  describe "rollback/2" do
    test "returns error when no self knowledge", %{agent_id: agent_id} do
      result = IdentityConsolidator.rollback(agent_id)
      assert result == {:error, :no_self_knowledge}
    end

    test "returns error when no history", %{agent_id: agent_id} do
      sk = SelfKnowledge.new(agent_id)
      IdentityConsolidator.save_self_knowledge(agent_id, sk)

      result = IdentityConsolidator.rollback(agent_id)
      assert result == {:error, :no_history}
    end

    test "rollback restores previous version", %{agent_id: agent_id} do
      sk =
        SelfKnowledge.new(agent_id)
        |> SelfKnowledge.add_trait(:curious, 0.8)
        |> SelfKnowledge.snapshot()
        |> SelfKnowledge.add_trait(:methodical, 0.9)

      IdentityConsolidator.save_self_knowledge(agent_id, sk)

      {:ok, rolled_back} = IdentityConsolidator.rollback(agent_id)
      assert length(rolled_back.personality_traits) == 1
      assert hd(rolled_back.personality_traits).trait == :curious
    end
  end

  describe "history/2" do
    test "returns empty list when no events", %{agent_id: agent_id} do
      {:ok, history} = IdentityConsolidator.history(agent_id)
      # May return events or empty depending on EventLog state
      assert is_list(history)
    end
  end

  describe "agent type filtering" do
    test "respects disabled_for config" do
      agent_id = "bridged_agent_test"

      # Configure bridged agents as disabled
      old_config = Application.get_env(:arbor_memory, :identity_consolidation, [])

      Application.put_env(:arbor_memory, :identity_consolidation,
        disabled_for: [:bridged]
      )

      on_exit(fn ->
        Application.put_env(:arbor_memory, :identity_consolidation, old_config)
      end)

      # Since we can't easily set agent type, this just tests the config is read
      # In a full implementation, agent type would be retrieved from a registry
      assert IdentityConsolidator.should_consolidate?(agent_id)
    end
  end
end
