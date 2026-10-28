defmodule Arbor.Persistence.EventTransportProviderTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.{BufferedStore, Events}

  defmodule Bus do
    def emit(category, type, data, opts) do
      send(
        Application.fetch_env!(:arbor_persistence, :test_event_observer),
        {:emitted, category, type, data, opts}
      )

      :ok
    end

    def subscribe(topic, callback) do
      Agent.update(__MODULE__, &[{topic, callback} | &1])
      {:ok, make_ref()}
    end
  end

  setup do
    previous =
      for key <- [:event_bus, :test_event_observer],
          do: {key, Application.fetch_env(:arbor_persistence, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:arbor_persistence, key, value)
          :error -> Application.delete_env(:arbor_persistence, key)
        end
      end
    end)

    :ok
  end

  test "absent event transport remains optional" do
    Application.put_env(:arbor_persistence, :event_bus, nil)
    refute Events.available?()
    assert :ok = Events.emit(:persistence, :cache_put, %{})
    assert {:error, :unavailable} = Events.subscribe("persistence.cache_put", fn _ -> :ok end)
  end

  test "selected transport forwards actual invalidation callbacks and cluster options" do
    Application.put_env(:arbor_persistence, :event_bus, Bus)
    Application.put_env(:arbor_persistence, :test_event_observer, self())
    start_supervised!(%{id: Bus, start: {Agent, :start_link, [fn -> [] end, [name: Bus]]}})

    # Bounded test-owned name; not an external identifier.
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    name = :"event_transport_store_#{System.unique_integer([:positive])}"
    start_supervised!({BufferedStore, name: name, distributed: true})
    callbacks = Agent.get(Bus, & &1)

    assert Enum.sort(Enum.map(callbacks, &elem(&1, 0))) ==
             ["persistence.cache_delete", "persistence.cache_put"]

    assert :ok = BufferedStore.put("key", "local", name: name)
    assert_receive {:emitted, :persistence, :cache_put, data, [scope: :cluster]}
    assert data == %{collection: Atom.to_string(name), key: "key", origin_node: node()}

    {_topic, callback} = Enum.find(callbacks, &(elem(&1, 0) == "persistence.cache_put"))

    callback.(%{
      type: :cache_put,
      data: %{collection: Atom.to_string(name), key: "key", origin_node: :remote_test_node}
    })

    assert {:error, :not_found} = BufferedStore.authoritative_get("key", name: name)
  end
end
