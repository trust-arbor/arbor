defmodule Arbor.Persistence.QueryableStore.PostgresConcurrentCASTest do
  @moduledoc """
  One-winner CAS under true concurrent independent DB sessions.

  The default DatabaseCase sandbox uses a single shared connection, which
  serializes writers and can mask races. This module puts the sandbox in
  `:auto` mode so Tasks each check out their own real connection.

  Requires PostgreSQL:

      ARBOR_DB=postgres MIX_ENV=test ./bin/mix ecto.create -r Arbor.Persistence.Repo
      ARBOR_DB=postgres MIX_ENV=test ./bin/mix ecto.migrate -r Arbor.Persistence.Repo
      ARBOR_DB=postgres MIX_ENV=test ./bin/mix test \\
        apps/arbor_persistence/test/arbor/persistence/queryable_store/postgres_concurrent_cas_test.exs \\
        --include database
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Persistence.QueryableStore.Postgres
  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.Record, as: RecordSchema
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :database

  if Repo.__adapter__() != Ecto.Adapters.Postgres do
    @moduletag skip: "independent-session CAS coverage requires PostgreSQL"
  end

  setup_all do
    case Repo.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, pid}} ->
        _ = Process.unlink(pid)
        :ok

      {:error, reason} ->
        {:skip, "database not available: #{inspect(reason)}"}
    end
  end

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    Repo.delete_all(RecordSchema)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      Repo.delete_all(RecordSchema)
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  test "two simultaneous expected-version claims cannot both succeed (independent sessions)" do
    namespace = "fence_ns_#{System.unique_integer([:positive])}"
    key = "fence"

    assert :ok =
             Postgres.put(key, Record.new(key, %{"base" => true}), name: namespace, repo: Repo)

    assert {:ok, observed} = Postgres.get(key, name: namespace, repo: Repo)
    parent = self()

    tasks =
      for i <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, i})

          receive do
            :go -> :ok
          after
            5_000 -> flunk("start barrier timeout")
          end

          Postgres.compare_and_swap(
            key,
            {:value, observed},
            Record.new(key, %{"writer" => i}),
            name: namespace,
            repo: Repo
          )
        end)
      end

    for _ <- 1..2, do: assert_receive({:ready, _}, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))
    results = Enum.map(tasks, &Task.await(&1, 15_000))

    oks = Enum.filter(results, &match?({:ok, _}, &1))
    conflicts = Enum.filter(results, &match?({:error, :conflict}, &1))

    assert length(oks) == 1, "expected one CAS winner, got: #{inspect(results)}"
    assert length(conflicts) == 1, "expected one CAS conflict, got: #{inspect(results)}"

    assert {:ok, %Record{generation: 1, revision: 2, data: data}} =
             Postgres.get(key, name: namespace, repo: Repo)

    assert data["writer"] in [1, 2]
  end

  test "delimiter collision pairs remain independent under concurrent writers" do
    # ("a","b:c") vs ("a:b","c") — must not share physical identity.
    parent = self()

    tasks = [
      Task.async(fn ->
        send(parent, :ready_1)

        receive do
          :go -> :ok
        after
          5_000 -> flunk("timeout")
        end

        Postgres.put("b:c", Record.new("b:c", %{"pair" => "a/b:c"}), name: "a", repo: Repo)
      end),
      Task.async(fn ->
        send(parent, :ready_2)

        receive do
          :go -> :ok
        after
          5_000 -> flunk("timeout")
        end

        Postgres.put("c", Record.new("c", %{"pair" => "a:b/c"}), name: "a:b", repo: Repo)
      end)
    ]

    assert_receive :ready_1, 5_000
    assert_receive :ready_2, 5_000
    Enum.each(tasks, &send(&1.pid, :go))
    results = Enum.map(tasks, &Task.await(&1, 15_000))
    assert results == [:ok, :ok]

    assert {:ok, %Record{data: %{"pair" => "a/b:c"}}} =
             Postgres.get("b:c", name: "a", repo: Repo)

    assert {:ok, %Record{data: %{"pair" => "a:b/c"}}} =
             Postgres.get("c", name: "a:b", repo: Repo)
  end
end
