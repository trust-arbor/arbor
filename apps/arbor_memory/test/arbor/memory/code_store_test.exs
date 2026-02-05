defmodule Arbor.Memory.CodeStoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.CodeStore

  @moduletag :fast

  setup do
    agent_id = "test_agent_#{System.unique_integer([:positive])}"
    on_exit(fn -> CodeStore.clear(agent_id) end)
    %{agent_id: agent_id}
  end

  describe "store/2" do
    test "stores a code pattern", %{agent_id: agent_id} do
      assert {:ok, entry} =
               CodeStore.store(agent_id, %{
                 code: "Enum.map(list, & &1 * 2)",
                 language: "elixir",
                 purpose: "Double all elements in a list"
               })

      assert entry.agent_id == agent_id
      assert entry.code == "Enum.map(list, & &1 * 2)"
      assert entry.language == "elixir"
      assert entry.purpose == "Double all elements in a list"
      assert String.starts_with?(entry.id, "code_")
    end

    test "stores with metadata", %{agent_id: agent_id} do
      assert {:ok, entry} =
               CodeStore.store(agent_id, %{
                 code: "def foo, do: :bar",
                 language: "elixir",
                 purpose: "Simple function",
                 metadata: %{source: "learned", confidence: 0.9}
               })

      assert entry.metadata == %{source: "learned", confidence: 0.9}
    end

    test "returns error for missing fields", %{agent_id: agent_id} do
      assert {:error, :missing_fields} =
               CodeStore.store(agent_id, %{code: "some code"})
    end

    test "returns error for invalid params", %{agent_id: agent_id} do
      assert {:error, :missing_fields} = CodeStore.store(agent_id, %{})
    end
  end

  describe "find_by_purpose/2" do
    test "finds patterns by keyword in purpose", %{agent_id: agent_id} do
      CodeStore.store(agent_id, %{
        code: "use GenServer",
        language: "elixir",
        purpose: "GenServer boilerplate template"
      })

      CodeStore.store(agent_id, %{
        code: "def handle_call",
        language: "elixir",
        purpose: "Handle synchronous GenServer call"
      })

      CodeStore.store(agent_id, %{
        code: "defstruct",
        language: "elixir",
        purpose: "Define a struct"
      })

      results = CodeStore.find_by_purpose(agent_id, "genserver")
      assert length(results) == 2
    end

    test "search is case-insensitive", %{agent_id: agent_id} do
      CodeStore.store(agent_id, %{
        code: "SELECT * FROM users",
        language: "sql",
        purpose: "Query all users from database"
      })

      assert length(CodeStore.find_by_purpose(agent_id, "DATABASE")) == 1
      assert length(CodeStore.find_by_purpose(agent_id, "database")) == 1
    end

    test "returns empty list for no matches", %{agent_id: agent_id} do
      CodeStore.store(agent_id, %{
        code: "def foo, do: :bar",
        language: "elixir",
        purpose: "Simple function"
      })

      assert CodeStore.find_by_purpose(agent_id, "quantum computing") == []
    end
  end

  describe "list/2" do
    test "lists all patterns for an agent", %{agent_id: agent_id} do
      CodeStore.store(agent_id, %{
        code: "code1",
        language: "elixir",
        purpose: "Purpose 1"
      })

      CodeStore.store(agent_id, %{
        code: "code2",
        language: "python",
        purpose: "Purpose 2"
      })

      assert length(CodeStore.list(agent_id)) == 2
    end

    test "filters by language", %{agent_id: agent_id} do
      CodeStore.store(agent_id, %{
        code: "elixir_code",
        language: "elixir",
        purpose: "Elixir pattern"
      })

      CodeStore.store(agent_id, %{
        code: "python_code",
        language: "python",
        purpose: "Python pattern"
      })

      elixir_only = CodeStore.list(agent_id, language: "elixir")
      assert length(elixir_only) == 1
      assert hd(elixir_only).language == "elixir"
    end

    test "respects limit", %{agent_id: agent_id} do
      for i <- 1..5 do
        CodeStore.store(agent_id, %{
          code: "code_#{i}",
          language: "elixir",
          purpose: "Purpose #{i}"
        })
      end

      assert length(CodeStore.list(agent_id, limit: 3)) == 3
    end

    test "returns empty list for new agent", %{agent_id: agent_id} do
      assert CodeStore.list(agent_id) == []
    end
  end

  describe "delete/2" do
    test "removes a specific pattern", %{agent_id: agent_id} do
      {:ok, entry} =
        CodeStore.store(agent_id, %{
          code: "deleteme",
          language: "elixir",
          purpose: "Will be deleted"
        })

      CodeStore.store(agent_id, %{
        code: "keepme",
        language: "elixir",
        purpose: "Will be kept"
      })

      assert :ok = CodeStore.delete(agent_id, entry.id)
      assert length(CodeStore.list(agent_id)) == 1
      assert hd(CodeStore.list(agent_id)).code == "keepme"
    end
  end

  describe "clear/1" do
    test "removes all patterns for an agent", %{agent_id: agent_id} do
      CodeStore.store(agent_id, %{
        code: "code1",
        language: "elixir",
        purpose: "Purpose 1"
      })

      CodeStore.clear(agent_id)
      assert CodeStore.list(agent_id) == []
    end
  end

  describe "agent isolation" do
    test "patterns are isolated per agent" do
      agent_a = "agent_a_#{System.unique_integer([:positive])}"
      agent_b = "agent_b_#{System.unique_integer([:positive])}"

      CodeStore.store(agent_a, %{
        code: "agent_a_code",
        language: "elixir",
        purpose: "Agent A pattern"
      })

      assert [_] = CodeStore.list(agent_a)
      assert CodeStore.list(agent_b) == []

      CodeStore.clear(agent_a)
      CodeStore.clear(agent_b)
    end
  end
end
