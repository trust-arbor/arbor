defmodule Arbor.Persistence.QueryableStore.SQLiteAdapterRegressionTest do
  @moduledoc """
  Adapter regression: QueryableStore.Postgres (historical name) must round-trip
  map-shaped trust/agent records and honor CAS under the default SQLite adapter.

  Exqlite rejects Elixir maps in raw `repo.query/2` params; Postgrex accepts them
  as jsonb. Encoding maps/datetimes for SQLite is the boot-critical fix for
  `ARBOR_DB=sqlite` (trust profiles + agent records).
  """

  use Arbor.Persistence.DatabaseCase, async: false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Persistence.Filter
  alias Arbor.Persistence.QueryableStore.Postgres
  alias Arbor.Persistence.Schemas.Record, as: RecordSchema

  @moduletag :database
  @moduletag :integration
  @moduletag :sqlite

  if Arbor.Persistence.Repo.__adapter__() != Ecto.Adapters.SQLite3 do
    @moduletag skip: "SQLite QueryableStore adapter regression requires ARBOR_DB=sqlite"
  end

  setup do
    Repo.delete_all(RecordSchema)
    {:ok, name: :sqlite_adapter_regression}
  end

  test "sqlite adapter regression: put/get round-trips trust-profile-shaped map data" do
    name = :sqlite_adapter_regression

    trust_profile = %{
      "agent_id" => "agent_deadbeef",
      "rules" => [
        %{"prefix" => "arbor://fs/read/", "mode" => "allow"},
        %{"prefix" => "arbor://shell/exec/", "mode" => "ask"}
      ],
      "metadata" => %{"source" => "onboarding", "version" => 1}
    }

    record =
      Record.new("trust:agent_deadbeef", trust_profile, metadata: %{"kind" => "trust_profile"})

    assert :ok = Postgres.put(record.key, record, name: name, repo: Repo)

    assert {:ok, %Record{} = retrieved} =
             Postgres.get(record.key, name: name, repo: Repo)

    assert retrieved.key == record.key
    assert retrieved.data == trust_profile
    assert retrieved.metadata == %{"kind" => "trust_profile"}
    assert retrieved.generation == 1
    assert retrieved.revision == 1

    filter = Filter.new() |> Filter.where(:agent_id, :eq, "agent_deadbeef")
    assert {:ok, [matched]} = Postgres.query(filter, name: name, repo: Repo)
    assert matched.key == record.key
    assert matched.data["agent_id"] == "agent_deadbeef"
  end

  test "sqlite adapter regression: compare_and_swap fences map updates (security regression)" do
    name = :sqlite_adapter_regression
    key = "agent:agent_cafef00d"

    assert :ok =
             Postgres.put(
               key,
               Record.new(key, %{"agent_id" => "agent_cafef00d", "status" => "active"}),
               name: name,
               repo: Repo
             )

    assert {:ok, %Record{generation: 1, revision: 1} = observed} =
             Postgres.get(key, name: name, repo: Repo)

    replacement =
      Record.new(key, %{
        "agent_id" => "agent_cafef00d",
        "status" => "suspended",
        "caps" => [%{"uri" => "arbor://fs/read/", "mode" => "allow"}]
      })

    assert {:ok, %Record{revision: 2, data: data}} =
             Postgres.compare_and_swap(key, {:value, observed}, replacement,
               name: name,
               repo: Repo
             )

    assert data["status"] == "suspended"
    assert data["caps"] == [%{"uri" => "arbor://fs/read/", "mode" => "allow"}]

    # Stale CAS must conflict (fence holds after map-encoded update path).
    assert {:error, :conflict} =
             Postgres.compare_and_swap(key, {:value, observed}, replacement,
               name: name,
               repo: Repo
             )

    assert {:ok, %Record{revision: 2, data: %{"status" => "suspended"}}} =
             Postgres.get(key, name: name, repo: Repo)
  end
end
