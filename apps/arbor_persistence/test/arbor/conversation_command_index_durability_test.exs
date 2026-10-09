defmodule Arbor.Persistence.ConversationCommandIndexDurabilityTest do
  use ExUnit.Case, async: false
  alias Arbor.Persistence
  @moduletag :database
  @moduletag :isolated_repo

  if Arbor.Persistence.Repo.__adapter__() != Ecto.Adapters.SQLite3 do
    @moduletag skip: "This reopen qualification owns a private SQLite database"
  end

  defmodule IsolatedRepo do
    use Ecto.Repo, otp_app: :arbor_persistence, adapter: Ecto.Adapters.SQLite3
  end

  test "committed command identity and source watermark survive an actual SQL repository reopen" do
    root =
      Path.join(System.tmp_dir!(), "command_index_reopen_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    opts = [database: Path.join(root, "index.db"), pool_size: 1]
    previous = Application.get_env(:arbor_persistence, :sql_repository)
    Application.put_env(:arbor_persistence, :sql_repository, IsolatedRepo)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:arbor_persistence, :sql_repository, previous),
        else: Application.delete_env(:arbor_persistence, :sql_repository)

      File.rm_rf!(root)
    end)

    start_supervised!({IsolatedRepo, opts})

    migration =
      Path.expand(
        "../../priv/repo/migrations/20261003000001_create_conversation_command_index.exs",
        __DIR__
      )

    Code.require_file(migration)

    :ok =
      Ecto.Migrator.up(
        IsolatedRepo,
        20_261_003_000_001,
        Arbor.Persistence.Repo.Migrations.CreateConversationCommandIndex,
        log: false
      )

    scope = %{
      owner_id: "human_reopen",
      target_agent_id: "agent_reopen",
      engagement_id: "eng_reopen",
      stream_id: "conversation_reopen"
    }

    row = %{
      command_id: "older_active",
      admitted_event_number: 1,
      source_event_number: 3,
      delivery_status: "dispatch_started",
      cancellation_status: "none",
      cancellation_termination: nil
    }

    assert {:ok, %{watermark: 3, projected: 1}} =
             Persistence.project_conversation_commands(scope, [row], %{from: 0, to: 3})

    :ok = stop_supervised(IsolatedRepo)
    start_supervised!({IsolatedRepo, opts})
    assert {:ok, 3} = Persistence.conversation_command_index_watermark(scope)

    assert {:ok, %{commands: [^row], watermark: 3}} =
             Persistence.read_conversation_commands(scope)

    assert {:ok, %{watermark: 3, projected: 0}} =
             Persistence.project_conversation_commands(scope, [row], %{from: 0, to: 3})
  end

  test "security regression bounded record and index reads do not acquire a SQLite writer lock" do
    root =
      Path.join(
        System.tmp_dir!(),
        "command_index_reader_lock_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    opts = [
      database: Path.join(root, "index.db"),
      pool_size: 2,
      journal_mode: :wal,
      busy_timeout: 50,
      default_transaction_mode: :immediate,
      custom_pragmas: [recursive_triggers: true]
    ]

    previous = Application.get_env(:arbor_persistence, :sql_repository)
    Application.put_env(:arbor_persistence, :sql_repository, IsolatedRepo)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:arbor_persistence, :sql_repository, previous),
        else: Application.delete_env(:arbor_persistence, :sql_repository)

      File.rm_rf!(root)
    end)

    start_supervised!({IsolatedRepo, Keyword.put(opts, :pool_size, 1)})
    migrations = Path.expand("../../priv/repo/migrations", __DIR__)
    migrated = Ecto.Migrator.run(IsolatedRepo, migrations, :up, all: true, log: false)
    assert 20_261_003_000_001 in migrated

    scope = %{
      owner_id: "human_reader",
      target_agent_id: "agent_reader",
      engagement_id: "eng_reader",
      stream_id: "conversation_reader"
    }

    row = %{
      command_id: "readable",
      admitted_event_number: 1,
      source_event_number: 1,
      delivery_status: "admitted",
      cancellation_status: "none",
      cancellation_termination: nil
    }

    assert {:ok, _} = Persistence.project_conversation_command(scope, row, 1)

    event =
      Arbor.Persistence.Event.new(scope.stream_id, "transition", %{text: "saved"},
        id: "reader_event"
      )

    assert {:ok, _} =
             Persistence.append(
               :journal,
               Arbor.Persistence.EventLog.Ecto,
               scope.stream_id,
               [event],
               repo: IsolatedRepo
             )

    :ok = stop_supervised(IsolatedRepo)
    start_supervised!({IsolatedRepo, opts})
    observer = self()

    writer =
      Task.async(fn ->
        IsolatedRepo.transaction(
          fn ->
            IsolatedRepo.query!(
              "UPDATE conversation_command_checkpoints SET watermark = watermark"
            )

            send(observer, {:writer_locked, self()})

            receive do
              :release_writer -> :released
            after
              5_000 -> raise "writer barrier was not released"
            end
          end,
          mode: :immediate
        )
      end)

    assert_receive {:writer_locked, writer_pid}, 5_000

    try do
      assert {:ok, %{events: [%{id: "reader_event"}], head: %{event_number: 1}}} =
               Persistence.read_event_records(
                 :journal,
                 Arbor.Persistence.EventLog.Ecto,
                 scope.stream_id,
                 ["reader_event"],
                 repo: IsolatedRepo,
                 max_event_number: 1
               )

      assert {:ok, %{commands: [^row], watermark: 1}} =
               Persistence.read_conversation_commands(scope)
    after
      send(writer_pid, :release_writer)
    end

    assert {:ok, :released} = Task.await(writer, 5_000)
  end

  test "security regression a busy projection returns before lock release and never commits later" do
    root =
      Path.join(System.tmp_dir!(), "command_index_busy_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    opts = [
      database: Path.join(root, "index.db"),
      pool_size: 2,
      journal_mode: :wal,
      busy_timeout: 5_000,
      custom_pragmas: [recursive_triggers: true]
    ]

    previous = Application.get_env(:arbor_persistence, :sql_repository)
    Application.put_env(:arbor_persistence, :sql_repository, IsolatedRepo)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:arbor_persistence, :sql_repository, previous),
        else: Application.delete_env(:arbor_persistence, :sql_repository)

      File.rm_rf!(root)
    end)

    start_supervised!({IsolatedRepo, Keyword.put(opts, :pool_size, 1)})
    migrations = Path.expand("../../priv/repo/migrations", __DIR__)
    Ecto.Migrator.run(IsolatedRepo, migrations, :up, all: true, log: false)
    :ok = stop_supervised(IsolatedRepo)
    start_supervised!({IsolatedRepo, opts})

    scope = %{
      owner_id: "human_busy",
      target_agent_id: "agent_busy",
      engagement_id: "eng_busy",
      stream_id: "conversation_busy"
    }

    row = %{
      command_id: "not_committed",
      admitted_event_number: 1,
      source_event_number: 1,
      delivery_status: "admitted",
      cancellation_status: "none",
      cancellation_termination: nil
    }

    observer = self()

    writer =
      Task.async(fn ->
        IsolatedRepo.transaction(
          fn ->
            send(observer, {:writer_locked, self()})

            receive do
              :release_writer -> :released
            after
              5_000 -> raise "writer barrier was not released"
            end
          end,
          mode: :immediate
        )
      end)

    assert_receive {:writer_locked, writer_pid}, 5_000
    # The writer occupies one connection. These reads prove the other is fully
    # connected and available before projection attempts native acquisition.
    assert Arbor.Persistence.SQLiteBusyTimeout.get(IsolatedRepo) == 5_000
    assert %{rows: [["wal"]]} = IsolatedRepo.query!("PRAGMA journal_mode")
    projection = Task.async(fn -> Persistence.project_conversation_command(scope, row, 1) end)

    try do
      # With the old native busy_timeout this call waits for lock release and
      # commits the page. The assertion observes the actual WAL writer lock,
      # rather than replacing the database with an adapter that returns :busy.
      assert {:ok, {:error, :conversation_index_unavailable}} = Task.yield(projection, 500)

      assert Arbor.Persistence.SQLiteBusyTimeout.get(IsolatedRepo) == 5_000
      assert {:ok, 0} = Persistence.conversation_command_index_watermark(scope)
    after
      send(writer_pid, :release_writer)
      Task.await(writer, 5_000)
      if Process.alive?(projection.pid), do: Task.await(projection, 5_000)
    end

    # A return of :unavailable is final for this attempt. Releasing the writer
    # cannot resurrect an orphaned projection or advance its source watermark.
    assert {:ok, %{commands: [], watermark: 0}} = Persistence.read_conversation_commands(scope)

    event = Arbor.Persistence.Event.new(scope.stream_id, "transition", %{}, id: "after_busy")

    assert {:ok, _} =
             Persistence.append(
               :journal,
               Arbor.Persistence.EventLog.Ecto,
               scope.stream_id,
               [event],
               repo: IsolatedRepo,
               timeout: 500
             )

    assert {:ok, %{events: [%{id: "after_busy"}], head: %{event_number: 1}}} =
             Persistence.read_event_records(
               :journal,
               Arbor.Persistence.EventLog.Ecto,
               scope.stream_id,
               ["after_busy"],
               repo: IsolatedRepo
             )

    assert {:ok, %{watermark: 1, projected: 1}} =
             Persistence.project_conversation_command(scope, row, 1)
  end
end
