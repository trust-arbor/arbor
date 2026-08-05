defmodule Arbor.Memory.Test.NodeRestartEventLog do
  @moduledoc false

  use GenServer

  alias Arbor.Persistence.EventLog.ETS

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    storage_name = Keyword.fetch!(opts, :storage_name)
    GenServer.start_link(__MODULE__, storage_name, name: name)
  end

  @impl true
  def init(storage_name), do: {:ok, storage_name}

  @impl true
  def handle_call(:storage_name, _from, storage_name), do: {:reply, storage_name, storage_name}

  def append(stream_id, events, opts) do
    with {:ok, storage_opts} <- storage_opts(opts) do
      ETS.append(stream_id, events, storage_opts)
    end
  end

  def reconcile_append(operation, opts) do
    with {:ok, storage_opts} <- storage_opts(opts) do
      ETS.reconcile_append(operation, storage_opts)
    end
  end

  def read_stream(stream_id, opts) do
    with {:ok, storage_opts} <- storage_opts(opts) do
      ETS.read_stream(stream_id, storage_opts)
    end
  end

  def durability_class(_opts), do: :node_restart

  defp storage_opts(opts) do
    name = Keyword.fetch!(opts, :name)
    storage_name = GenServer.call(name, :storage_name)
    {:ok, Keyword.put(opts, :name, storage_name)}
  rescue
    _ -> {:error, :store_unavailable}
  catch
    :exit, _reason -> {:error, :store_unavailable}
  end
end

defmodule Arbor.Memory.Test.IndeterminateEventLog do
  @moduledoc false

  alias Arbor.Persistence.EventLog

  def append(stream_id, events, opts) do
    with {:ok, _events, _preconditions, operation, _deadline} <-
           EventLog.prepare_append(stream_id, events, opts) do
      EventLog.indeterminate(operation)
    end
  end

  def reconcile_append(operation, _opts), do: EventLog.indeterminate(operation)
  def read_stream(_stream_id, _opts), do: {:error, :store_unavailable}
  def durability_class(_opts), do: :node_restart
end

defmodule Arbor.Memory.Test.DurableEventLog do
  @moduledoc false

  alias Arbor.Memory.Test.NodeRestartEventLog
  alias Arbor.Persistence.EventLog.ETS

  @config_key :maintenance_archive_target

  @spec start!() :: map()
  def start! do
    storage_name = unique_name(:arbor_memory_event_storage)
    sink_name = unique_name(:arbor_memory_event_sink)

    ExUnit.Callbacks.start_supervised!(%{
      id: storage_name,
      start: {ETS, :start_link, [[name: storage_name]]}
    })

    start_front!(sink_name, storage_name)

    target = %{name: sink_name, backend: NodeRestartEventLog, opts: []}
    lease_target!(target)

    %{sink_name: sink_name, storage_name: storage_name, target: target}
  end

  @spec restart_front!(map()) :: :ok
  def restart_front!(%{sink_name: sink_name, storage_name: storage_name}) do
    :ok = ExUnit.Callbacks.stop_supervised(sink_name)
    _pid = start_front!(sink_name, storage_name)
    :ok
  end

  @spec lease_target!(map() | keyword()) :: :ok
  def lease_target!(target) do
    original = Application.fetch_env(:arbor_memory, @config_key)
    Application.put_env(:arbor_memory, @config_key, target)

    ExUnit.Callbacks.on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:arbor_memory, @config_key, value)
        :error -> Application.delete_env(:arbor_memory, @config_key)
      end
    end)

    :ok
  end

  @spec restart_default_memory_events!() :: :ok
  def restart_default_memory_events! do
    :ok =
      Supervisor.terminate_child(
        Arbor.Memory.Supervisor,
        Arbor.Persistence.EventLog.ETS
      )

    case Supervisor.restart_child(
           Arbor.Memory.Supervisor,
           Arbor.Persistence.EventLog.ETS
         ) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
    end
  end

  defp start_front!(sink_name, storage_name) do
    ExUnit.Callbacks.start_supervised!(%{
      id: sink_name,
      start: {NodeRestartEventLog, :start_link, [[name: sink_name, storage_name: storage_name]]}
    })
  end

  defp unique_name(prefix),
    do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end
