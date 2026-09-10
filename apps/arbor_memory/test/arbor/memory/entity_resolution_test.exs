defmodule Arbor.Memory.EntityResolutionTest do
  use ExUnit.Case, async: false

  alias Arbor.Memory
  alias Arbor.Memory.Test.{DurableGraphAuthority, NodeRestartBackend}
  alias Arbor.Persistence
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag :integration

  setup do
    authority = DurableGraphAuthority.start!()
    agent = "agent_entity_resolution_#{System.unique_integer([:positive])}"
    assert {:ok, nil} = Memory.init_for_agent(agent, index_enabled: false, auto_embed: false)
    on_exit(fn -> :ets.delete(:arbor_memory_graphs, agent) end)
    Map.put(authority, :agent, agent)
  end

  test "public resolver finds persisted explicit names and aliases while preserving full-content matches",
       %{agent: agent} do
    id =
      add(agent, "The Arbor project orchestrates supervised agents", %{
        "name" => "Arbor",
        "aliases" => ["Tree Agent", "ARB"]
      })

    for name <- [
          "arbor",
          "ARBOR",
          "tree agent",
          "arb",
          "The Arbor project orchestrates supervised agents"
        ] do
      assert {:ok, ^id} = Memory.find_knowledge_by_name(agent, name)
    end

    assert {:ok, record} =
             Persistence.get(:arbor_memory_durable, BufferedStore, "knowledge_graph:#{agent}")

    assert %{"$map" => encoded_metadata} = record.data["payload"]["nodes"][id]["metadata"]
    assert ["s:name", "Arbor"] in encoded_metadata
  end

  test "security regression: exact names do not link substrings or malformed aliases", %{
    agent: agent
  } do
    ann =
      add(agent, "A synthetic reviewer", %{"name" => "Ann", "aliases" => ["Reviewer A", 7, nil]})

    add(agent, "A separate synthetic reviewer", %{"name" => "Anna"})
    add(agent, "A third synthetic reviewer", %{"name" => "Joanne", "aliases" => "Ann"})
    assert {:ok, ^ann} = Memory.find_knowledge_by_name(agent, "ANN")
    assert {:ok, ^ann} = Memory.find_knowledge_by_name(agent, "reviewer a")

    for name <- ["An", "reviewer", "7"] do
      assert {:error, :not_found} = Memory.find_knowledge_by_name(agent, name)
    end

    for name <- [nil, 7, "", "   ", <<255>>] do
      assert {:error, :invalid_name} = Memory.find_knowledge_by_name(agent, name)
    end
  end

  test "security regression: ambiguous exact content or aliases never select an arbitrary node",
       %{agent: agent} do
    first = add(agent, "Atlas", %{}, :fact)
    second = add(agent, "Atlas", %{}, :goal)
    assert first != second
    assert {:error, :ambiguous} = Memory.find_knowledge_by_name(agent, "atlas")
    add(agent, "Synthetic project one", %{"name" => "Project One", "aliases" => ["shared"]})
    add(agent, "Synthetic project two", %{"name" => "Shared"})
    assert {:error, :ambiguous} = Memory.find_knowledge_by_name(agent, "SHARED")
    assert {:ok, graph} = Memory.export_knowledge_graph(agent)
    assert graph.edges == %{}
  end

  test "explicit names and aliases survive storage-owner restart and projection eviction", ctx do
    id =
      add(ctx.agent, "Durable named project", %{"aliases" => ["Project Alias"], name: "Project"})

    assert {:ok, before} = Memory.export_knowledge_graph(ctx.agent)
    assert :ok = stop_supervised(BufferedStore)
    :ets.delete(:arbor_memory_graphs, ctx.agent)

    start_supervised!(
      {BufferedStore,
       name: ctx.store_name,
       backend: NodeRestartBackend,
       collection: ctx.backend_name,
       write_mode: :sync,
       ack_mode: :backend}
    )

    assert {:ok, ^id} = Memory.find_knowledge_by_name(ctx.agent, "project alias")
    assert {:ok, ^before} = Memory.export_knowledge_graph(ctx.agent)
  end

  test "all actual durable relationship types are accepted and invalid types or IDs leave no mutation",
       %{agent: agent} do
    source = add(agent, "Synthetic source", %{})
    target = add(agent, "Synthetic target", %{})

    relationships = [
      :associated_with,
      :causes,
      :contradicts,
      :depends_on,
      :derived_from,
      :enables,
      :example_of,
      :follows,
      :part_of,
      :precedes,
      :related_to,
      :relates_to,
      :supports,
      :uses
    ]

    for relationship <- relationships do
      assert :ok = Memory.link_knowledge(agent, source, target, relationship)
    end

    assert {:ok, graph} = Memory.export_knowledge_graph(agent)

    assert MapSet.new(Enum.map(graph.edges[source], & &1.relationship)) ==
             MapSet.new(relationships)

    for invalid <- [:works_at, "not_a_relationship", nil, 17] do
      assert {:error, _} = Memory.link_knowledge(agent, source, target, invalid)
      assert {:ok, ^graph} = Memory.export_knowledge_graph(agent)
    end

    assert {:error, _} = Memory.link_knowledge(agent, source, "missing-node", :related_to)
    assert {:ok, ^graph} = Memory.export_knowledge_graph(agent)
  end

  defp add(agent, content, metadata, type \\ :fact) do
    assert {:ok, id} =
             Memory.add_knowledge(agent, %{type: type, content: content, metadata: metadata})

    id
  end
end
