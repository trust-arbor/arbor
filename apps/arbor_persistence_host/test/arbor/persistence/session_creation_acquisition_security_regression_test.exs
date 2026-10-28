defmodule Arbor.Persistence.SessionCreationAcquisitionSecurityRegressionTest do
  use ExUnit.Case, async: false
  alias Arbor.Persistence
  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Test.SessionCreationContentionFixture, as: Contention
  @moduletag :integration
  @moduletag :database
  @moduletag :isolated_repo
  @migrations Path.expand("../../../priv/repo/migrations", __DIR__)

  setup_all do
    assert Process.whereis(Repo) == nil, "Run this actual SQLite pool proof standalone."

    root =
      Path.join(System.tmp_dir!(), "session-acquisition-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    database = Path.join(root, "sessions.sqlite3")

    start_supervised!(
      {Repo,
       database: database,
       pool: DBConnection.ConnectionPool,
       pool_size: 4,
       busy_timeout: 5_000,
       journal_mode: :wal}
    )

    assert [_ | _] = Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false)
    Contention.start_peers!(database)
    :ok
  end

  test "security regression first creations preserve default writer progress rather than occupy native IO until timeout" do
    writer = Contention.hold_writer!()
    creators = Contention.start_creators!()
    result = Contention.release_after_lookups!(writer, creators)

    assert Enum.all?(result.results, &match?({:ok, _}, &1)),
           "public first creation must not raise under a promptly released writer: #{inspect(result.results)}"

    assert result.writer_release_ms < 5_000
  end

  test "security regression first callers converge and an existing owner is readable under a writer lock" do
    id = "same-owner-#{System.unique_integer([:positive])}"

    tasks =
      for _ <- 1..12, do: Task.async(fn -> Persistence.ensure_session(id, "agent_owner") end)

    results = Enum.map(tasks, &Task.await(&1, 15_000))
    assert Enum.all?(results, &match?({:ok, _}, &1))
    [{:ok, first} | _] = results
    assert Enum.uniq(Enum.map(results, fn {:ok, session} -> session.id end)) == [first.id]
    writer = Contention.hold_writer!()

    try do
      assert {:ok, ^first} = Persistence.ensure_session(id, "agent_owner")

      assert {:error, {:agent_id_mismatch, "agent_owner", "agent_foreign"}} =
               Persistence.ensure_session(id, "agent_foreign")
    after
      send(writer.pid, :release)
      assert {:ok, :ok} = Task.await(writer, 5_000)
    end
  end

  test "security regression a competing owner is rejected after first-creation acquisition" do
    id = "competing-owner-#{System.unique_integer([:positive])}"
    writer = Contention.hold_writer!()
    handler = Contention.observe_lookups!()

    tasks =
      for owner <- ["agent_first", "agent_second"] do
        Task.async(fn -> Persistence.ensure_session(id, owner) end)
      end

    result = Contention.release_after_lookups!(writer, %{tasks: tasks, handler: handler}, 2)
    assert [{:ok, winner}] = Enum.filter(result.results, &match?({:ok, _}, &1))
    loser = if winner.agent_id == "agent_first", do: "agent_second", else: "agent_first"
    assert {:error, {:agent_id_mismatch, winner.agent_id, loser}} in result.results
  end
end
