defmodule Arbor.Persistence.EventLog.EctoPurgeSecurityRegressionTest do
  use Arbor.Persistence.DatabaseCase, async: false

  import Ecto.Query

  alias Arbor.Persistence
  alias Arbor.Persistence.EventLog
  alias Arbor.Persistence.EventLog.Ecto, as: EctoEventLog
  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.{Event, EventLogOperation}

  @moduletag :integration
  @moduletag :database

  setup do
    Repo.delete_all(EventLogOperation)
    Repo.delete_all(Event)
    :ok
  end

  test "security regression: transactional purge removes one stream and its operation ledger" do
    target = "ecto-purge-target"
    survivor = "ecto-purge-survivor"

    target_events = [
      Arbor.Persistence.Event.new(target, "target.created", %{"ordinal" => 1}),
      Arbor.Persistence.Event.new(target, "target.updated", %{"ordinal" => 2})
    ]

    survivor_event =
      Arbor.Persistence.Event.new(survivor, "survivor.created", %{"ordinal" => 1})

    assert {:ok, target_operation} = EventLog.build_operation(target, target_events)
    assert {:ok, survivor_operation} = EventLog.build_operation(survivor, [survivor_event])

    assert {:ok, [_first, _second]} =
             Persistence.append(:ecto_purge, EctoEventLog, target, target_events, repo: Repo)

    assert {:ok, [surviving]} =
             Persistence.append(:ecto_purge, EctoEventLog, survivor, survivor_event, repo: Repo)

    assert row_count(Event, target) == 2
    assert row_count(EventLogOperation, target) == 1
    assert %EventLogOperation{} = Repo.get(EventLogOperation, target_operation.operation_id)

    assert :ok =
             Persistence.purge_stream(:ecto_purge, EctoEventLog, target, repo: Repo)

    assert row_count(Event, target) == 0
    assert row_count(EventLogOperation, target) == 0
    assert row_count(Event, survivor) == 1
    assert row_count(EventLogOperation, survivor) == 1
    assert {:ok, []} = Persistence.read_stream(:ecto_purge, EctoEventLog, target, repo: Repo)
    assert {:ok, 0} = Persistence.stream_version(:ecto_purge, EctoEventLog, target, repo: Repo)
    refute Persistence.stream_exists?(:ecto_purge, EctoEventLog, target, repo: Repo)

    Enum.each(target_events, fn event ->
      assert {:ok, nil} =
               Persistence.event_identity(:ecto_purge, EctoEventLog, target, event.id, repo: Repo)
    end)

    assert :ok =
             Persistence.purge_stream(:ecto_purge, EctoEventLog, target, repo: Repo)

    assert {:ok, [remaining]} =
             Persistence.read_stream(:ecto_purge, EctoEventLog, survivor, repo: Repo)

    assert remaining.id == surviving.id
    assert remaining.global_position == surviving.global_position

    assert {:ok, {:committed, [reconciled]}} =
             Persistence.reconcile_append(
               :ecto_purge,
               EctoEventLog,
               survivor_operation,
               repo: Repo
             )

    assert reconciled.id == survivor_event.id
  end

  test "security regression: operation-ledger failure rolls back event deletion and retry converges" do
    stream_id = "ecto-purge-transaction-rollback"
    event = Arbor.Persistence.Event.new(stream_id, "target.created", %{})

    assert {:ok, [_]} =
             Persistence.append(:ecto_purge, EctoEventLog, stream_id, event, repo: Repo)

    install_operation_delete_blocker(stream_id)

    assert {:error, {:purge_indeterminate, ^stream_id}} =
             Persistence.purge_stream(:ecto_purge, EctoEventLog, stream_id,
               repo: Repo,
               purge_timeout_ms: 1_000
             )

    assert row_count(Event, stream_id) == 1
    assert row_count(EventLogOperation, stream_id) == 1

    remove_operation_delete_blocker()

    assert :ok =
             Persistence.purge_stream(:ecto_purge, EctoEventLog, stream_id, repo: Repo)

    assert row_count(Event, stream_id) == 0
    assert row_count(EventLogOperation, stream_id) == 0
  end

  defp row_count(schema, stream_id) do
    from(row in schema, where: row.stream_id == ^stream_id, select: count())
    |> Repo.one!()
  end

  defp install_operation_delete_blocker(stream_id) do
    escaped_stream_id = String.replace(stream_id, "'", "''")

    case repo_adapter() do
      Ecto.Adapters.Postgres ->
        Repo.query!("""
        CREATE OR REPLACE FUNCTION event_log_purge_test_block_delete()
        RETURNS trigger AS $$
        BEGIN
          IF OLD.stream_id = '#{escaped_stream_id}' THEN
            RAISE EXCEPTION 'blocked event-log operation deletion';
          END IF;
          RETURN OLD;
        END;
        $$ LANGUAGE plpgsql
        """)

        Repo.query!("""
        CREATE TRIGGER event_log_purge_test_block_delete
        BEFORE DELETE ON event_log_operations
        FOR EACH ROW EXECUTE FUNCTION event_log_purge_test_block_delete()
        """)

      Ecto.Adapters.SQLite3 ->
        Repo.query!("""
        CREATE TRIGGER event_log_purge_test_block_delete
        BEFORE DELETE ON event_log_operations
        WHEN OLD.stream_id = '#{escaped_stream_id}'
        BEGIN
          SELECT RAISE(ABORT, 'blocked event-log operation deletion');
        END
        """)
    end
  end

  defp remove_operation_delete_blocker do
    case repo_adapter() do
      Ecto.Adapters.Postgres ->
        Repo.query!(
          "DROP TRIGGER IF EXISTS event_log_purge_test_block_delete ON event_log_operations"
        )

        Repo.query!("DROP FUNCTION IF EXISTS event_log_purge_test_block_delete()")

      Ecto.Adapters.SQLite3 ->
        Repo.query!("DROP TRIGGER IF EXISTS event_log_purge_test_block_delete")
    end
  end

  defp repo_adapter, do: apply(Repo, :__adapter__, [])
end
