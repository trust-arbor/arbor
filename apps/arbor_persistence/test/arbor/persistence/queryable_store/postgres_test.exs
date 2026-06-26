defmodule Arbor.Persistence.QueryableStore.PostgresTest do
  @moduledoc """
  Tests for the PostgreSQL QueryableStore backend.

  ## Setup Required

  These tests require a running PostgreSQL database:

      mix ecto.create -r Arbor.Persistence.Repo
      mix ecto.migrate -r Arbor.Persistence.Repo

  ## Running

      mix test --include database

  Or for just this file:

      mix test apps/arbor_persistence/test/arbor/persistence/queryable_store/postgres_test.exs --include database
  """

  # Uses the shared DatabaseCase template, which starts the Repo lazily and checks
  # out a `:manual` Sandbox connection per test with `shared: true` — so the
  # concurrent-upsert regression test's spawned Tasks see the same connection and
  # roll back cleanly. (Replaces the old hand-rolled `Repo.start_link` setup_all,
  # which assumed a non-manual sandbox mode and broke once any DatabaseCase module
  # flipped the Repo to `:manual` globally.)
  use Arbor.Persistence.DatabaseCase, async: false

  alias Arbor.Persistence.{Filter, Record}
  alias Arbor.Persistence.QueryableStore.Postgres
  alias Arbor.Persistence.Schemas.Record, as: RecordSchema

  @moduletag :integration
  @moduletag :database

  setup do
    # Clean up records table before each test (within the checked-out connection)
    Repo.delete_all(RecordSchema)
    {:ok, name: :test_store}
  end

  # ===========================================================================
  # CRUD Operations
  # ===========================================================================

  describe "put/3 and get/2" do
    test "stores and retrieves a record", %{name: name} do
      record = Record.new("user:1", %{"name" => "Alice", "role" => "admin"})
      assert :ok = Postgres.put("user:1", record, name: name, repo: Repo)

      assert {:ok, retrieved} = Postgres.get("user:1", name: name, repo: Repo)
      assert retrieved.key == "user:1"
      assert retrieved.data == %{"name" => "Alice", "role" => "admin"}
    end

    test "upserts on conflict — updates data and metadata", %{name: name} do
      record1 = Record.new("key", %{"version" => 1})
      assert :ok = Postgres.put("key", record1, name: name, repo: Repo)

      record2 = Record.new("key", %{"version" => 2}, metadata: %{"updated" => true})
      assert :ok = Postgres.put("key", record2, name: name, repo: Repo)

      assert {:ok, retrieved} = Postgres.get("key", name: name, repo: Repo)
      assert retrieved.data == %{"version" => 2}
      assert retrieved.metadata == %{"updated" => true}
    end

    test "namespaces are isolated", %{} do
      record = Record.new("same-key", %{"ns" => "a"})
      assert :ok = Postgres.put("same-key", record, name: :ns_a, repo: Repo)

      record2 = Record.new("same-key", %{"ns" => "b"})
      assert :ok = Postgres.put("same-key", record2, name: :ns_b, repo: Repo)

      assert {:ok, a} = Postgres.get("same-key", name: :ns_a, repo: Repo)
      assert {:ok, b} = Postgres.get("same-key", name: :ns_b, repo: Repo)

      assert a.data == %{"ns" => "a"}
      assert b.data == %{"ns" => "b"}
    end

    test "returns not_found for missing key", %{name: name} do
      assert {:error, :not_found} = Postgres.get("missing", name: name, repo: Repo)
    end
  end

  describe "delete/2" do
    test "removes a record", %{name: name} do
      record = Record.new("to-delete", %{})
      Postgres.put("to-delete", record, name: name, repo: Repo)

      assert :ok = Postgres.delete("to-delete", name: name, repo: Repo)
      assert {:error, :not_found} = Postgres.get("to-delete", name: name, repo: Repo)
    end

    test "succeeds even if key doesn't exist", %{name: name} do
      assert :ok = Postgres.delete("nonexistent", name: name, repo: Repo)
    end
  end

  describe "list/1" do
    test "returns all keys in namespace", %{name: name} do
      for key <- ["c", "a", "b"] do
        Postgres.put(key, Record.new(key), name: name, repo: Repo)
      end

      {:ok, keys} = Postgres.list(name: name, repo: Repo)
      assert keys == ["a", "b", "c"]
    end

    test "returns empty list for empty namespace", %{name: name} do
      {:ok, keys} = Postgres.list(name: name, repo: Repo)
      assert keys == []
    end

    test "only returns keys from the correct namespace", %{} do
      Postgres.put("a", Record.new("a"), name: :ns1, repo: Repo)
      Postgres.put("b", Record.new("b"), name: :ns2, repo: Repo)

      {:ok, keys} = Postgres.list(name: :ns1, repo: Repo)
      assert keys == ["a"]
    end
  end

  describe "exists?/2" do
    test "returns true for existing key", %{name: name} do
      Postgres.put("here", Record.new("here"), name: name, repo: Repo)
      assert Postgres.exists?("here", name: name, repo: Repo)
    end

    test "returns false for missing key", %{name: name} do
      refute Postgres.exists?("nope", name: name, repo: Repo)
    end
  end

  # ===========================================================================
  # Query Operations
  # ===========================================================================

  describe "query/2" do
    setup %{name: name} do
      records = [
        {"job-1", %{"status" => "active", "priority" => "high", "score" => 10}},
        {"job-2", %{"status" => "active", "priority" => "normal", "score" => 20}},
        {"job-3", %{"status" => "completed", "priority" => "high", "score" => 30}},
        {"job-4", %{"status" => "failed", "priority" => "low", "score" => 5}}
      ]

      for {key, data} <- records do
        Postgres.put(key, Record.new(key, data), name: name, repo: Repo)
      end

      :ok
    end

    test "returns all with empty filter", %{name: name} do
      {:ok, results} = Postgres.query(Filter.new(), name: name, repo: Repo)
      assert length(results) == 4
    end

    test "filters by JSONB field equality", %{name: name} do
      filter = Filter.new() |> Filter.where(:status, :eq, "active")
      {:ok, results} = Postgres.query(filter, name: name, repo: Repo)

      assert length(results) == 2
      assert Enum.all?(results, &(&1.data["status"] == "active"))
    end

    test "filters by JSONB field inequality", %{name: name} do
      filter = Filter.new() |> Filter.where(:status, :neq, "active")
      {:ok, results} = Postgres.query(filter, name: name, repo: Repo)

      assert length(results) == 2
      statuses = Enum.map(results, & &1.data["status"])
      refute "active" in statuses
    end

    test "filters by JSONB field :in", %{name: name} do
      filter = Filter.new() |> Filter.where(:status, :in, ["active", "failed"])
      {:ok, results} = Postgres.query(filter, name: name, repo: Repo)

      assert length(results) == 3
    end

    test "filters by key equality", %{name: name} do
      filter = Filter.new() |> Filter.where(:key, :eq, "job-1")
      {:ok, results} = Postgres.query(filter, name: name, repo: Repo)

      assert length(results) == 1
      assert hd(results).key == "job-1"
    end

    test "filters by key :in", %{name: name} do
      filter = Filter.new() |> Filter.where(:key, :in, ["job-1", "job-3"])
      {:ok, results} = Postgres.query(filter, name: name, repo: Repo)

      assert length(results) == 2
      keys = Enum.map(results, & &1.key) |> Enum.sort()
      assert keys == ["job-1", "job-3"]
    end

    test "combines multiple conditions", %{name: name} do
      filter =
        Filter.new()
        |> Filter.where(:status, :eq, "active")
        |> Filter.where(:priority, :eq, "high")

      {:ok, results} = Postgres.query(filter, name: name, repo: Repo)

      assert length(results) == 1
      assert hd(results).key == "job-1"
    end

    test "orders by key", %{name: name} do
      filter = Filter.new() |> Filter.order_by(:key, :desc)
      {:ok, results} = Postgres.query(filter, name: name, repo: Repo)

      keys = Enum.map(results, & &1.key)
      assert keys == ["job-4", "job-3", "job-2", "job-1"]
    end

    test "orders by JSONB field", %{name: name} do
      filter = Filter.new() |> Filter.order_by(:priority, :asc)
      {:ok, results} = Postgres.query(filter, name: name, repo: Repo)

      priorities = Enum.map(results, & &1.data["priority"])
      assert priorities == ["high", "high", "low", "normal"]
    end

    test "applies limit", %{name: name} do
      filter = Filter.new() |> Filter.order_by(:key, :asc) |> Filter.limit(2)
      {:ok, results} = Postgres.query(filter, name: name, repo: Repo)

      assert length(results) == 2
      assert hd(results).key == "job-1"
    end

    test "applies offset", %{name: name} do
      filter =
        Filter.new()
        |> Filter.order_by(:key, :asc)
        |> Filter.offset(2)
        |> Filter.limit(2)

      {:ok, results} = Postgres.query(filter, name: name, repo: Repo)

      assert length(results) == 2
      keys = Enum.map(results, & &1.key)
      assert keys == ["job-3", "job-4"]
    end

    test "filters by time range", %{name: name} do
      # All records were just inserted, so since a minute ago should include all
      one_minute_ago = DateTime.add(DateTime.utc_now(), -60, :second)
      filter = Filter.new() |> Filter.since(one_minute_ago)
      {:ok, results} = Postgres.query(filter, name: name, repo: Repo)

      assert length(results) == 4

      # Since far in the future should include none
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      filter2 = Filter.new() |> Filter.since(future)
      {:ok, results2} = Postgres.query(filter2, name: name, repo: Repo)

      assert results2 == []
    end

    test "filters by JSONB contains text", %{name: name} do
      # Add a record with a description
      record = Record.new("job-5", %{"status" => "active", "title" => "Refactor comms module"})
      Postgres.put("job-5", record, name: name, repo: Repo)

      filter = Filter.new() |> Filter.where(:title, :contains, "comms")
      {:ok, results} = Postgres.query(filter, name: name, repo: Repo)

      assert length(results) == 1
      assert hd(results).key == "job-5"
    end
  end

  # ===========================================================================
  # Count Operations
  # ===========================================================================

  describe "count/2" do
    test "counts all records with empty filter", %{name: name} do
      for i <- 1..5 do
        Postgres.put("r-#{i}", Record.new("r-#{i}", %{"type" => "test"}), name: name, repo: Repo)
      end

      {:ok, count} = Postgres.count(Filter.new(), name: name, repo: Repo)
      assert count == 5
    end

    test "counts matching records", %{name: name} do
      Postgres.put("a", Record.new("a", %{"status" => "active"}), name: name, repo: Repo)
      Postgres.put("b", Record.new("b", %{"status" => "done"}), name: name, repo: Repo)
      Postgres.put("c", Record.new("c", %{"status" => "active"}), name: name, repo: Repo)

      filter = Filter.new() |> Filter.where(:status, :eq, "active")
      {:ok, count} = Postgres.count(filter, name: name, repo: Repo)
      assert count == 2
    end

    test "returns 0 for no matches", %{name: name} do
      filter = Filter.new() |> Filter.where(:status, :eq, "nonexistent")
      {:ok, count} = Postgres.count(filter, name: name, repo: Repo)
      assert count == 0
    end
  end

  # ===========================================================================
  # Aggregate Operations
  # ===========================================================================

  describe "aggregate/4" do
    setup %{name: name} do
      records = [
        {"a", %{"score" => 10}},
        {"b", %{"score" => 20}},
        {"c", %{"score" => 30}}
      ]

      for {key, data} <- records do
        Postgres.put(key, Record.new(key, data), name: name, repo: Repo)
      end

      :ok
    end

    test "sum", %{name: name} do
      {:ok, result} = Postgres.aggregate(Filter.new(), :score, :sum, name: name, repo: Repo)
      assert Decimal.equal?(result, 60)
    end

    test "avg", %{name: name} do
      {:ok, result} = Postgres.aggregate(Filter.new(), :score, :avg, name: name, repo: Repo)
      assert_in_delta Decimal.to_float(result), 20.0, 0.01
    end

    test "min", %{name: name} do
      {:ok, result} = Postgres.aggregate(Filter.new(), :score, :min, name: name, repo: Repo)
      assert Decimal.equal?(result, 10)
    end

    test "max", %{name: name} do
      {:ok, result} = Postgres.aggregate(Filter.new(), :score, :max, name: name, repo: Repo)
      assert Decimal.equal?(result, 30)
    end

    test "returns nil for no matching records", %{name: name} do
      filter = Filter.new() |> Filter.where(:key, :eq, "nonexistent")
      {:ok, result} = Postgres.aggregate(filter, :score, :sum, name: name, repo: Repo)
      assert result == nil
    end

    test "aggregates with filter", %{name: name} do
      filter = Filter.new() |> Filter.where(:key, :in, ["a", "b"])
      {:ok, result} = Postgres.aggregate(filter, :score, :sum, name: name, repo: Repo)
      assert Decimal.equal?(result, 30)
    end
  end

  # ===========================================================================
  # Schema Conversion
  # ===========================================================================

  describe "Schemas.Record conversion" do
    test "from_record/2 converts Record to schema attrs" do
      record = Record.new("test-key", %{"data" => "value"}, metadata: %{"source" => "test"})
      attrs = Arbor.Persistence.Schemas.Record.from_record(record, "my_namespace")

      assert attrs.id == record.id
      assert attrs.namespace == "my_namespace"
      assert attrs.key == "test-key"
      assert attrs.data == %{"data" => "value"}
      assert attrs.metadata == %{"source" => "test"}
    end

    test "to_record/1 converts schema to Record" do
      now = DateTime.utc_now()

      schema = %Arbor.Persistence.Schemas.Record{
        id: "rec_123",
        namespace: "test",
        key: "my-key",
        data: %{"field" => "value"},
        metadata: %{"meta" => true},
        inserted_at: now,
        updated_at: now
      }

      record = Arbor.Persistence.Schemas.Record.to_record(schema)

      assert record.id == "rec_123"
      assert record.key == "my-key"
      assert record.data == %{"field" => "value"}
      assert record.metadata == %{"meta" => true}
      assert record.inserted_at == now
      assert record.updated_at == now
    end
  end

  # ===========================================================================
  # Regression: spurious records_pkey violation under upsert (the dual-index race)
  #
  # The `records` table once carried TWO redundant unique constraints: the pkey
  # `id` (= `namespace:key`) AND `records_namespace_key_index` UNIQUE on
  # `(namespace, key)`. The upsert arbitrated only `(namespace, key)`, so a fresh
  # INSERT could surface a violation on the *non-arbiter* pkey index — which the
  # changeset did not declare, so Ecto raised `Ecto.ConstraintError` instead of
  # returning `{:error, changeset}`. The fix collapses to `id` as the sole arbiter
  # (`conflict_target: [:id]`) + declares the pkey constraint.
  #
  # This reproduces the raise DETERMINISTICALLY (no timing race): seed a row whose
  # pkey equals what the next `put` computes, but whose `(namespace, key)` differs.
  # PRE-FIX: ON CONFLICT(namespace,key) misses → INSERT → pkey collision → raise.
  # POST-FIX: ON CONFLICT(id) hits → DO UPDATE → no raise.
  # ===========================================================================

  describe "records_pkey upsert regression (dual-index race)" do
    test "put does not raise when computed id collides with a row of a different (namespace, key)",
         %{} do
      namespace = "regress_ns"
      dup_key = "dup"
      colliding_id = "#{namespace}:#{dup_key}"

      # Seed row R directly: its pkey equals what put(namespace, dup_key) will
      # compute, but its (namespace, key) is DIFFERENT — so an upsert arbitrating
      # on (namespace, key) won't find it and will attempt an INSERT.
      now = DateTime.utc_now()

      {:ok, _seeded} =
        %RecordSchema{}
        |> RecordSchema.changeset(%{
          id: colliding_id,
          namespace: namespace,
          key: "a-different-key",
          data: %{"seed" => true},
          metadata: %{},
          inserted_at: now,
          updated_at: now
        })
        |> Repo.insert()

      # put computes id = "regress_ns:dup" == colliding_id. PRE-FIX this raises
      # records_pkey (rescued into {:error, {:put_failed, %Ecto.ConstraintError{}}});
      # POST-FIX it resolves via ON CONFLICT(id) and returns :ok.
      record = Record.new(dup_key, %{"version" => 1})
      result = Postgres.put(dup_key, record, name: namespace, repo: Repo)

      assert result == :ok,
             "expected upsert to resolve via ON CONFLICT(id), got: #{inspect(result)}"

      # The upsert resolved on the pkey `id`, so it UPDATED the seed row (which
      # owns that id) rather than inserting a colliding one. Fetch by id directly
      # to confirm the data was written and no duplicate row was created.
      fetched = Repo.get(RecordSchema, colliding_id)
      assert fetched != nil
      assert fetched.data == %{"version" => 1}
      assert Repo.aggregate(RecordSchema, :count, :id) == 1
    end

    test "N concurrent upserts of the same fresh (namespace, key) all succeed", %{} do
      namespace = "regress_concurrent_ns"
      key = "hot-key"

      tasks =
        for i <- 1..25 do
          Task.async(fn ->
            record = Record.new(key, %{"writer" => i})
            Postgres.put(key, record, name: namespace, repo: Repo)
          end)
        end

      results = Enum.map(tasks, &Task.await(&1, 10_000))

      assert Enum.all?(results, &(&1 == :ok)),
             "expected all concurrent upserts to succeed, got: #{inspect(results)}"

      # Exactly one row should exist for this (namespace, key).
      {:ok, keys} = Postgres.list(name: namespace, repo: Repo)
      assert keys == [key]
    end
  end
end
