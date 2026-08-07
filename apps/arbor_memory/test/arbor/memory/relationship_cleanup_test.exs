defmodule Arbor.Memory.RelationshipCleanupTest do
  @moduledoc """
  Memory public-facade content-only relationship cleanup (VP-05D2C3I0A).
  """

  use Arbor.Persistence.DatabaseCase, async: false

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory
  alias Arbor.Memory.{Provenance, Relationship}

  @moduletag :integration
  @moduletag :database
  @moduletag spec: "VP-05D2C3I0A"

  setup do
    for agent <- ~w(cleanup_agent_a cleanup_agent_b) do
      :ok = Memory.delete_all_relationships(agent)
      :ok = Provenance.delete_agent(agent)
    end

    on_exit(fn ->
      for agent <- ~w(cleanup_agent_a cleanup_agent_b) do
        Provenance.delete_agent(agent)
      end
    end)

    {:ok, agent: "cleanup_agent_a", other: "cleanup_agent_b"}
  end

  test "delete_all_relationships is target-only and idempotent", %{agent: agent, other: other} do
    assert {:ok, _} = Memory.save_relationship(agent, Relationship.new("A1"))
    assert {:ok, _} = Memory.save_relationship(agent, Relationship.new("A2"))
    assert {:ok, _} = Memory.save_relationship(other, Relationship.new("B1"))

    assert {:ok, false} = Memory.relationships_absent?(agent)
    assert :ok = Memory.delete_all_relationships(agent)
    assert {:ok, true} = Memory.relationships_absent?(agent)
    assert :ok = Memory.delete_all_relationships(agent)

    assert {:ok, [only]} = Memory.list_relationships(other)
    assert only.name == "B1"
    assert {:ok, false} = Memory.relationships_absent?(other)
  end

  test "content-only cleanup retains live Provenance for other domains", %{agent: agent} do
    payload = %{"content" => "goal evidence", "score" => 1}

    assert {:ok, taint} =
             Taint.new(%{
               level: :trusted,
               sensitivity: :internal,
               sanitizations: 0,
               confidence: :verified,
               source: "relationship_cleanup_test",
               chain: []
             })

    assert :ok = Provenance.put(:goal, agent, "goal-keep", payload, taint)
    assert {:ok, ^taint, :verified} = Provenance.resolve(:goal, agent, "goal-keep", payload)
    assert {:ok, ["goal-keep"]} = Provenance.list_item_ids(:goal, agent)

    assert {:ok, _} = Memory.save_relationship(agent, Relationship.new("WillDelete"))
    assert {:ok, false} = Memory.relationships_absent?(agent)

    assert :ok = Memory.delete_all_relationships(agent)
    assert {:ok, true} = Memory.relationships_absent?(agent)

    # Behavioral proof: provenance entry for a non-relationship domain remains.
    assert {:ok, ["goal-keep"]} = Provenance.list_item_ids(:goal, agent)
    assert {:ok, ^taint, :verified} = Provenance.resolve(:goal, agent, "goal-keep", payload)
  end
end
