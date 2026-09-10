defmodule Arbor.Memory.ModelOutputPersistenceTest do
  use ExUnit.Case, async: false

  alias Arbor.Memory
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Persistence
  alias Arbor.Persistence.{BufferedStore, QueryableStore}

  @moduletag :fast
  @moduletag :integration
  @store :arbor_memory_durable

  defmodule Backend do
    @behaviour Arbor.Contracts.Persistence.Store

    alias Arbor.Persistence.QueryableStore.ETS

    @impl true
    def put(key, value, opts), do: write(opts, fn -> ETS.put(key, value, opts) end)
    @impl true
    def get(key, opts), do: read(opts, fn -> ETS.get(key, opts) end)
    @impl true
    def delete(key, opts), do: write(opts, fn -> ETS.delete(key, opts) end)
    @impl true
    def list(opts), do: read(opts, fn -> ETS.list(opts) end)
    @impl true
    def query(filter, opts), do: read(opts, fn -> ETS.query(filter, opts) end)
    @impl true
    def compare_and_swap(key, expected, replacement, opts),
      do: write(opts, fn -> ETS.compare_and_swap(key, expected, replacement, opts) end)

    @impl true
    def compare_and_delete(key, expected, opts),
      do: write(opts, fn -> ETS.compare_and_delete(key, expected, opts) end)

    @impl true
    def durability_class(_opts), do: :node_restart

    defp read(opts, fun) do
      if Agent.get(Keyword.fetch!(opts, :control), fn {mode, _observer} -> mode end) ==
           :read_error,
         do: {:error, :fixture_read_failure},
         else: fun.()
    end

    defp write(opts, fun) do
      control = Keyword.fetch!(opts, :control)
      send(Agent.get(control, fn {_mode, observer} -> observer end), :backend_write)

      if Agent.get(control, fn {mode, _observer} -> mode end) == :write_error,
        do: {:error, :fixture_write_failure},
        else: fun.()
    end
  end

  setup do
    assert Process.whereis(@store) == nil
    observer = self()
    control = start_supervised!({Agent, fn -> {:available, observer} end})
    backend_name = Module.concat(__MODULE__, Records)
    start_supervised!({QueryableStore.ETS, name: backend_name})

    opts = [
      name: @store,
      backend: Backend,
      backend_opts: [control: control],
      collection: backend_name,
      write_mode: :sync,
      ack_mode: :backend
    ]

    start_supervised!({BufferedStore, opts})
    agent_id = "agent_model_output_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      # These are test-owned projections, not observations of domain behavior.
      for table <- [:arbor_working_memory, :arbor_self_knowledge],
          :ets.whereis(table) != :undefined do
        :ets.delete(table, agent_id)
      end
    end)

    %{agent_id: agent_id, control: control, backend_name: backend_name, store_opts: opts}
  end

  test "note write regression: mixed notes report saved transformations and skip malformed inputs",
       %{agent_id: agent} do
    notes = [nil, "", "   ", %{"text" => 10}, "first note", %{text: "second note"}]

    assert {:ok, %{updated: true, applied_count: 2, skipped_count: 4, error_count: 0}} =
             Memory.index_memory_notes(agent, %{"session.memory_notes" => notes})

    assert Enum.map(Memory.get_working_memory(agent).recent_thoughts, & &1.content) ==
             ["second note", "first note"]
  end

  test "empty and invalid notes never initialize working memory or call the backend", %{
    agent_id: agent
  } do
    for input <- [nil, [], %{}, %{memory_notes: []}, %{"memory_notes" => nil}] do
      assert {:ok, %{updated: false, applied_count: 0, skipped_count: 0, error_count: 0}} =
               Memory.index_memory_notes(agent, input)
    end

    assert {:ok, %{updated: false, applied_count: 0, skipped_count: 3}} =
             Memory.index_memory_notes(agent, [false, 42, %{text: nil}])

    for key <- [:memory_notes, "memory_notes", "session.memory_notes"] do
      assert {:ok, %{updated: false, applied_count: 0, skipped_count: 1}} =
               Memory.index_memory_notes(agent, %{key => false})
    end

    refute_received :backend_write
    assert Memory.get_working_memory(agent) == nil
  end

  test "combined updates save notes once and restore the same content from the backend", ctx do
    updates = %{
      "session.memory_notes" => ["one thought", %{"text" => "second thought"}],
      "session.concerns" => [false, "test concern"],
      "session.curiosity" => ["test question", ""]
    }

    assert {:ok, %{updated: true, applied_count: 4, skipped_count: 2, error_count: 0}} =
             Memory.apply_working_memory_updates(ctx.agent_id, updates)

    before = Memory.get_working_memory(ctx.agent_id)
    assert length(before.recent_thoughts) == 2
    assert before.concerns == ["test concern"]
    assert before.curiosity == ["test question"]

    assert {:ok, record} =
             Persistence.get(@store, BufferedStore, "working_memory:#{ctx.agent_id}")

    assert record.data["payload"]["concerns"] == ["test concern"]

    # Owned BufferedStore process restart and projection eviction; the fixture
    # backend stays alive. This is not database or whole-BEAM durability.
    assert :ok = stop_supervised(BufferedStore)
    :ets.delete(:arbor_working_memory, ctx.agent_id)
    start_supervised!({BufferedStore, ctx.store_opts})
    assert Memory.get_working_memory(ctx.agent_id) == before
  end

  test "save error regression: rejected storage never reports applied notes", ctx do
    assert {:ok, _} = Memory.index_memory_notes(ctx.agent_id, ["existing thought"])
    before = Memory.get_working_memory(ctx.agent_id)
    set_mode(ctx.control, :write_error)

    assert {:error, %{updated: false, applied_count: 0, error_count: 1, errors: [_]}} =
             Memory.index_memory_notes(ctx.agent_id, ["rejected thought"])

    set_mode(ctx.control, :available)
    assert Memory.get_working_memory(ctx.agent_id) == before
  end

  test "failed authoritative read cannot replace an existing memory with fresh content", ctx do
    assert {:ok, _} = Memory.index_memory_notes(ctx.agent_id, ["existing thought"])
    before = Memory.get_working_memory(ctx.agent_id)
    set_mode(ctx.control, :read_error)

    assert {:error, %{updated: false, applied_count: 0, error_count: 1}} =
             Memory.index_memory_notes(ctx.agent_id, ["new thought"])

    set_mode(ctx.control, :available)
    assert Memory.get_working_memory(ctx.agent_id) == before
  end

  test "identity save error regression: public insight creation propagates refused admission", %{
    agent_id: agent
  } do
    assert Memory.get_self_knowledge(agent) == nil
    assert {:ok, _fence} = MutationAdmission.drain(agent, timeout_ms: 1_000)

    for category <- [:capability, :skill, :personality, :trait, :value] do
      assert {:error, :store_unavailable} =
               Memory.add_insight(agent, "must not be accepted", category)
    end

    assert Memory.get_self_knowledge(agent) == nil
  end

  defp set_mode(control, mode),
    do: Agent.update(control, fn {_old, observer} -> {mode, observer} end)
end
