defmodule Arbor.Actions.MemoryCodeTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.MemoryCode

  @moduletag :fast

  defmodule ConfirmingVectorSeam do
    @moduledoc false
    @behaviour Arbor.Memory.StrictVectorSeam

    @impl true
    def encode_operation(_input), do: {:error, :unsupported}

    @impl true
    def encode_batch(_inputs), do: {:error, :unsupported}

    @impl true
    def execute(_agent_id, _input, _opts \\ []), do: {:error, :unsupported}

    @impl true
    def reconcile(_agent_id, _input, _opts \\ []), do: {:error, :unsupported}

    @impl true
    def search(_agent_id, _vector, _opts \\ []), do: {:error, :unsupported}

    @impl true
    def fetch(_agent_id, _namespace, _key, _opts \\ []), do: {:error, :not_found}

    @impl true
    def list(_agent_id, _opts \\ []), do: {:ok, []}

    @impl true
    def destroy(_agent_id, _opts \\ []), do: :ok
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:arbor_memory)

    for table <- [
          :arbor_memory_graphs,
          :arbor_working_memory,
          :arbor_memory_proposals,
          :arbor_chat_history,
          :arbor_preferences
        ] do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, :set])
      end
    end

    children = [
      {Registry, keys: :unique, name: Arbor.Memory.Registry},
      {Arbor.Memory.IndexSupervisor, []},
      {Arbor.Persistence.EventLog.ETS, name: :memory_events},
      {Arbor.Memory.GoalStore, []},
      {Arbor.Memory.IntentStore, []},
      {Arbor.Memory.Thinking, []},
      {Arbor.Memory.CodeStore, []}
    ]

    for child <- children do
      Supervisor.start_child(Arbor.Memory.Supervisor, child)
    end

    :ok
  end

  setup do
    agent_id = "test_agent_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Arbor.Memory.init_for_agent(agent_id)

    on_exit(fn ->
      Arbor.Memory.cleanup_for_agent(agent_id)
    end)

    {:ok, agent_id: agent_id, context: %{agent_id: agent_id}}
  end

  # ============================================================================
  # StoreCode
  # ============================================================================

  describe "StoreCode" do
    test "stores a code pattern", %{context: ctx} do
      assert {:ok, result} =
               MemoryCode.StoreCode.run(
                 %{
                   code: "Enum.map(list, & &1 * 2)",
                   language: "elixir",
                   purpose: "Double all elements"
                 },
                 ctx
               )

      assert result.entry_id
      assert result.stored == true
      assert result.language == "elixir"
    end

    test "returns error without agent_id" do
      assert {:error, :missing_agent_id} =
               MemoryCode.StoreCode.run(
                 %{code: "test", language: "elixir", purpose: "test"},
                 %{}
               )
    end

    test "validates action metadata" do
      assert MemoryCode.StoreCode.name() == "code_pattern_store"
      assert MemoryCode.StoreCode.category() == "memory_code"
      assert "store" in MemoryCode.StoreCode.tags()
    end

    test "has taint roles" do
      roles = MemoryCode.StoreCode.taint_roles()
      assert roles[:language] == :control
      assert roles[:code] == :data
    end
  end

  # ============================================================================
  # ListCode
  # ============================================================================

  describe "ListCode" do
    test "lists code patterns", %{agent_id: agent_id, context: ctx} do
      Arbor.Memory.store_code(agent_id, %{
        code: "IO.puts/1",
        language: "elixir",
        purpose: "Print to stdout"
      })

      assert {:ok, result} =
               MemoryCode.ListCode.run(%{}, ctx)

      assert result.count >= 1
    end

    test "filters by language", %{agent_id: agent_id, context: ctx} do
      Arbor.Memory.store_code(agent_id, %{
        code: "print('hello')",
        language: "python",
        purpose: "Print hello"
      })

      Arbor.Memory.store_code(agent_id, %{
        code: "IO.puts('hello')",
        language: "elixir",
        purpose: "Print hello"
      })

      assert {:ok, result} =
               MemoryCode.ListCode.run(%{language: "python"}, ctx)

      assert Enum.all?(result.entries, &(&1.language == "python"))
    end

    test "returns error without agent_id" do
      assert {:error, :missing_agent_id} =
               MemoryCode.ListCode.run(%{}, %{})
    end

    test "validates action metadata" do
      assert MemoryCode.ListCode.name() == "code_pattern_list"
      assert "list" in MemoryCode.ListCode.tags()
    end
  end

  # ============================================================================
  # DeleteCode
  # ============================================================================

  describe "DeleteCode" do
    test "deletes a code pattern", %{agent_id: agent_id, context: ctx} do
      {:ok, entry} =
        Arbor.Memory.store_code(agent_id, %{
          code: "to_delete",
          language: "elixir",
          purpose: "Delete me"
        })

      previous = Application.fetch_env(:arbor_memory, :strict_vector_seam)
      Application.put_env(:arbor_memory, :strict_vector_seam, ConfirmingVectorSeam)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:arbor_memory, :strict_vector_seam, value)
          :error -> Application.delete_env(:arbor_memory, :strict_vector_seam)
        end
      end)

      assert {:ok, result} =
               MemoryCode.DeleteCode.run(%{entry_id: entry.id}, ctx)

      assert result.deleted == true

      # Verify it's gone
      assert Arbor.Memory.list_code(agent_id) == []
    end

    test "returns error without agent_id" do
      assert {:error, :missing_agent_id} =
               MemoryCode.DeleteCode.run(%{entry_id: "some_id"}, %{})
    end

    test "validates action metadata" do
      assert MemoryCode.DeleteCode.name() == "code_pattern_delete"
      assert "delete" in MemoryCode.DeleteCode.tags()
    end

    test "returns structured failure and emits failed when delete_code cannot confirm cleanup",
         %{agent_id: agent_id, context: ctx} do
      {:ok, entry} =
        Arbor.Memory.store_code(agent_id, %{
          code: "to_fail_closed",
          language: "elixir",
          purpose: "surface cleanup failure"
        })

      parent = self()

      {:ok, failed_id} =
        Arbor.Signals.subscribe("action.failed", fn signal ->
          send(parent, {:action_signal, :failed, signal})
          :ok
        end)

      on_exit(fn -> Arbor.Signals.unsubscribe(failed_id) end)

      stop_knowledge_graph_store!()

      assert {:error, :store_unavailable} =
               MemoryCode.DeleteCode.run(%{entry_id: entry.id}, ctx)

      assert_receive {:action_signal, :failed, signal}, 1_000
      assert signal.data.action == "code_pattern_delete"
      assert signal.data.error == inspect(:store_unavailable)
    after
      restart_knowledge_graph_store!()
    end
  end

  # ============================================================================
  # ViewCode
  # ============================================================================

  describe "ViewCode" do
    test "views by entry_id", %{agent_id: agent_id, context: ctx} do
      {:ok, entry} =
        Arbor.Memory.store_code(agent_id, %{
          code: "def hello, do: :world",
          language: "elixir",
          purpose: "Hello world function"
        })

      assert {:ok, result} =
               MemoryCode.ViewCode.run(%{entry_id: entry.id}, ctx)

      assert result.code == "def hello, do: :world"
      assert result.language == "elixir"
    end

    test "searches by purpose", %{agent_id: agent_id, context: ctx} do
      Arbor.Memory.store_code(agent_id, %{
        code: "Enum.sort/1",
        language: "elixir",
        purpose: "Sort a list"
      })

      assert {:ok, result} =
               MemoryCode.ViewCode.run(%{query: "sort"}, ctx)

      assert result.count >= 1
    end

    test "returns not_found for unknown ID", %{context: ctx} do
      assert {:error, :not_found} =
               MemoryCode.ViewCode.run(%{entry_id: "nonexistent"}, ctx)
    end

    test "requires entry_id or query", %{context: ctx} do
      assert {:error, :entry_id_or_query_required} =
               MemoryCode.ViewCode.run(%{}, ctx)
    end

    test "returns error without agent_id" do
      assert {:error, :missing_agent_id} =
               MemoryCode.ViewCode.run(%{entry_id: "some_id"}, %{})
    end

    test "validates action metadata" do
      assert MemoryCode.ViewCode.name() == "code_pattern_view"
      assert "view" in MemoryCode.ViewCode.tags()
    end

    test "generates tool schema" do
      tool = MemoryCode.ViewCode.to_tool()
      assert is_map(tool)
      assert tool[:name] == "code_pattern_view"
    end
  end

  defp stop_knowledge_graph_store! do
    case Process.whereis(Arbor.Memory.KnowledgeGraphStore) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)

        :ok =
          Supervisor.terminate_child(Arbor.Memory.Supervisor, Arbor.Memory.KnowledgeGraphStore)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end

      nil ->
        :ok
    end
  end

  defp restart_knowledge_graph_store! do
    case Supervisor.restart_child(Arbor.Memory.Supervisor, Arbor.Memory.KnowledgeGraphStore) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :not_found} -> start_knowledge_graph_store!()
      {:error, _reason} -> start_knowledge_graph_store!()
    end
  end

  defp start_knowledge_graph_store! do
    case Supervisor.start_child(Arbor.Memory.Supervisor, {Arbor.Memory.KnowledgeGraphStore, []}) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :already_present} -> restart_knowledge_graph_store!()
    end
  end
end
