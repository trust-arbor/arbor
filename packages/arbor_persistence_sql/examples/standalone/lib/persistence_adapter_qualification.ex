defmodule PersistenceAdapterQualification do
  @moduledoc false

  def with_child(child, fun) when is_function(fun, 0),
    do: with_child(child, fn _pid -> fun.() end)

  def with_child(child, fun) when is_function(fun, 1) do
    {:ok, supervisor} = Supervisor.start_link([child], strategy: :one_for_one)

    try do
      [{_id, pid, _type, _modules}] = Supervisor.which_children(supervisor)
      fun.(pid)
    after
      Supervisor.stop(supervisor)
    end
  end

  def save_receipt!(receipt) do
    path = System.fetch_env!("PERSISTENCE_ACK_PATH")
    File.write!(path, :erlang.term_to_binary(receipt), [:binary, :exclusive])
    File.chmod!(path, 0o600)
    :ok
  end

  def read_receipt! do
    for module <- [
          Arbor.Persistence.Contracts.Record,
          Arbor.Persistence.Contracts.AppendOperation,
          Arbor.Persistence.Event,
          DateTime,
          Calendar.ISO
        ],
        do: Code.ensure_loaded!(module)

    System.fetch_env!("PERSISTENCE_ACK_PATH")
    |> File.read!()
    |> :erlang.binary_to_term([:safe])
  end

  def assert_closure!(adapter) do
    expected = Enum.sort([:arbor_persistence, adapter])
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
      arbor =
        applications
        |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "arbor_"))
        |> Enum.uniq()
        |> Enum.sort()

      if arbor != expected,
        do: raise("Unexpected #{kind} Arbor closure: #{inspect(arbor)}")
    end

    other_adapter =
      if adapter == :arbor_persistence_sql,
        do: Arbor.Persistence.Ecto.EventStore,
        else: Arbor.Persistence.SQL.Repo

    for module <- [
          Arbor.Persistence,
          Arbor.Persistence.Repo,
          Arbor.Persistence.Host.Application,
          Arbor.Contracts,
          Arbor.Security,
          Arbor.Signals,
          other_adapter
        ] do
      if Code.ensure_loaded?(module),
        do: raise("Unexpected host/adapter module: #{inspect(module)}")
    end

    true = Application.spec(:arbor_persistence, :mod) in [nil, []]
    nil = Process.whereis(Arbor.Persistence.Supervisor)

    IO.puts(
      "PERSISTENCE_ADAPTER_CLOSURE " <>
        Jason.encode!(%{
          compiled: Enum.sort(Enum.uniq(compiled)),
          loaded: Enum.sort(loaded),
          started: Enum.sort(started)
        })
    )

    :ok
  end
end
