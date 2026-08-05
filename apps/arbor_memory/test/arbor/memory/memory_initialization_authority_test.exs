defmodule Arbor.Memory.InitializationAuthorityTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.{TaintedValue, TaintEnvelope}
  alias Arbor.Memory

  alias Arbor.Memory.{
    IndexSupervisor,
    KnowledgeGraph,
    KnowledgeGraphStore,
    MemoryStore,
    Provenance
  }

  alias Arbor.Memory.KnowledgeGraph.Codec
  alias Arbor.Memory.Test.DurableGraphAuthority
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @store_name :arbor_memory_durable
  @graph_ets :arbor_memory_graphs

  defmodule SwitchableBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    alias Arbor.Persistence.QueryableStore.ETS

    @impl true
    def put(key, value, opts), do: available_call(opts, fn -> ETS.put(key, value, opts) end)

    @impl true
    def get(key, opts), do: available_call(opts, fn -> ETS.get(key, opts) end)

    @impl true
    def delete(key, opts), do: available_call(opts, fn -> ETS.delete(key, opts) end)

    @impl true
    def list(opts), do: available_call(opts, fn -> ETS.list(opts) end)

    @impl true
    def query(filter, opts), do: available_call(opts, fn -> ETS.query(filter, opts) end)

    @impl true
    def compare_and_swap(key, expected, replacement, opts) do
      available_call(opts, fn ->
        cas_mode =
          Agent.get_and_update(Keyword.fetch!(opts, :control), fn state ->
            {state.cas_mode, Map.update!(state, :cas_calls, fn calls -> calls + 1 end)}
          end)

        case cas_mode do
          :normal -> ETS.compare_and_swap(key, expected, replacement, opts)
          :conflict -> {:error, :conflict}
        end
      end)
    end

    @impl true
    def compare_and_delete(key, expected, opts) do
      available_call(opts, fn -> ETS.compare_and_delete(key, expected, opts) end)
    end

    @impl true
    def durability_class(_opts), do: :node_restart

    defp available_call(opts, operation) do
      if Agent.get(Keyword.fetch!(opts, :control), & &1.available),
        do: operation.(),
        else: {:error, :forced_failure}
    end
  end

  setup do
    DurableGraphAuthority.start!()

    agent_id = "agent_init_authority_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      _ = IndexSupervisor.stop_index(agent_id)
      _ = KnowledgeGraphStore.delete_graph(agent_id)
      _ = Provenance.delete_agent(agent_id)
      :ets.delete(@graph_ets, agent_id)
    end)

    %{agent_id: agent_id}
  end

  test "public init creates a graph only after exact authoritative absence", %{
    agent_id: agent_id
  } do
    subscribe_to_initialization(agent_id)

    assert {:ok, nil} =
             Memory.init_for_agent(agent_id,
               index_enabled: false,
               graph_enabled: true,
               auto_embed: false
             )

    assert {:ok, %KnowledgeGraph{agent_id: ^agent_id}} = KnowledgeGraphStore.get_graph(agent_id)

    assert {:ok, %TaintedValue{}, :verified, %Record{revision: 1}, :namespaced} =
             MemoryStore.load_tainted_authoritative_with_status("knowledge_graph", agent_id)

    assert_receive {:memory_initialized, ^agent_id}
  end

  test "public init security regression refuses backend outage without save, signal, or index", %{
    agent_id: agent_id
  } do
    {backend_name, control} = install_switchable_backend(false)
    subscribe_to_initialization(agent_id)

    assert {:error, :store_unavailable} =
             Memory.init_for_agent(agent_id,
               index_enabled: true,
               graph_enabled: true,
               auto_embed: false
             )

    refute IndexSupervisor.has_index?(agent_id)
    refute_receive {:memory_initialized, ^agent_id}, 100
    assert Agent.get(control, & &1.cas_calls) == 0

    Agent.update(control, &%{&1 | available: true})

    assert {:error, :not_found} =
             Arbor.Persistence.QueryableStore.ETS.get(
               "knowledge_graph:#{agent_id}",
               name: backend_name
             )

    assert {:error, :graph_not_initialized} = KnowledgeGraphStore.get_graph(agent_id)
  end

  test "public init security regression refuses malformed authority without overwrite", %{
    agent_id: agent_id
  } do
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)

    assert {:ok, snapshot} =
             Codec.reconcile(agent_id, graph, nil, TaintEnvelope.missing_fallback())

    assert {:ok, wrapper} = Codec.encode(snapshot)
    malformed = Map.delete(wrapper, "provenance")

    assert {:ok, %Record{revision: revision}} =
             MemoryStore.compare_and_swap_tainted(
               "knowledge_graph",
               agent_id,
               :not_found,
               malformed,
               taint: TaintEnvelope.missing_fallback()
             )

    subscribe_to_initialization(agent_id)

    assert {:error, :invalid_provenance} =
             Memory.init_for_agent(agent_id,
               index_enabled: true,
               graph_enabled: true,
               auto_embed: false
             )

    refute IndexSupervisor.has_index?(agent_id)
    refute_receive {:memory_initialized, ^agent_id}, 100

    assert {:ok, %TaintedValue{value: ^malformed}, :verified, %Record{revision: ^revision},
            :namespaced} =
             MemoryStore.load_tainted_authoritative_with_status("knowledge_graph", agent_id)
  end

  test "public init propagates a create conflict without signal or index", %{
    agent_id: agent_id
  } do
    {backend_name, control} = install_switchable_backend(true, :conflict)
    subscribe_to_initialization(agent_id)

    assert {:error, :conflict} =
             Memory.init_for_agent(agent_id,
               index_enabled: true,
               graph_enabled: true,
               auto_embed: false
             )

    refute IndexSupervisor.has_index?(agent_id)
    refute_receive {:memory_initialized, ^agent_id}, 100
    assert Agent.get(control, & &1.cas_calls) > 0

    assert {:error, :not_found} =
             Arbor.Persistence.QueryableStore.ETS.get(
               "knowledge_graph:#{agent_id}",
               name: backend_name
             )
  end

  defp install_switchable_backend(available, cas_mode \\ :normal) do
    stop_supervised!(BufferedStore)
    backend_name = unique_name(:init_authority_backend)
    control = unique_name(:init_authority_control)

    start_supervised!({Arbor.Persistence.QueryableStore.ETS, name: backend_name})

    start_supervised!(%{
      id: control,
      start:
        {Agent, :start_link,
         [fn -> %{available: available, cas_calls: 0, cas_mode: cas_mode} end, [name: control]]}
    })

    start_supervised!(
      {BufferedStore,
       name: @store_name,
       backend: SwitchableBackend,
       backend_opts: [control: control],
       collection: backend_name,
       write_mode: :sync}
    )

    {backend_name, control}
  end

  defp subscribe_to_initialization(agent_id) do
    parent = self()

    assert {:ok, subscription_id} =
             Arbor.Signals.subscribe("memory.initialized", fn
               %{data: %{agent_id: ^agent_id}} ->
                 send(parent, {:memory_initialized, agent_id})
                 :ok

               _signal ->
                 :ok
             end)

    on_exit(fn -> Arbor.Signals.unsubscribe(subscription_id) end)
    subscription_id
  end

  defp unique_name(prefix),
    do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end
