defmodule Arbor.Persistence.Ecto.EventLogIntegrationTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.Ecto.EventLog
  alias Arbor.Persistence.Ecto.EventStore, as: Store
  alias Arbor.Persistence.Event

  @moduletag :database
  @moduletag :integration

  defmodule OrdinaryEvent do
    @moduledoc false
    defstruct [:value]
  end

  setup_all do
    previous_config = Application.get_env(:arbor_persistence_ecto, Store)
    Application.put_env(:arbor_persistence_ecto, Store, event_store_config())

    on_exit(fn ->
      if previous_config do
        Application.put_env(:arbor_persistence_ecto, Store, previous_config)
      else
        Application.delete_env(:arbor_persistence_ecto, Store)
      end
    end)

    start_supervised!(Store)
    :ok
  end

  test "ordinary append uses EventStore's no-precondition sentinel" do
    stream_id = "ordinary-append-#{System.unique_integer([:positive])}"
    event_type = Atom.to_string(OrdinaryEvent)
    event = Event.new(stream_id, event_type, %{value: 1})

    assert {:ok, [%Event{} = persisted]} = EventLog.append(stream_id, event)
    assert persisted.stream_id == stream_id
    assert persisted.event_number == 1

    assert {:ok,
            [
              %Event{
                id: id,
                type: ^event_type,
                data: %OrdinaryEvent{value: 1},
                event_number: 1
              }
            ]} =
             EventLog.read_stream(stream_id)

    assert id == event.id
  end

  defp event_store_config do
    [
      serializer: EventStore.JsonSerializer,
      username: System.get_env("POSTGRES_USER", "arbor_dev"),
      password: System.get_env("POSTGRES_PASSWORD", ""),
      database: System.get_env("POSTGRES_DB", "trust_arbor_test"),
      hostname: System.get_env("POSTGRES_HOST", "localhost"),
      port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
      pool_size: 2
    ]
  end
end
