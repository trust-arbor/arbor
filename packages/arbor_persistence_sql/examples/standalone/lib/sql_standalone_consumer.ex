defmodule SQLStandaloneConsumer do
  @moduledoc "Explicit SQL installation and cross-VM public Core recovery proof."

  alias Arbor.Persistence.{Core, EventLog, Record}
  alias Arbor.Persistence.Contracts.Record, as: OwnedRecord
  alias Arbor.Persistence.EventLog.Ecto, as: Log
  alias Arbor.Persistence.QueryableStore.Postgres, as: Records
  alias Arbor.Persistence.SQL.Repo
  alias PersistenceAdapterQualification, as: Proof

  @namespace :cold_consumer
  @stream "cold-consumer"

  def install! do
    assert_idle!()

    with_repo(fn ->
      versions = Ecto.Migrator.run(Repo, :up, all: true, log: false)
      true = length(versions) == 11
    end)

    assert_idle!()
    IO.puts("PERSISTENCE_SQL_INSTALL_OK")
    :ok
  end

  def write! do
    assert_idle!()

    with_repo(fn ->
      {:ok, :node_restart} = Core.durability_class(@namespace, Records, repo: Repo)
      :ok = Core.put(@namespace, Records, "key", Record.new("key", %{"value" => 1}), repo: Repo)
      {:ok, %OwnedRecord{generation: 1, revision: 1} = first} = get_record()

      {:ok, %OwnedRecord{generation: 1, revision: 2} = generation_one} =
        Core.compare_and_swap(
          @namespace,
          Records,
          "key",
          {:value, first},
          Record.update(first, %{"value" => 2}),
          repo: Repo
        )

      :ok = Core.delete(@namespace, Records, "key", repo: Repo)
      {:error, :not_found} = get_record()
      :ok = Core.put(@namespace, Records, "key", Record.new("key", %{"value" => 3}), repo: Repo)
      {:ok, %OwnedRecord{generation: 2, revision: 1} = reborn} = get_record()

      {:ok, %OwnedRecord{generation: 2, revision: 2} = acknowledged} =
        Core.compare_and_swap(
          @namespace,
          Records,
          "key",
          {:value, reborn},
          Record.update(reborn, %{"value" => 42}),
          repo: Repo
        )

      {:ok, ^acknowledged} = get_record()
      submitted = Core.new_event(@stream, "cold.ready", %{"value" => 42})
      {:ok, operation} = EventLog.build_operation(@stream, [submitted])

      {:ok, [event]} =
        Core.append(@namespace, Log, @stream, submitted, repo: Repo, expected_version: 0)

      true = Core.committed_event_matches_submission?(@stream, submitted, event)
      fingerprint = Core.canonical_event_fingerprint(@stream, event)
      true = is_binary(fingerprint) and fingerprint == event.operation_fingerprint

      receipt = %{
        record: acknowledged,
        generation_one: generation_one,
        submitted: submitted,
        event: event,
        operation: operation,
        fingerprint: fingerprint
      }

      verify_receipt!(receipt)
      Proof.save_receipt!(receipt)
    end)

    assert_idle!()
    IO.puts("PERSISTENCE_SQL_WRITE_OK")
    :ok
  end

  def read! do
    assert_idle!()
    receipt = Proof.read_receipt!()
    with_repo(fn -> verify_receipt!(receipt) end)
    assert_idle!()
    IO.puts("PERSISTENCE_SQL_READ_OK")
    :ok
  end

  defp verify_receipt!(receipt) do
    %{record: record, generation_one: previous, event: event, operation: operation} = receipt
    %OwnedRecord{generation: 2, revision: 2, data: %{"value" => 42}} = record
    {:ok, ^record} = get_record()

    {:error, :conflict} =
      Core.compare_and_swap(
        @namespace,
        Records,
        "key",
        {:value, previous},
        Record.update(previous, %{"stale" => true}),
        repo: Repo
      )

    {:ok, ^record} = get_record()
    {:ok, [^event]} = Core.read_stream(@namespace, Log, @stream, repo: Repo)
    {:ok, ^event} = Core.read_stream_head(@namespace, Log, @stream, repo: Repo)
    true = Core.committed_event_matches_submission?(@stream, receipt.submitted, event)
    true = Core.canonical_event_fingerprint(@stream, event) == receipt.fingerprint
    true = event.operation_fingerprint == receipt.fingerprint
    {:ok, {:committed, [^event]}} = Core.reconcile_append(@namespace, Log, operation, repo: Repo)

    {:error, :version_conflict} =
      Core.append(@namespace, Log, @stream, Core.new_event(@stream, "stale.parent", %{}),
        repo: Repo,
        expected_version: 0
      )

    {:ok, [^event]} = Core.read_stream(@namespace, Log, @stream, repo: Repo)
    :ok
  end

  defp get_record, do: Core.get(@namespace, Records, "key", repo: Repo)
  defp with_repo(fun), do: Proof.with_child(Repo, fun)

  defp assert_idle! do
    {:ok, _started} = Application.ensure_all_started(:sql_standalone_consumer)
    nil = Process.whereis(Repo)
    Proof.assert_closure!(:arbor_persistence_sql)
    :ok
  end
end
