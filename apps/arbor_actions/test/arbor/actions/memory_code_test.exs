defmodule Arbor.Actions.MemoryCodeTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.MemoryCode

  @moduletag :fast

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
      assert MemoryCode.StoreCode.name() == "memory_store_code"
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
      assert MemoryCode.ListCode.name() == "memory_list_code"
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
      assert MemoryCode.DeleteCode.name() == "memory_delete_code"
      assert "delete" in MemoryCode.DeleteCode.tags()
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
      assert MemoryCode.ViewCode.name() == "memory_view_code"
      assert "view" in MemoryCode.ViewCode.tags()
    end

    test "generates tool schema" do
      tool = MemoryCode.ViewCode.to_tool()
      assert is_map(tool)
      assert tool[:name] == "memory_view_code"
    end
  end
end
