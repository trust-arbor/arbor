defmodule Arbor.Persistence.QueryableStore.SQLiteJSONRegressionTest do
  @moduledoc """
  Dual-adapter regression: QueryableStore must persist nested trust/agent maps
  and datetime fields on the default SQLite adapter without jsonb-only SQL.
  """

  use Arbor.Persistence.DatabaseCase, async: false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Persistence.Filter
  alias Arbor.Persistence.QueryableStore.Postgres
  alias Arbor.Persistence.Schemas.Record, as: RecordSchema

  @moduletag :integration
  @moduletag :database
  @moduletag :sqlite

  setup do
    Repo.delete_all(RecordSchema)
    {:ok, name: :sqlite_json_regression}
  end

  describe "SQLite / dual-adapter JSON persistence" do
    test "persists nested trust/agent maps and datetime fields, then queries them", %{
      name: name
    } do
      updated_at = ~U[2026-08-19 12:30:00.000000Z]

      record =
        Record.new("agent_local_1", %{
          "kind" => "external",
          "agent" => %{
            "id" => "agent_local_1",
            "display_name" => "Local operator",
            "created_at" => updated_at
          },
          "trust" => %{
            "mode" => "ask",
            "updated_at" => updated_at,
            "rules" => %{"arbor://fs/read/" => "allow"}
          }
        })

      assert :ok = Postgres.put("agent_local_1", record, name: name, repo: Repo)

      assert {:ok, retrieved} = Postgres.get("agent_local_1", name: name, repo: Repo)
      assert retrieved.data["kind"] == "external"
      assert retrieved.data["agent"]["id"] == "agent_local_1"
      assert retrieved.data["agent"]["display_name"] == "Local operator"
      assert retrieved.data["trust"]["mode"] == "ask"
      assert retrieved.data["trust"]["rules"]["arbor://fs/read/"] == "allow"

      assert retrieved.data["agent"]["created_at"] =~ "2026-08-19T12:30:00"
      assert retrieved.data["trust"]["updated_at"] =~ "2026-08-19T12:30:00"
      assert %DateTime{} = retrieved.inserted_at
      assert %DateTime{} = retrieved.updated_at

      filter = Filter.new() |> Filter.where(:kind, :eq, "external")
      assert {:ok, [matched]} = Postgres.query(filter, name: name, repo: Repo)
      assert matched.key == "agent_local_1"
      assert matched.data["trust"]["mode"] == "ask"

      count_filter = Filter.new() |> Filter.where(:kind, :eq, "missing")
      assert {:ok, 0} = Postgres.count(count_filter, name: name, repo: Repo)
    end
  end
end
