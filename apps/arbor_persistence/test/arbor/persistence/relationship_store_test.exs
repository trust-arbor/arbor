defmodule Arbor.Persistence.RelationshipStoreTest do
  @moduledoc """
  Persistence-facade contract tests for tenant-scoped relationships (VP-05D2C3I0A).
  """

  use Arbor.Persistence.DatabaseCase, async: false

  import Ecto.Query

  alias Arbor.Persistence
  alias Arbor.Persistence.RelationshipStore
  alias Arbor.Persistence.Schemas.Relationship, as: RelationshipSchema

  @moduletag :integration
  @moduletag :database
  @moduletag spec: "VP-05D2C3I0A"

  setup do
    for agent <- ~w(rel_agent_a rel_agent_b rel_agent_empty) do
      :ok = Persistence.delete_all_relationships(agent)
    end

    {:ok, agent: "rel_agent_a", other: "rel_agent_b"}
  end

  defp base_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        id: "rel_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
        name: "Person",
        preferred_name: nil,
        background: [],
        values: [],
        connections: [],
        key_moments: [],
        relationship_dynamic: nil,
        personal_details: [],
        current_focus: [],
        uncertainties: [],
        first_encountered: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        last_interaction: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        salience: 0.5,
        access_count: 0
      },
      overrides
    )
  end

  describe "put/fetch" do
    test "stores and retrieves by id and name", %{agent: agent} do
      attrs = base_attrs(%{name: "Hysun", relationship_dynamic: "Partnership", salience: 0.8})
      assert {:ok, saved} = Persistence.put_relationship(agent, attrs)
      assert saved.name == "Hysun"
      assert saved.relationship_dynamic == "Partnership"
      refute Map.has_key?(saved, :agent_id)

      assert {:ok, by_id} = Persistence.fetch_relationship(agent, saved.id)
      assert by_id.name == "Hysun"

      assert {:ok, by_name} = Persistence.fetch_relationship_by_name(agent, "Hysun")
      assert by_name.id == saved.id
    end

    test "upsert preserves id on name conflict", %{agent: agent} do
      attrs = base_attrs(%{name: "Hysun", relationship_dynamic: "Old"})
      assert {:ok, first} = Persistence.put_relationship(agent, attrs)

      second =
        base_attrs(%{
          id: "rel_other_id",
          name: "Hysun",
          relationship_dynamic: "New"
        })

      assert {:ok, updated} = Persistence.put_relationship(agent, second)
      assert updated.id == first.id
      assert updated.relationship_dynamic == "New"
    end

    test "tenant isolation on fetch/list/delete/touch", %{agent: agent, other: other} do
      attrs = base_attrs(%{name: "Shared"})
      assert {:ok, saved} = Persistence.put_relationship(agent, attrs)

      assert {:error, :not_found} = Persistence.fetch_relationship(other, saved.id)
      assert {:error, :not_found} = Persistence.fetch_relationship_by_name(other, "Shared")
      assert {:ok, []} = Persistence.list_relationships(other)
      assert {:error, :not_found} = Persistence.delete_relationship(other, saved.id)
      assert {:error, :not_found} = Persistence.touch_relationship(other, saved.id)
      assert {:ok, 1} = Persistence.count_relationships(agent)
      assert {:ok, 0} = Persistence.count_relationships(other)
    end

    test "not_found paths", %{agent: agent} do
      assert {:error, :not_found} = Persistence.fetch_relationship(agent, "missing")
      assert {:error, :not_found} = Persistence.fetch_relationship_by_name(agent, "Nobody")
      assert {:error, :not_found} = Persistence.delete_relationship(agent, "missing")
      assert {:error, :not_found} = Persistence.fetch_primary_relationship(agent)
    end
  end

  describe "list/count/primary/touch" do
    test "deterministic sort, default finite limit, primary, atomic touch", %{agent: agent} do
      for {name, sal} <- [{"Low", 0.3}, {"High", 0.9}, {"Medium", 0.6}] do
        assert {:ok, _} =
                 Persistence.put_relationship(agent, base_attrs(%{name: name, salience: sal}))
      end

      assert {:ok, listed} = Persistence.list_relationships(agent)
      assert Enum.map(listed, & &1.salience) == [0.9, 0.6, 0.3]

      assert {:ok, by_name} =
               Persistence.list_relationships(agent, sort_by: :name, sort_dir: :asc)

      assert Enum.map(by_name, & &1.name) == ["High", "Low", "Medium"]

      assert {:ok, limited} = Persistence.list_relationships(agent, limit: 2)
      assert length(limited) == 2

      assert {:ok, primary} = Persistence.fetch_primary_relationship(agent)
      assert primary.name == "High"

      assert {:ok, 3} = Persistence.count_relationships(agent)

      original = primary.access_count
      Process.sleep(10)
      assert {:ok, touched} = Persistence.touch_relationship(agent, primary.id)
      assert touched.access_count == original + 1
      assert DateTime.compare(touched.last_interaction, primary.last_interaction) == :gt
    end

    test "list salience ties break deterministically by name then id", %{agent: agent} do
      assert {:ok, first} =
               Persistence.put_relationship(
                 agent,
                 base_attrs(%{id: "rel_tie_b", name: "Beta", salience: 0.5})
               )

      assert {:ok, second} =
               Persistence.put_relationship(
                 agent,
                 base_attrs(%{id: "rel_tie_a", name: "Alpha A", salience: 0.5})
               )

      assert {:ok, third} =
               Persistence.put_relationship(
                 agent,
                 base_attrs(%{id: "rel_tie_c", name: "Alpha B", salience: 0.5})
               )

      assert {:ok, listed} = Persistence.list_relationships(agent, sort_by: :salience)
      ids = Enum.map(listed, & &1.id)
      # Same salience: name ASC then id ASC.
      assert ids == [second.id, third.id, first.id]
    end

    test "rejects unbounded/oversized list opts", %{agent: agent} do
      assert {:error, :invalid_options} =
               Persistence.list_relationships(agent, limit: 0)

      assert {:error, :invalid_options} =
               Persistence.list_relationships(agent, limit: 1001)

      assert {:error, :invalid_options} =
               Persistence.list_relationships(agent, sort_by: :unknown)

      assert {:error, :invalid_options} =
               Persistence.list_relationships(agent, foo: 1)
    end
  end

  describe "update" do
    test "updates fields and allows bounded rename", %{agent: agent} do
      assert {:ok, saved} =
               Persistence.put_relationship(agent, base_attrs(%{name: "Old", salience: 0.4}))

      assert {:ok, updated} =
               Persistence.update_relationship(agent, saved.id, %{salience: 0.9, name: "New"})

      assert updated.salience == 0.9
      assert updated.name == "New"
      assert {:ok, _} = Persistence.fetch_relationship_by_name(agent, "New")
      assert {:error, :not_found} = Persistence.fetch_relationship_by_name(agent, "Old")
    end

    test "rename collision is validation_failed", %{agent: agent} do
      assert {:ok, a} = Persistence.put_relationship(agent, base_attrs(%{name: "A"}))
      assert {:ok, _b} = Persistence.put_relationship(agent, base_attrs(%{name: "B"}))

      assert {:error, :validation_failed} =
               Persistence.update_relationship(agent, a.id, %{name: "B"})
    end

    test "rejects id/agent_id transfer and unknown keys", %{agent: agent} do
      assert {:ok, saved} = Persistence.put_relationship(agent, base_attrs(%{name: "X"}))

      assert {:error, :invalid_request} =
               Persistence.update_relationship(agent, saved.id, %{id: "hijack"})

      assert {:error, :invalid_request} =
               Persistence.update_relationship(agent, saved.id, %{agent_id: "other"})

      assert {:error, :invalid_request} =
               Persistence.update_relationship(agent, saved.id, %{unknown: 1})

      assert {:error, :invalid_request} =
               Persistence.update_relationship(agent, saved.id, %{"salience" => 0.9})
    end

    test "rejects update when merged projected row exceeds byte ceiling", %{agent: agent} do
      assert {:ok, saved} =
               Persistence.put_relationship(agent, base_attrs(%{name: "Ceiling"}))

      # Field-level bounds admit this list, but merged row exceeds 65_536 bytes.
      huge = List.duplicate(String.duplicate("b", 1024), 70)

      assert {:error, :invalid_request} =
               Persistence.update_relationship(agent, saved.id, %{background: huge})

      assert {:ok, still} = Persistence.fetch_relationship(agent, saved.id)
      assert still.background == []
    end
  end

  describe "closed input bounds" do
    test "rejects agent_id in put map, string keys, oversize, bad salience", %{agent: agent} do
      assert {:error, :invalid_request} =
               Persistence.put_relationship(agent, Map.put(base_attrs(), :agent_id, "x"))

      assert {:error, :invalid_request} =
               Persistence.put_relationship(agent, %{"id" => "a", "name" => "b"})

      assert {:error, :invalid_request} =
               Persistence.put_relationship(
                 agent,
                 base_attrs(%{name: String.duplicate("n", 300)})
               )

      assert {:error, :invalid_request} =
               Persistence.put_relationship(agent, base_attrs(%{salience: 1.5}))

      assert {:error, :invalid_request} =
               Persistence.put_relationship(
                 agent,
                 base_attrs(%{background: List.duplicate("x", 101)})
               )
    end

    test "content-free errors never include changeset payloads", %{agent: agent} do
      assert {:error, reason} =
               Persistence.put_relationship(agent, base_attrs(%{salience: 99.0}))

      assert reason in [
               :invalid_request,
               :invalid_options,
               :not_found,
               :validation_failed,
               :backend_failure,
               :indeterminate
             ]

      refute is_list(reason)
      refute is_tuple(reason)
    end
  end

  describe "delete_all and absence" do
    test "target-only, idempotent, and absence check", %{agent: agent, other: other} do
      assert {:ok, _} = Persistence.put_relationship(agent, base_attrs(%{name: "A1"}))
      assert {:ok, _} = Persistence.put_relationship(agent, base_attrs(%{name: "A2"}))
      assert {:ok, _} = Persistence.put_relationship(other, base_attrs(%{name: "B1"}))

      assert {:ok, false} = Persistence.relationships_absent?(agent)
      assert :ok = Persistence.delete_all_relationships(agent)
      assert {:ok, true} = Persistence.relationships_absent?(agent)
      assert :ok = Persistence.delete_all_relationships(agent)

      assert {:ok, [only]} = Persistence.list_relationships(other)
      assert only.name == "B1"
      assert {:ok, false} = Persistence.relationships_absent?(other)
    end

    test "fail-closed verify rolls back so target rows remain", %{agent: agent} do
      assert {:ok, kept} =
               Persistence.put_relationship(agent, base_attrs(%{name: "Z", salience: 0.8}))

      assert :ok = RelationshipStore.__set_post_delete_remaining_override__(1)

      try do
        assert {:error, :indeterminate} = Persistence.delete_all_relationships(agent)
      after
        RelationshipStore.__clear_post_delete_remaining_override__()
      end

      # Transaction rolled back: content still present and readable.
      assert {:ok, false} = Persistence.relationships_absent?(agent)
      assert {:ok, again} = Persistence.fetch_relationship(agent, kept.id)
      assert again.name == "Z"
      assert again.salience == 0.8
      assert {:ok, 1} = Persistence.count_relationships(agent)
    end
  end

  describe "row/page bounds and malformed storage" do
    test "put rejects oversize projected row before write", %{agent: agent} do
      huge = List.duplicate(String.duplicate("r", 1024), 70)

      assert {:error, :invalid_request} =
               Persistence.put_relationship(agent, base_attrs(%{name: "Huge", background: huge}))

      assert {:ok, true} = Persistence.relationships_absent?(agent)
    end

    test "list fails closed when page byte budget is exceeded", %{agent: agent} do
      # Bypass facade validation to plant large durable rows, then list via facade.
      chunk = String.duplicate("p", 1024)
      background = List.duplicate(chunk, 60)

      for i <- 1..20 do
        attrs =
          base_attrs(%{
            id: "rel_page_#{i}",
            name: "Page#{i}",
            background: background
          })

        schema_attrs = RelationshipSchema.attrs_from_map(attrs, agent)

        assert {:ok, _} =
                 %RelationshipSchema{}
                 |> RelationshipSchema.changeset(schema_attrs)
                 |> Repo.insert()
      end

      assert {:error, :backend_failure} =
               Persistence.list_relationships(agent, limit: 20)
    end

    test "fetch fails closed on malformed stored key_moments", %{agent: agent} do
      attrs = base_attrs(%{id: "rel_malformed", name: "Broken"})
      schema_attrs = RelationshipSchema.attrs_from_map(attrs, agent)

      assert {:ok, row} =
               %RelationshipSchema{}
               |> RelationshipSchema.changeset(schema_attrs)
               |> Repo.insert()

      # Keep the storage type valid while making the timestamp undecodable.
      {1, _} =
        Repo.update_all(from(r in RelationshipSchema, where: r.id == ^row.id),
          set: [
            key_moments: [
              %{
                "summary" => "bad",
                "timestamp" => 123,
                "emotional_markers" => [],
                "salience" => 0.5
              }
            ]
          ]
        )

      assert {:error, :backend_failure} =
               Persistence.fetch_relationship(agent, row.id)
    end
  end

  describe "complex moments" do
    test "round-trips key moments with string markers", %{agent: agent} do
      attrs =
        base_attrs(%{
          name: "Moments",
          key_moments: [
            %{
              summary: "First",
              timestamp: DateTime.utc_now() |> DateTime.truncate(:microsecond),
              emotional_markers: ["connection"],
              salience: 0.8
            }
          ]
        })

      assert {:ok, saved} = Persistence.put_relationship(agent, attrs)
      assert [%{summary: "First", emotional_markers: markers}] = saved.key_moments
      assert "connection" in markers
    end
  end
end
