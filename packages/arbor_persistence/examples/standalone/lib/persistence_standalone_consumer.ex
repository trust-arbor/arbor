defmodule PersistenceStandaloneConsumer do
  @moduledoc "Independent public Core canary, executable in a production release without Mix."

  alias Arbor.Persistence.{Core, Event, EventLog, Record, Store}
  alias Arbor.Persistence.Contracts.Record, as: OwnedRecord

  @agent_store __MODULE__.AgentStore
  @ets_store __MODULE__.ETSStore
  @event_log __MODULE__.EventLog

  def verify! do
    {:ok, _started} = Application.ensure_all_started(:persistence_standalone_consumer)
    assert_library_lifetime!()
    assert_independent_closure!()

    for {backend, name} <- [{Store.Agent, @agent_store}, {Store.ETS, @ets_store}] do
      verify_store!(backend, name)
    end

    verify_event_log!()
    assert_library_lifetime!()
    assert_independent_closure!()
    IO.puts("PERSISTENCE_CORE_STANDALONE_OK")
    :ok
  end

  defp verify_store!(backend, name) do
    {:ok, owner} = backend.start_link(name: name)

    try do
      {:ok, :process_lifetime} = Core.durability_class(name, backend)
      initial = Record.new("key", %{value: 1}, id: "standalone_record")
      :ok = Core.put(name, backend, "key", initial)

      {:ok, %OwnedRecord{id: "standalone_record", generation: 1, revision: 1} = first} =
        Core.get(name, backend, "key")

      %{value: 1} = first.data

      {:ok, %OwnedRecord{id: "standalone_record", generation: 1, revision: 2} = second} =
        Core.compare_and_swap(
          name,
          backend,
          "key",
          {:value, first},
          Record.update(first, %{value: 2})
        )

      {:ok, ^second} = Core.get(name, backend, "key")
      :ok = Core.delete(name, backend, "key")
      {:error, :not_found} = Core.get(name, backend, "key")
      reborn = Record.new("key", %{value: 3}, id: "standalone_reborn")
      :ok = Core.put(name, backend, "key", reborn)

      {:ok, %OwnedRecord{id: "standalone_reborn", generation: 2, revision: 1} = third} =
        Core.get(name, backend, "key")

      {:error, :conflict} =
        Core.compare_and_swap(
          name,
          backend,
          "key",
          {:value, second},
          Record.update(second, %{stale: true})
        )

      {:error, :key_mismatch} = Core.put(name, backend, "different", third)
      {:error, :not_found} = Core.get(name, backend, "different")
      {:ok, ^third} = Core.get(name, backend, "key")
      :ok = Core.compare_and_delete(name, backend, "key", third)
      {:error, :not_found} = Core.get(name, backend, "key")
    after
      GenServer.stop(owner)
    end

    nil = Process.whereis(name)
  end

  defp verify_event_log! do
    {:ok, owner} = EventLog.Agent.start_link(name: @event_log)

    try do
      event = Core.new_event("standalone", "ready", %{value: 42})

      {:ok, [%Event{event_number: 1, global_position: 1, data: %{"value" => 42}} = committed]} =
        Core.append(@event_log, EventLog.Agent, "standalone", event)

      true = committed.id == event.id
      {:ok, [^committed]} = Core.read_stream(@event_log, EventLog.Agent, "standalone")
      {:ok, [^committed]} = Core.append(@event_log, EventLog.Agent, "standalone", event)
      {:ok, [^committed]} = Core.read_stream(@event_log, EventLog.Agent, "standalone")
    after
      GenServer.stop(owner)
    end

    nil = Process.whereis(@event_log)
  end

  defp assert_library_lifetime! do
    mod = Application.spec(:arbor_persistence, :mod)
    true = mod in [nil, []]
    nil = Process.whereis(Arbor.Persistence.Supervisor)
    nil = Process.whereis(Arbor.Persistence.Core.Supervisor)
    nil = Process.whereis(@agent_store)
    nil = Process.whereis(@ets_store)
    nil = Process.whereis(@event_log)
  end

  defp assert_independent_closure! do
    loaded = for {app, _, _} <- Application.loaded_applications(), do: app
    started = for {app, _, _} <- Application.started_applications(), do: app

    compiled =
      :code.get_path()
      |> Enum.flat_map(fn path -> Path.wildcard(Path.join(List.to_string(path), "*.app")) end)
      |> Enum.map(fn path ->
        {:ok, [{:application, app, _properties}]} = :file.consult(String.to_charlist(path))
        app
      end)

    for {kind, applications} <- [compiled: compiled, loaded: loaded, started: started] do
      unexpected =
        applications
        |> Enum.filter(
          &(String.starts_with?(Atom.to_string(&1), "arbor_") and &1 != :arbor_persistence)
        )
        |> Enum.uniq()

      if unexpected != [] do
        raise "Unexpected #{kind} Arbor applications: #{inspect(unexpected)}"
      end

      true = :arbor_persistence in applications
    end

    for module <- [
          Arbor.Persistence,
          Arbor.Persistence.Repo,
          Arbor.Persistence.Host.Application,
          Arbor.Contracts,
          Arbor.Security,
          Arbor.Signals
        ] do
      if Code.ensure_loaded?(module), do: raise("Unexpected host module: #{inspect(module)}")
    end

    IO.puts(
      "PERSISTENCE_CORE_CLOSURE " <>
        Jason.encode!(%{
          compiled: Enum.sort(Enum.uniq(compiled)),
          loaded: Enum.sort(loaded),
          started: Enum.sort(started)
        })
    )
  end
end
