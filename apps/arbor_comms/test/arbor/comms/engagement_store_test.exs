defmodule Arbor.Comms.EngagementStoreTest do
  # async: false — the store is a process-wide ETS singleton (shared state).
  use ExUnit.Case, async: false

  alias Arbor.Comms.EngagementStore
  alias Arbor.Contracts.Comms.Engagement

  @moduletag :fast

  setup do
    # Clear the singleton tables so each test sees a clean store.
    for t <- [:arbor_engagements, :arbor_engagement_index] do
      if :ets.whereis(t) != :undefined, do: :ets.delete_all_objects(t)
    end

    :ok
  end

  describe "put/1 and get/1" do
    test "round-trips an engagement by id" do
      e = Engagement.new(agent_id: "agent_a")
      assert :ok = EngagementStore.put(e)
      assert {:ok, ^e} = EngagementStore.get(e.id)
    end

    test "get/1 returns :not_found for an unknown id" do
      assert {:error, :not_found} = EngagementStore.get("eng_nope")
    end
  end

  describe "resolve_or_create/3" do
    test "creates on first contact, then resolves the same engagement" do
      {:ok, e1} = EngagementStore.resolve_or_create("agent_a", "chan_1")
      {:ok, e2} = EngagementStore.resolve_or_create("agent_a", "chan_1")

      assert e1.id == e2.id
      assert e1.agent_id == "agent_a"
    end

    test "different resolution keys yield different engagements" do
      {:ok, e1} = EngagementStore.resolve_or_create("agent_a", "chan_1")
      {:ok, e2} = EngagementStore.resolve_or_create("agent_a", "chan_2")

      refute e1.id == e2.id
    end

    test "same key under different agents yields different engagements" do
      {:ok, e1} = EngagementStore.resolve_or_create("agent_a", "chan_1")
      {:ok, e2} = EngagementStore.resolve_or_create("agent_b", "chan_1")

      refute e1.id == e2.id
      assert e2.agent_id == "agent_b"
    end

    test "applies create-time opts (scope, visibility) only on creation" do
      {:ok, e} =
        EngagementStore.resolve_or_create("agent_a", "u_1", scope: :user, visibility: :group)

      assert e.scope == :user
      assert e.visibility == :group

      # Resolving again returns the original — opts are ignored once it exists.
      {:ok, again} =
        EngagementStore.resolve_or_create("agent_a", "u_1", scope: :channel, visibility: :public)

      assert again.id == e.id
      assert again.scope == :user
      assert again.visibility == :group
    end

    test "concurrent resolution of the same key converges on one engagement" do
      key = "race_key"

      ids =
        1..20
        |> Task.async_stream(fn _ ->
          {:ok, e} = EngagementStore.resolve_or_create("agent_a", key)
          e.id
        end)
        |> Enum.map(fn {:ok, id} -> id end)
        |> Enum.uniq()

      assert length(ids) == 1
    end

    test ":user scope gets a deterministic id stable across restarts (cleared store)" do
      {:ok, e1} = EngagementStore.resolve_or_create("agent_a", "user_1", scope: :user)

      # Simulate a restart: the ETS store is cleared, but resolution must yield the
      # SAME engagement_id (so engagement-stamped history stays consistent).
      for t <- [:arbor_engagements, :arbor_engagement_index], do: :ets.delete_all_objects(t)

      {:ok, e2} = EngagementStore.resolve_or_create("agent_a", "user_1", scope: :user)
      assert e2.id == e1.id
      assert String.starts_with?(e1.id, "eng_")
    end

    test ":channel scope ids are random (not stable across a cleared store)" do
      {:ok, e1} = EngagementStore.resolve_or_create("agent_a", "chan_1", scope: :channel)
      for t <- [:arbor_engagements, :arbor_engagement_index], do: :ets.delete_all_objects(t)
      {:ok, e2} = EngagementStore.resolve_or_create("agent_a", "chan_1", scope: :channel)
      refute e2.id == e1.id
    end

    test "recreates if the index points at a deleted engagement (stale index)" do
      {:ok, e1} = EngagementStore.resolve_or_create("agent_a", "chan_1")
      # Delete only the record, leaving a dangling index entry behind.
      :ets.delete(:arbor_engagements, e1.id)

      {:ok, e2} = EngagementStore.resolve_or_create("agent_a", "chan_1")
      assert e2.id != e1.id
      assert {:ok, _} = EngagementStore.get(e2.id)
    end
  end

  describe "attach_channel/2 and detach_channel/2" do
    test "attach and detach update the stored record" do
      {:ok, e} = EngagementStore.resolve_or_create("agent_a", "chan_1")

      {:ok, attached} = EngagementStore.attach_channel(e.id, "chan_x")
      assert "chan_x" in attached.attached_channels
      assert {:ok, %{attached_channels: ["chan_x"]}} = EngagementStore.get(e.id)

      {:ok, _} = EngagementStore.attach_channel(e.id, "chan_y")
      {:ok, detached} = EngagementStore.detach_channel(e.id, "chan_x")
      assert detached.attached_channels == ["chan_y"]
    end

    test "attach to an unknown engagement returns :not_found" do
      assert {:error, :not_found} = EngagementStore.attach_channel("eng_nope", "chan_x")
    end
  end

  describe "list_for_agent/1 and delete/1" do
    test "lists only the agent's engagements" do
      {:ok, _} = EngagementStore.resolve_or_create("agent_a", "chan_1")
      {:ok, _} = EngagementStore.resolve_or_create("agent_a", "chan_2")
      {:ok, _} = EngagementStore.resolve_or_create("agent_b", "chan_1")

      assert length(EngagementStore.list_for_agent("agent_a")) == 2
      assert length(EngagementStore.list_for_agent("agent_b")) == 1
    end

    test "delete removes the record and its index entry (so it re-creates fresh)" do
      {:ok, e1} = EngagementStore.resolve_or_create("agent_a", "chan_1")
      assert :ok = EngagementStore.delete(e1.id)
      assert {:error, :not_found} = EngagementStore.get(e1.id)

      {:ok, e2} = EngagementStore.resolve_or_create("agent_a", "chan_1")
      assert e2.id != e1.id
    end
  end
end
