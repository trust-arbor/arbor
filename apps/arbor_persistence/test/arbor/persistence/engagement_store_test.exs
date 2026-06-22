defmodule Arbor.Persistence.EngagementStoreTest do
  # Exercises the durable engagement store against the real Repo (SQLite3 by
  # default, PostgreSQL when configured) via the sandbox. Excluded from the
  # no-database lane.
  use Arbor.Persistence.DatabaseCase, async: false

  @moduletag :database

  alias Arbor.Contracts.Comms.Engagement
  alias Arbor.Persistence.EngagementStore

  test "upsert/get round-trips a contract Engagement (atoms <-> string columns)" do
    e =
      Engagement.new(agent_id: "agent_a", scope: :user, visibility: :group, owner_tenant: "t1")
      |> Engagement.attach_channel("chan_1")

    assert {:ok, saved} = EngagementStore.upsert(e)
    assert saved.id == e.id

    assert {:ok, got} = EngagementStore.get(e.id)
    assert got.agent_id == "agent_a"
    assert got.scope == :user
    assert got.visibility == :group
    assert got.status == :active
    assert got.owner_tenant == "t1"
    assert got.attached_channels == ["chan_1"]
  end

  test "upsert updates an existing engagement (by engagement_id)" do
    e = Engagement.new(agent_id: "agent_a", scope: :user)
    {:ok, _} = EngagementStore.upsert(e)

    {:ok, _} = EngagementStore.upsert(Engagement.attach_channel(e, "chan_2"))

    assert {:ok, got} = EngagementStore.get(e.id)
    assert got.attached_channels == ["chan_2"]
  end

  test "list_for_agent returns only that agent's engagements" do
    {:ok, _} = EngagementStore.upsert(Engagement.new(agent_id: "agent_x", scope: :user))
    {:ok, _} = EngagementStore.upsert(Engagement.new(agent_id: "agent_x", scope: :channel))
    {:ok, _} = EngagementStore.upsert(Engagement.new(agent_id: "agent_y", scope: :user))

    assert length(EngagementStore.list_for_agent("agent_x")) == 2
    assert length(EngagementStore.list_for_agent("agent_y")) == 1
  end

  test "get returns :not_found for an unknown id" do
    assert {:error, :not_found} = EngagementStore.get("eng_nope")
  end

  test "delete removes the engagement" do
    e = Engagement.new(agent_id: "agent_a", scope: :user)
    {:ok, _} = EngagementStore.upsert(e)

    assert :ok = EngagementStore.delete(e.id)
    assert {:error, :not_found} = EngagementStore.get(e.id)
  end
end
