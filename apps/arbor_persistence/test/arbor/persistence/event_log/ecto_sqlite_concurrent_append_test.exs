defmodule Arbor.Persistence.EventLog.EctoSQLiteConcurrentAppendTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.Ecto, as: EventLog

  @moduletag capture_log: true
  @moduletag :integration

  defmodule SQLitePoolRepo do
    use Ecto.Repo,
      otp_app: :arbor_persistence,
      adapter: Ecto.Adapters.SQLite3
  end

  setup_all do
    database =
      Path.join(
        System.tmp_dir!(),
        "arbor-event-log-concurrency-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!(
      {SQLitePoolRepo,
       database: database,
       pool: DBConnection.ConnectionPool,
       pool_size: 12,
       busy_timeout: 0,
       journal_mode: :wal,
       queue_target: 100,
       queue_interval: 1_000}
    )

    SQLitePoolRepo.query!("""
    CREATE TABLE events (
      id TEXT PRIMARY KEY,
      stream_id TEXT NOT NULL,
      event_number INTEGER NOT NULL,
      global_position INTEGER,
      type TEXT NOT NULL,
      data TEXT DEFAULT '{}',
      metadata TEXT DEFAULT '{}',
      agent_id TEXT,
      causation_id TEXT,
      correlation_id TEXT,
      event_timestamp TEXT,
      committed_at TEXT,
      created_at TEXT NOT NULL
    )
    """)

    SQLitePoolRepo.query!("""
    CREATE UNIQUE INDEX events_stream_id_event_number_index
    ON events (stream_id, event_number)
    """)

    SQLitePoolRepo.query!("""
    CREATE TRIGGER events_set_committed_at_after_insert
    AFTER INSERT ON events
    FOR EACH ROW
    BEGIN
      UPDATE events
      SET committed_at = STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
      WHERE id = NEW.id;
    END
    """)

    on_exit(fn ->
      Enum.each([database, database <> "-shm", database <> "-wal"], &File.rm/1)
    end)

    :ok
  end

  setup do
    SQLitePoolRepo.delete_all(Arbor.Persistence.Schemas.Event)
    :ok
  end

  test "pooled ordinary appends retry BEGIN IMMEDIATE contention without exits" do
    writer_count = 40
    stream_id = "sqlite-ordinary-#{System.unique_integer([:positive])}"

    task_results =
      1..writer_count
      |> Task.async_stream(
        fn writer ->
          EventLog.append(
            stream_id,
            Event.new(stream_id, "ordinary", %{writer: writer}),
            repo: SQLitePoolRepo
          )
        end,
        max_concurrency: writer_count,
        ordered: false,
        timeout: 15_000
      )
      |> Enum.to_list()

    assert Enum.all?(task_results, &match?({:ok, {:ok, [_]}}, &1)),
           "ordinary append failure or exit: #{inspect(task_results)}"

    assert {:ok, persisted} = EventLog.read_stream(stream_id, repo: SQLitePoolRepo)
    assert Enum.map(persisted, & &1.event_number) == Enum.to_list(1..writer_count)
  end

  test "pooled exact-version appends retain one-winner CAS" do
    writer_count = 24
    stream_id = "sqlite-cas-#{System.unique_integer([:positive])}"

    task_results =
      1..writer_count
      |> Task.async_stream(
        fn writer ->
          EventLog.append(
            stream_id,
            Event.new(stream_id, "terminal", %{writer: writer}),
            repo: SQLitePoolRepo,
            expected_version: 0
          )
        end,
        max_concurrency: writer_count,
        ordered: false,
        timeout: 15_000
      )
      |> Enum.to_list()

    assert Enum.all?(task_results, &match?({:ok, _result}, &1)),
           "exact-version append exited: #{inspect(task_results)}"

    append_results = Enum.map(task_results, fn {:ok, result} -> result end)
    assert Enum.count(append_results, &match?({:ok, [_]}, &1)) == 1
    assert Enum.count(append_results, &(&1 == {:error, :version_conflict})) == writer_count - 1
    assert {:ok, 1} = EventLog.stream_version(stream_id, repo: SQLitePoolRepo)
  end

  test "lock deadline exhaustion returns a stable error and never exits" do
    parent = self()

    locker =
      Task.async(fn ->
        SQLitePoolRepo.transaction(
          fn ->
            send(parent, :sqlite_lock_acquired)

            receive do
              :release_sqlite_lock -> :ok
            after
              2_000 -> raise "test lock release timed out"
            end
          end,
          mode: :immediate
        )
      end)

    assert_receive :sqlite_lock_acquired, 1_000

    try do
      event = Event.new("sqlite-busy", "ordinary", %{})

      assert {:error, :database_busy} =
               EventLog.append("sqlite-busy", event,
                 repo: SQLitePoolRepo,
                 sqlite_busy_deadline_ms: 40
               )
    after
      send(locker.pid, :release_sqlite_lock)
    end

    assert {:ok, _result} = Task.yield(locker, 1_000)
    assert {:ok, 0} = EventLog.stream_version("sqlite-busy", repo: SQLitePoolRepo)
  end
end
