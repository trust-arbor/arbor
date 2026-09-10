defmodule Arbor.Actions.MemoryEntityLinksPersistenceTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions
  alias Arbor.Actions.Memory.{Connect, Remember}
  alias Arbor.Memory
  alias Arbor.Persistence
  alias Arbor.Persistence.{BufferedStore, QueryableStore}

  @moduletag :fast
  @moduletag :integration
  @store :arbor_memory_durable

  defmodule Backend do
    @behaviour Arbor.Contracts.Persistence.Store
    alias Arbor.Persistence.QueryableStore.ETS

    @impl true
    def put(key, value, opts), do: ETS.put(key, value, opts)
    @impl true
    def get(key, opts), do: ETS.get(key, opts)
    @impl true
    def delete(key, opts), do: ETS.delete(key, opts)
    @impl true
    def list(opts), do: ETS.list(opts)
    @impl true
    def query(filter, opts), do: ETS.query(filter, opts)
    @impl true
    def compare_and_delete(key, expected, opts), do: ETS.compare_and_delete(key, expected, opts)
    @impl true
    def durability_class(_opts), do: :node_restart

    @impl true
    def compare_and_swap(key, expected, replacement, opts) do
      {mode, observer} = Agent.get(Keyword.fetch!(opts, :control), & &1)
      edges = get_in(replacement.data, ["payload", "edges"]) || %{}
      edge_write? = Enum.any?(edges, fn {_id, outgoing} -> outgoing != [] end)
      if edge_write?, do: send(observer, {:edge_write_attempt, key})

      if edge_write? and mode == :reject_edges,
        do: {:error, :fixture_edge_write_rejected},
        else: ETS.compare_and_swap(key, expected, replacement, opts)
    end
  end

  defmodule Embeddings do
    def embed(_text, _opts) do
      dimensions = Arbor.Contracts.Persistence.VectorRecord.dimensions()

      {:ok,
       %{
         embedding: [1.0 | List.duplicate(0.0, dimensions - 1)],
         provider: :test,
         model: "entity-links-fixture",
         dimensions: dimensions
       }}
    end
  end

  setup do
    unless System.get_env("ARBOR_TEST_MEMORY_AUTHORITY") == "external" do
      raise "run this sole test file with ARBOR_TEST_MEMORY_AUTHORITY=external"
    end

    assert Process.whereis(@store) == nil
    observer = self()
    control = start_supervised!({Agent, fn -> {:available, observer} end})
    backend_name = Module.concat(__MODULE__, Records)
    start_supervised!({QueryableStore.ETS, name: backend_name})

    store_opts = [
      name: @store,
      backend: Backend,
      backend_opts: [control: control],
      collection: backend_name,
      write_mode: :sync,
      ack_mode: :backend
    ]

    start_supervised!({BufferedStore, store_opts})

    agent = "agent_entity_links_#{System.unique_integer([:positive])}"

    assert {:ok, _index} =
             Memory.init_for_agent(agent, auto_embed: false, embedding_provider: Embeddings)

    for resource <- [
          "arbor://memory/read",
          "arbor://memory/write",
          "arbor://memory/add_knowledge"
        ] do
      assert {:ok, cap} = Arbor.Security.grant(principal: agent, resource: resource)
      on_exit(fn -> Arbor.Security.revoke(cap.id) end)
    end

    on_exit(fn ->
      _ = Memory.cleanup_for_agent(agent)
      :ets.delete(:arbor_memory_graphs, agent)
    end)

    %{agent: agent, context: %{agent_id: agent}, control: control, store_opts: store_opts}
  end

  test "Remember resolves named sentence nodes and aliases, persisting one acknowledged edge",
       ctx do
    target =
      add(ctx.agent, "The BEAM executes concurrent processes", %{
        "name" => "BEAM",
        "aliases" => ["Erlang VM"]
      })

    assert {:ok, result} =
             remember(ctx, "Arbor runs supervised agents", ["beam", "Erlang VM", "BEAM"])

    assert result.stored and result.outcome == :created
    assert result.linked_count == 1
    assert Enum.map(result.entity_links, & &1.status) == [:linked, :duplicate, :duplicate]
    assert Enum.all?(result.entity_links, &(&1.target_id == target))
    assert_receive {:edge_write_attempt, _key}
    refute_receive {:edge_write_attempt, _key}

    assert {:ok, graph} = Memory.export_knowledge_graph(ctx.agent)

    assert [%{target_id: ^target, relationship: :related_to, strength: 1.0}] =
             graph.edges[result.node_id]

    assert {:ok, record} = Persistence.get(@store, BufferedStore, "knowledge_graph:#{ctx.agent}")

    assert [%{"target_id" => ^target, "relationship" => "related_to"}] =
             record.data["payload"]["edges"][result.node_id]

    # Restart the owned storage process; retain the explicit test backend.
    # This proves storage-owner recovery, not disk or whole-BEAM durability.
    assert :ok = stop_supervised(BufferedStore)
    :ets.delete(:arbor_memory_graphs, ctx.agent)
    start_supervised!({BufferedStore, ctx.store_opts})
    assert {:ok, ^graph} = Memory.export_knowledge_graph(ctx.agent)
    assert {:ok, ^target} = Memory.find_knowledge_by_name(ctx.agent, "erlang vm")
  end

  test "duplicate Remember preserves node outcome and reinforces a target only once per invocation",
       ctx do
    target =
      add(ctx.agent, "The BEAM executes processes", %{"name" => "BEAM", "aliases" => ["VM"]})

    assert {:ok, first} = remember(ctx, "Arbor uses the BEAM", ["BEAM", "VM"])
    assert {:ok, second} = remember(ctx, "Arbor uses the BEAM", ["VM", "BEAM"])
    assert second.node_id == first.node_id
    assert second.outcome == :deduplicated and second.already_existed
    assert first.linked_count == 1 and second.linked_count == 1
    assert {:ok, graph} = Memory.export_knowledge_graph(ctx.agent)
    assert [%{target_id: ^target, strength: 1.5}] = graph.edges[first.node_id]
    assert map_size(graph.nodes) == 2
  end

  test "security regression: ambiguous, absent and substring entity names create no false links or stubs",
       ctx do
    add(ctx.agent, "Atlas", %{}, :fact)
    add(ctx.agent, "Atlas", %{}, :goal)
    add(ctx.agent, "Anna is a synthetic reviewer", %{"name" => "Anna"})
    assert {:ok, result} = remember(ctx, "A synthetic project note", ["atlas", "Ann", "Missing"])
    assert result.linked_count == 0
    assert Enum.all?(result.entity_links, &(&1.status == :unresolved))

    assert Enum.map(result.entity_links, & &1.reason) == [
             ":ambiguous",
             ":not_found",
             ":not_found"
           ]

    assert {:ok, graph} = Memory.export_knowledge_graph(ctx.agent)
    assert graph.edges == %{}
    assert map_size(graph.nodes) == 4
    refute_receive {:edge_write_attempt, _}
  end

  test "acknowledgment regression: a real rejected edge CAS cannot inflate Remember linked_count",
       ctx do
    target = add(ctx.agent, "Target", %{})
    Agent.update(ctx.control, fn {_mode, observer} -> {:reject_edges, observer} end)
    assert {:ok, result} = remember(ctx, "Source stored before failed link", ["Target"])
    assert result.stored
    assert result.linked_count == 0
    assert [%{target_id: ^target, status: :failed, reason: reason}] = result.entity_links
    assert is_binary(reason) and reason != ""
    assert_receive {:edge_write_attempt, _key}
    Agent.update(ctx.control, fn {_mode, observer} -> {:available, observer} end)
    assert {:ok, graph} = Memory.export_knowledge_graph(ctx.agent)
    assert graph.edges == %{}
    assert graph.nodes[result.node_id].content == "Source stored before failed link"
    assert {:ok, record} = Persistence.get(@store, BufferedStore, "knowledge_graph:#{ctx.agent}")
    assert record.data["payload"]["edges"] == %{}
  end

  test "public Connect preserves accepted spelling and rejects invalid relationship types without mutation",
       ctx do
    source = add(ctx.agent, "Source", %{})
    target = add(ctx.agent, "Target", %{})

    for relationship <- ["related_to", "relates_to"] do
      assert {:ok, %{linked: true}} =
               dispatch(ctx, Connect, %{
                 from_id: source,
                 to_id: target,
                 relationship: relationship
               })
    end

    assert {:ok, graph} = Memory.export_knowledge_graph(ctx.agent)

    assert MapSet.new(Enum.map(graph.edges[source], & &1.relationship)) ==
             MapSet.new([:related_to, :relates_to])

    assert {:error, _} =
             dispatch(ctx, Connect, %{from_id: source, to_id: target, relationship: "works_at"})

    assert {:ok, ^graph} = Memory.export_knowledge_graph(ctx.agent)
  end

  test "security regression: private policy denies Remember and Connect before graph effects",
       ctx do
    source = add(ctx.agent, "Source", %{})
    target = add(ctx.agent, "Target", %{})
    assert {:ok, graph} = Memory.export_knowledge_graph(ctx.agent)
    restricted = %{ctx | context: Map.put(ctx.context, :memory_write_policy, :deny)}

    assert {:error, :private_turn_memory_write_denied} =
             remember(restricted, "Private content", ["Target"])

    assert {:error, :private_turn_memory_write_denied} =
             dispatch(restricted, Connect, %{
               from_id: source,
               to_id: target,
               relationship: "related_to"
             })

    assert {:ok, ^graph} = Memory.export_knowledge_graph(ctx.agent)
    refute_receive {:edge_write_attempt, _}
  end

  defp remember(ctx, content, entities),
    do: dispatch(ctx, Remember, %{content: content, type: "fact", entities: entities})

  defp dispatch(ctx, action, params),
    do: Actions.authorize_and_execute(ctx.agent, action, params, ctx.context)

  defp add(agent, content, metadata, type \\ :fact) do
    assert {:ok, id} =
             Memory.add_knowledge(agent, %{type: type, content: content, metadata: metadata})

    id
  end
end
