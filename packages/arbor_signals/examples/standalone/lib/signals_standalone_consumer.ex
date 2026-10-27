defmodule SignalsStandaloneConsumer.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: SignalsStandaloneConsumer.Supervisor)
  end
end

defmodule SignalsStandaloneConsumer do
  @moduledoc "Independent public-API canary, executable in a release without Mix."

  alias Arbor.Signals

  def verify! do
    {:ok, _started} = Application.ensure_all_started(:signals_standalone_consumer)
    assert_independent_closure!()
    original_bus = Process.whereis(Arbor.Signals.Bus)
    true = is_pid(original_bus)
    owner = self()

    {:ok, subscription} =
      Signals.subscribe("standalone.*", fn signal ->
        send(owner, {:standalone_signal, signal})
        :ok
      end)

    :ok = Signals.emit(:standalone, :ready, %{value: 42}, async: false)

    receive do
      {:standalone_signal, %{category: :standalone, type: :ready, data: %{value: 42}}} -> :ok
    after
      2_000 -> raise "Standalone signal delivery was not observed"
    end

    {:ok, signals} = Signals.recent(category: :standalone, limit: 10)
    true = Enum.any?(signals, &(&1.type == :ready and &1.data == %{value: 42}))

    {:error, :unauthorized} =
      Signals.subscribe("security.*", fn _signal -> :ok end,
        principal_id: "standalone_principal",
        session_token: "standalone-proof"
      )

    Application.put_env(:arbor_signals, :security_module, SignalsStandaloneConsumer.Authorization)

    {:error, :unauthorized} =
      Signals.subscribe("security.*", fn _signal -> :ok end,
        principal_id: "other_principal",
        session_token: "standalone-proof"
      )

    {:ok, protected_subscription} =
      Signals.subscribe("security.*", fn _signal -> :ok end,
        principal_id: "standalone_principal",
        session_token: "standalone-proof"
      )

    :ok = Signals.unsubscribe(protected_subscription)
    Application.delete_env(:arbor_signals, :security_module)
    :ok = Signals.unsubscribe(subscription)

    :ok = Application.stop(:signals_standalone_consumer)
    :ok = Application.stop(:arbor_signals)
    nil = Process.whereis(Arbor.Signals.Supervisor)
    nil = Process.whereis(Arbor.Signals.Bus)
    false = Process.alive?(original_bus)

    {:ok, _restarted} = Application.ensure_all_started(:signals_standalone_consumer)
    restarted_bus = Process.whereis(Arbor.Signals.Bus)
    true = is_pid(restarted_bus)
    true = restarted_bus != original_bus
    assert_independent_closure!()

    IO.puts("Standalone Signals verified: delivery, history, authorization, closure and restart")
    :ok
  end

  defp assert_independent_closure! do
    loaded = for {app, _description, _version} <- Application.loaded_applications(), do: app
    started = for {app, _description, _version} <- Application.started_applications(), do: app

    compiled =
      :code.get_path()
      |> Enum.flat_map(fn path -> Path.wildcard(Path.join(List.to_string(path), "*.app")) end)
      |> Enum.map(fn path ->
        {:ok, [{:application, app, _properties}]} = :file.consult(String.to_charlist(path))
        app
      end)

    for {kind, applications} <- [loaded: loaded, started: started, compiled: compiled] do
      unexpected =
        applications
        |> Enum.filter(
          &(String.starts_with?(Atom.to_string(&1), "arbor_") and &1 != :arbor_signals)
        )
        |> Enum.uniq()

      if unexpected != [] do
        raise "Standalone consumer has unexpected #{kind} Arbor applications: #{inspect(unexpected)}"
      end
    end

    false = Code.ensure_loaded?(Arbor.Common)
    false = Code.ensure_loaded?(Arbor.Security)
    false = Code.ensure_loaded?(Arbor.Agent)
    :ok
  end
end

defmodule SignalsStandaloneConsumer.Authorization do
  @moduledoc "Exact fixture authorization; it is not a production identity provider."
  @behaviour Arbor.Signals.Contracts.Authorization

  @impl true
  def authorize("standalone_principal", "arbor://signals/subscribe/security", :subscribe,
        session_token: "standalone-proof"
      ),
      do: {:ok, :authorized}

  def authorize(_principal, _resource, _operation, _opts), do: {:error, :no_capability}
end
