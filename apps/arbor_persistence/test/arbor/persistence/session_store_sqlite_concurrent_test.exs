defmodule Arbor.Persistence.SessionStoreSQLiteConcurrentTest do
  @moduledoc """
  Runs the public SessionStore append boundary against a real multi-connection
  SQLite pool. DatabaseCase deliberately shares one sandbox connection, so it
  cannot prove writer serialization. Run this module standalone with both
  `--include database --include isolated_repo`.
  """

  use ExUnit.Case, async: false

  @moduletag :database
  @moduletag :isolated_repo

  @migrations_path Path.expand("../../../priv/repo/migrations", __DIR__)

  alias Arbor.Persistence.{Repo, SessionStore}

  setup_all do
    assert GenServer.whereis(Repo) == nil,
           "Arbor.Persistence.Repo must be absent; run this isolated pool proof standalone"

    database =
      Path.join(
        System.tmp_dir!(),
        "arbor-session-concurrent-#{System.unique_integer([:positive])}.sqlite3"
      )

    File.rm(database)

    start_supervised!(
      {Repo,
       database: database,
       pool: DBConnection.ConnectionPool,
       pool_size: 8,
       busy_timeout: 5_000,
       journal_mode: :wal}
    )

    assert [_ | _] = Ecto.Migrator.run(Repo, @migrations_path, :up, all: true, log: false)

    on_exit(fn -> File.rm(database) end)
    :ok
  end

  test "public same-session appends are gap-free across real SQLite connections" do
    session_id = "concurrent-#{System.unique_integer([:positive])}"

    assert {:ok, session} =
             SessionStore.create_session("agent-concurrent", session_id: session_id)

    tasks =
      for index <- 1..24 do
        Task.async(fn ->
          SessionStore.append_entry(session.id, %{
            entry_type: "user",
            role: "user",
            content: [%{"type" => "text", "text" => "entry-#{index}"}],
            timestamp: DateTime.utc_now(),
            metadata: %{}
          })
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 15_000))
    assert Enum.all?(results, &match?({:ok, _}, &1))

    ordinals = Enum.map(SessionStore.load_entries(session.id), & &1.entry_ordinal)
    assert ordinals == Enum.to_list(1..24)
    assert length(ordinals) == length(Enum.uniq(ordinals))
  end
end
