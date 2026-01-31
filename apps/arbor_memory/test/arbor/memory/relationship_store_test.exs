defmodule Arbor.Memory.RelationshipStoreTest do
  @moduledoc """
  Tests for the PostgreSQL RelationshipStore backend.

  ## Setup Required

  These tests require a running PostgreSQL database:

      mix ecto.create -r Arbor.Persistence.Repo
      mix ecto.migrate -r Arbor.Persistence.Repo

  ## Running

      mix test --include database

  Or for just this file:

      mix test apps/arbor_memory/test/arbor/memory/relationship_store_test.exs --include database
  """

  use ExUnit.Case, async: false

  alias Arbor.Memory.{Relationship, RelationshipStore}
  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.Relationship, as: RelationshipSchema

  @moduletag :integration
  @moduletag :database

  setup_all do
    case Repo.start_link() do
      {:ok, pid} -> {:ok, repo_pid: pid}
      {:error, {:already_started, pid}} -> {:ok, repo_pid: pid}
      {:error, reason} -> {:skip, "Database not available: #{inspect(reason)}"}
    end
  end

  setup do
    # Clean up relationships table before each test
    Repo.delete_all(RelationshipSchema)
    {:ok, agent_id: "test_agent_001"}
  end

  # ===========================================================================
  # CRUD Operations
  # ===========================================================================

  describe "put/2 and get/2" do
    test "stores and retrieves a relationship", %{agent_id: agent_id} do
      rel = Relationship.new("Hysun", relationship_dynamic: "Partnership")
      {:ok, saved_rel} = RelationshipStore.put(agent_id, rel)

      assert saved_rel.name == "Hysun"
      assert saved_rel.relationship_dynamic == "Partnership"
      assert saved_rel.id != nil

      # Retrieve by ID
      {:ok, retrieved} = RelationshipStore.get(agent_id, saved_rel.id)
      assert retrieved.name == "Hysun"
      assert retrieved.relationship_dynamic == "Partnership"
    end

    test "upserts on conflict — updates existing relationship", %{agent_id: agent_id} do
      rel1 = Relationship.new("Hysun", relationship_dynamic: "Old dynamic")
      {:ok, saved1} = RelationshipStore.put(agent_id, rel1)

      # Update with same name
      rel2 =
        Relationship.new("Hysun", relationship_dynamic: "New dynamic")
        |> Map.put(:id, saved1.id)

      {:ok, saved2} = RelationshipStore.put(agent_id, rel2)

      # Should have same ID but updated dynamic
      {:ok, retrieved} = RelationshipStore.get(agent_id, saved2.id)
      assert retrieved.relationship_dynamic == "New dynamic"
    end

    test "agent_ids are isolated", %{} do
      rel = Relationship.new("Same Name")
      {:ok, _} = RelationshipStore.put("agent_a", rel)

      rel2 = Relationship.new("Same Name")
      {:ok, _} = RelationshipStore.put("agent_b", rel2)

      {:ok, a_rels} = RelationshipStore.list("agent_a")
      {:ok, b_rels} = RelationshipStore.list("agent_b")

      assert length(a_rels) == 1
      assert length(b_rels) == 1
    end

    test "returns not_found for missing relationship", %{agent_id: agent_id} do
      assert {:error, :not_found} = RelationshipStore.get(agent_id, "nonexistent_id")
    end
  end

  describe "get_by_name/2" do
    test "retrieves relationship by name", %{agent_id: agent_id} do
      rel = Relationship.new("Hysun", preferred_name: "H")
      {:ok, _} = RelationshipStore.put(agent_id, rel)

      {:ok, retrieved} = RelationshipStore.get_by_name(agent_id, "Hysun")
      assert retrieved.name == "Hysun"
      assert retrieved.preferred_name == "H"
    end

    test "returns not_found for missing name", %{agent_id: agent_id} do
      assert {:error, :not_found} = RelationshipStore.get_by_name(agent_id, "Unknown")
    end
  end

  describe "list/2" do
    test "returns all relationships for agent", %{agent_id: agent_id} do
      for name <- ["Alice", "Bob", "Carol"] do
        {:ok, _} = RelationshipStore.put(agent_id, Relationship.new(name))
      end

      {:ok, rels} = RelationshipStore.list(agent_id)
      names = Enum.map(rels, & &1.name) |> Enum.sort()
      assert names == ["Alice", "Bob", "Carol"]
    end

    test "sorts by salience by default (descending)", %{agent_id: agent_id} do
      {:ok, _} =
        RelationshipStore.put(agent_id, Relationship.new("Low", salience: 0.3))

      {:ok, _} =
        RelationshipStore.put(agent_id, Relationship.new("High", salience: 0.9))

      {:ok, _} =
        RelationshipStore.put(agent_id, Relationship.new("Medium", salience: 0.6))

      {:ok, rels} = RelationshipStore.list(agent_id)
      saliences = Enum.map(rels, & &1.salience)
      assert saliences == Enum.sort(saliences, :desc)
    end

    test "supports sort_by option", %{agent_id: agent_id} do
      for name <- ["Charlie", "Alice", "Bob"] do
        {:ok, _} = RelationshipStore.put(agent_id, Relationship.new(name))
      end

      {:ok, rels} = RelationshipStore.list(agent_id, sort_by: :name, sort_dir: :asc)
      names = Enum.map(rels, & &1.name)
      assert names == ["Alice", "Bob", "Charlie"]
    end

    test "supports limit option", %{agent_id: agent_id} do
      for i <- 1..5 do
        {:ok, _} = RelationshipStore.put(agent_id, Relationship.new("Rel #{i}"))
      end

      {:ok, rels} = RelationshipStore.list(agent_id, limit: 2)
      assert length(rels) == 2
    end

    test "returns empty list for agent with no relationships", %{} do
      {:ok, rels} = RelationshipStore.list("empty_agent")
      assert rels == []
    end
  end

  describe "delete/2" do
    test "removes a relationship", %{agent_id: agent_id} do
      rel = Relationship.new("ToDelete")
      {:ok, saved} = RelationshipStore.put(agent_id, rel)

      assert :ok = RelationshipStore.delete(agent_id, saved.id)
      assert {:error, :not_found} = RelationshipStore.get(agent_id, saved.id)
    end

    test "returns not_found for missing relationship", %{agent_id: agent_id} do
      assert {:error, :not_found} = RelationshipStore.delete(agent_id, "nonexistent")
    end
  end

  describe "update/3" do
    test "updates specific fields", %{agent_id: agent_id} do
      rel = Relationship.new("Test", salience: 0.5)
      {:ok, saved} = RelationshipStore.put(agent_id, rel)

      {:ok, updated} = RelationshipStore.update(agent_id, saved.id, %{salience: 0.9})
      assert updated.salience == 0.9
      assert updated.name == "Test"
    end

    test "returns not_found for missing relationship", %{agent_id: agent_id} do
      assert {:error, :not_found} = RelationshipStore.update(agent_id, "nonexistent", %{salience: 0.9})
    end
  end

  describe "get_primary/1" do
    test "returns relationship with highest salience", %{agent_id: agent_id} do
      {:ok, _} = RelationshipStore.put(agent_id, Relationship.new("Low", salience: 0.3))
      {:ok, _} = RelationshipStore.put(agent_id, Relationship.new("High", salience: 0.9))
      {:ok, _} = RelationshipStore.put(agent_id, Relationship.new("Medium", salience: 0.6))

      {:ok, primary} = RelationshipStore.get_primary(agent_id)
      assert primary.name == "High"
      assert primary.salience == 0.9
    end

    test "returns not_found when no relationships exist", %{} do
      assert {:error, :not_found} = RelationshipStore.get_primary("empty_agent")
    end
  end

  describe "touch/2" do
    test "updates access tracking", %{agent_id: agent_id} do
      rel = Relationship.new("Test")
      {:ok, saved} = RelationshipStore.put(agent_id, rel)

      original_count = saved.access_count
      original_time = saved.last_interaction

      # Small delay to ensure timestamp differs
      Process.sleep(10)

      {:ok, touched} = RelationshipStore.touch(agent_id, saved.id)

      assert touched.access_count == original_count + 1
      assert DateTime.compare(touched.last_interaction, original_time) == :gt
    end
  end

  describe "count/1" do
    test "returns relationship count for agent", %{agent_id: agent_id} do
      for i <- 1..3 do
        {:ok, _} = RelationshipStore.put(agent_id, Relationship.new("Rel #{i}"))
      end

      {:ok, count} = RelationshipStore.count(agent_id)
      assert count == 3
    end

    test "returns 0 for agent with no relationships", %{} do
      {:ok, count} = RelationshipStore.count("empty_agent")
      assert count == 0
    end
  end

  # ===========================================================================
  # Complex Data Persistence
  # ===========================================================================

  describe "complex data persistence" do
    test "persists and restores key moments", %{agent_id: agent_id} do
      rel =
        Relationship.new("Test")
        |> Relationship.add_moment("First meeting", emotional_markers: [:connection], salience: 0.8)
        |> Relationship.add_moment("Breakthrough", emotional_markers: [:insight, :joy], salience: 0.9)

      {:ok, saved} = RelationshipStore.put(agent_id, rel)
      {:ok, retrieved} = RelationshipStore.get(agent_id, saved.id)

      assert length(retrieved.key_moments) == 2

      [moment2, moment1] = retrieved.key_moments
      assert moment1.summary == "First meeting"
      assert :connection in moment1.emotional_markers
      assert moment1.salience == 0.8

      assert moment2.summary == "Breakthrough"
      assert :insight in moment2.emotional_markers
      assert :joy in moment2.emotional_markers
    end

    test "persists and restores all list fields", %{agent_id: agent_id} do
      rel =
        Relationship.new("Test", preferred_name: "T", relationship_dynamic: "Partnership")
        |> Relationship.add_background("Engineer")
        |> Relationship.add_background("Creator of Arbor")
        |> Relationship.add_value("Treats AI with respect")
        |> Relationship.add_value("Values collaboration")
        |> Relationship.add_connection("Works at Company X")
        |> Relationship.add_personal_detail("Has cats")
        |> Relationship.update_focus(["Project A", "Project B"])
        |> Relationship.add_uncertainty("Timezone unclear")

      {:ok, saved} = RelationshipStore.put(agent_id, rel)
      {:ok, retrieved} = RelationshipStore.get(agent_id, saved.id)

      assert retrieved.preferred_name == "T"
      assert retrieved.relationship_dynamic == "Partnership"
      assert length(retrieved.background) == 2
      assert length(retrieved.values) == 2
      assert length(retrieved.connections) == 1
      assert length(retrieved.personal_details) == 1
      assert length(retrieved.current_focus) == 2
      assert length(retrieved.uncertainties) == 1
    end

    test "persists timestamps correctly", %{agent_id: agent_id} do
      rel = Relationship.new("Test")
      {:ok, saved} = RelationshipStore.put(agent_id, rel)
      {:ok, retrieved} = RelationshipStore.get(agent_id, saved.id)

      assert retrieved.first_encountered != nil
      assert retrieved.last_interaction != nil
      assert %DateTime{} = retrieved.first_encountered
      assert %DateTime{} = retrieved.last_interaction
    end
  end
end
