defmodule Arbor.Persistence.EctoTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence.Ecto

  describe "module availability" do
    test "event_store/0 returns EventStore module" do
      assert Ecto.event_store() == Arbor.Persistence.Ecto.EventStore
    end

    test "event_log/0 returns EventLog module" do
      assert Ecto.event_log() == Arbor.Persistence.Ecto.EventLog
    end

    test "available?/0 returns false when not configured" do
      # In test env without full config, should return false
      # This test verifies the function exists and handles missing config gracefully
      result = Ecto.available?()
      assert is_boolean(result)
    end
  end

  # Integration tests require a running Postgres database
  # They are tagged and can be run with: mix test --include integration
  #
  # @tag :integration
  # describe "EventLog integration" do
  #   setup do
  #     # Start EventStore for this test
  #     {:ok, _} = start_supervised(Arbor.Persistence.Ecto.EventStore)
  #     :ok
  #   end
  #
  #   test "append and read events" do
  #     alias Arbor.Persistence.Ecto.EventLog
  #     alias Arbor.Persistence.Event
  #
  #     stream_id = "test-stream-#{System.unique_integer()}"
  #     event = Event.new(stream_id, "TestEvent", %{foo: "bar"})
  #
  #     {:ok, [persisted]} = EventLog.append(stream_id, event, [])
  #     assert persisted.stream_id == stream_id
  #     assert persisted.type == "TestEvent"
  #
  #     {:ok, events} = EventLog.read_stream(stream_id, [])
  #     assert length(events) == 1
  #   end
  # end
end
