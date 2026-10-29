defmodule CustodyStandaloneConsumer.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([CustodyStandaloneConsumer.Owner],
      strategy: :one_for_one,
      name: CustodyStandaloneConsumer.Supervisor
    )
  end
end

defmodule CustodyStandaloneConsumer.Owner do
  @moduledoc false
  use GenServer

  @anchor {__MODULE__, :private_counter}
  @schema :counter

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.flag(:sensitive, true)
    :ok = Arbor.Custody.open_process_private_state(@anchor, @schema, 0, &valid_counter?/1)
    {:ok, %{authenticated_calls: Arbor.Custody.new_authenticated_call_custody()}}
  end

  @impl true
  def handle_call(_request, _from, state), do: {:reply, {:error, :unauthorized}, state}

  @impl true
  def handle_info(message, state) do
    case Arbor.Custody.handle_authenticated_call(message, state.authenticated_calls) do
      {:authenticated, caller, :read, reply_to} ->
        reply_with_counter(reply_to, caller)
        {:noreply, state}

      {:authenticated, caller, :increment, reply_to} ->
        :ok =
          Arbor.Custody.update_process_private_state(
            @anchor,
            @schema,
            &(&1 + 1),
            &valid_counter?/1
          )

        reply_with_counter(reply_to, caller)
        {:noreply, state}

      _pending_or_rejected ->
        {:noreply, state}
    end
  end

  defp reply_with_counter(reply_to, caller) do
    {:ok, counter} =
      Arbor.Custody.fetch_process_private_state(@anchor, @schema, &valid_counter?/1)

    :ok = Arbor.Custody.reply_authenticated_call(reply_to, {:ok, caller, counter})
  end

  defp valid_counter?(value), do: is_integer(value) and value >= 0
end

defmodule CustodyStandaloneConsumer do
  @moduledoc false

  @owner CustodyStandaloneConsumer.Owner
  @forbidden_apps ~w(eventstore ecto ecto_sql ecto_sqlite3 exqlite postgrex)

  def verify!(opts \\ []) do
    if Keyword.get(opts, :require_no_mix, false) do
      false = Code.ensure_loaded?(Mix)
      release_root = Path.expand(System.fetch_env!("CUSTODY_RELEASE_ROOT")) <> "/"

      for module <- [__MODULE__, Arbor.Custody] do
        path = module |> :code.which() |> List.to_string() |> Path.expand()
        true = String.starts_with?(path, release_root)
      end
    end

    {:ok, _started} = Application.ensure_all_started(:custody_standalone_consumer)

    {:ok, owner} =
      Arbor.Custody.supervised_registered_child_pid(
        :custody_standalone_consumer,
        [@owner],
        @owner
      )

    ^owner = Process.whereis(@owner)
    caller = self()
    {:ok, ^caller, before_count} = Arbor.Custody.authenticated_call(owner, :read)

    tag = make_ref()
    send(owner, {:"$gen_call", {self(), tag}, :increment})

    receive do
      {^tag, {:error, :unauthorized}} -> :ok
    after
      5_000 -> raise "Ordinary call was not rejected"
    end

    :sys.replace_state(owner, &Map.put(&1, :authenticated_calls, make_ref()))
    {:ok, ^caller, next_count} = Arbor.Custody.authenticated_call(owner, :increment)
    true = next_count == before_count + 1
    verify_private_slot!()
    verify_registered_impostor!()
    report = application_closure!()

    File.write!(
      System.fetch_env!("CUSTODY_PROBE_REPORT"),
      inspect(report, pretty: true, limit: :infinity) <> "\n"
    )

    IO.puts("Custody standalone probe passed")
    :ok
  end

  defp verify_private_slot! do
    anchor = {__MODULE__, make_ref()}
    validator = &is_integer/1
    :ok = Arbor.Custody.open_process_private_state(anchor, :value, 7, validator)

    try do
      {:ok, 7} = Arbor.Custody.fetch_process_private_state(anchor, :value, validator)
      :ok = Arbor.Custody.replace_process_private_state(anchor, :value, 8, validator)
      :ok = Arbor.Custody.update_process_private_state(anchor, :value, &(&1 + 1), validator)
      {:ok, 9} = Arbor.Custody.fetch_process_private_state(anchor, :value, validator)
    after
      :ok = Arbor.Custody.close_process_private_state(anchor)
    end

    {:error, :invalid_private_state} =
      Arbor.Custody.fetch_process_private_state(anchor, :value, validator)
  end

  defp verify_registered_impostor! do
    {pid, monitor} = spawn_monitor(fn -> receive do: (:stop -> :ok) end)

    try do
      true = Process.register(pid, CustodyStandaloneConsumer.Impostor)

      {:error, :not_supervised_owner} =
        Arbor.Custody.supervised_registered_child_pid(
          :custody_standalone_consumer,
          [@owner],
          CustodyStandaloneConsumer.Impostor
        )
    after
      send(pid, :stop)
    end

    receive do
      {:DOWN, ^monitor, :process, ^pid, :normal} -> :ok
    after
      5_000 -> raise "Owned impostor did not stop"
    end
  end

  defp application_closure! do
    code_paths = :code.get_path() |> Enum.map(&List.to_string/1) |> Enum.sort()

    compiled =
      code_paths
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.app")))
      |> Enum.map(&Path.basename(&1, ".app"))
      |> Enum.uniq()
      |> Enum.sort()

    loaded =
      Application.loaded_applications()
      |> Enum.map(&(elem(&1, 0) |> Atom.to_string()))
      |> Enum.sort()

    started =
      Application.started_applications()
      |> Enum.map(&(elem(&1, 0) |> Atom.to_string()))
      |> Enum.sort()

    forbidden =
      Enum.filter(Enum.uniq(compiled ++ loaded ++ started), fn app ->
        (String.starts_with?(app, "arbor_") and app != "arbor_custody") or
          app in @forbidden_apps or String.starts_with?(app, "phoenix")
      end)

    [] = forbidden

    for module <- [
          Arbor.Common,
          Arbor.KernelRuntime,
          Arbor.Signals,
          Arbor.Security,
          Ecto.Repo,
          Phoenix.LiveView
        ] do
      false = Code.ensure_loaded?(module)
    end

    %{compiled: compiled, loaded: loaded, started: started, code_paths: code_paths}
  end
end
