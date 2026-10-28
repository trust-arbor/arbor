defmodule EventStoreStandaloneConsumer do
  @moduledoc "Explicit EventStore installation and cross-VM event recovery proof."

  alias Arbor.Persistence.{Core, EventLog}
  alias Arbor.Persistence.Ecto.EventLog, as: Log
  alias Arbor.Persistence.Ecto.{EventLogSchema, EventStore}
  alias PersistenceAdapterQualification, as: Proof

  @namespace :cold_consumer
  @stream "cold-consumer"

  def install! do
    assert_idle!()
    config = EventStore.config()
    :ok = Elixir.EventStore.Tasks.Init.exec(config, quiet: true)

    options =
      config
      |> Elixir.EventStore.Config.default_postgrex_opts()
      |> Keyword.put(:types, Elixir.EventStore.PostgresTypes)

    Proof.with_child({Postgrex, options}, fn connection ->
      :ok = EventLogSchema.migrate!(connection, "public")
    end)

    assert_idle!()
    IO.puts("PERSISTENCE_EVENTSTORE_INSTALL_OK")
    :ok
  end

  def write! do
    assert_idle!()

    Proof.with_child(EventStore, fn ->
      Code.ensure_loaded!(Log)
      {:error, :unsupported} = Core.durability_class(@namespace, Log)
      submitted = Core.new_event(@stream, "cold.ready", %{"value" => 42})
      {:ok, operation} = EventLog.build_operation(@stream, [submitted])
      {:ok, [event]} = Core.append(@namespace, Log, @stream, submitted, expected_version: 0)
      true = Core.committed_event_matches_submission?(@stream, submitted, event)
      fingerprint = Core.canonical_event_fingerprint(@stream, event)
      true = is_binary(fingerprint) and fingerprint == event.operation_fingerprint

      receipt = %{
        submitted: submitted,
        event: event,
        operation: operation,
        fingerprint: fingerprint
      }

      verify_receipt!(receipt)
      Proof.save_receipt!(receipt)
    end)

    assert_idle!()
    IO.puts("PERSISTENCE_EVENTSTORE_WRITE_OK")
    :ok
  end

  def read! do
    assert_idle!()
    receipt = Proof.read_receipt!()
    Proof.with_child(EventStore, fn -> verify_receipt!(receipt) end)
    assert_idle!()
    IO.puts("PERSISTENCE_EVENTSTORE_READ_OK")
    :ok
  end

  defp verify_receipt!(receipt) do
    %{event: event, operation: operation} = receipt
    Code.ensure_loaded!(Log)
    {:error, :unsupported} = Core.durability_class(@namespace, Log)
    {:ok, [^event]} = Core.read_stream(@namespace, Log, @stream)
    {:ok, ^event} = Core.read_stream_head(@namespace, Log, @stream)
    true = Core.committed_event_matches_submission?(@stream, receipt.submitted, event)
    true = Core.canonical_event_fingerprint(@stream, event) == receipt.fingerprint
    true = event.operation_fingerprint == receipt.fingerprint
    {:ok, {:committed, [^event]}} = Core.reconcile_append(@namespace, Log, operation)

    {:error, :version_conflict} =
      Core.append(@namespace, Log, @stream, Core.new_event(@stream, "stale.parent", %{}),
        expected_version: 0
      )

    {:ok, [^event]} = Core.read_stream(@namespace, Log, @stream)
    :ok
  end

  defp assert_idle! do
    {:ok, _started} = Application.ensure_all_started(:eventstore_standalone_consumer)
    nil = Process.whereis(EventStore)
    Proof.assert_closure!(:arbor_persistence_eventstore)
    :ok
  end
end
