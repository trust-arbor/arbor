defmodule Arbor.Persistence.EventLogProjectionPublicBoundaryTest do
  @moduledoc """
  The projection primitive as consumers reach it: through `Arbor.Persistence`,
  never by calling backend internals.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Persistence
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog
  alias Arbor.Persistence.EventLog.ETS
  alias Arbor.Persistence.Store.ETS, as: StoreETS

  @timestamp ~U[2026-08-21 00:00:00.000000Z]

  setup do
    {:ok, name: start_projection()}
  end

  describe "supports_projection?/1" do
    test "is true only for a backend exporting project_committed_events/2" do
      assert Persistence.supports_projection?(ETS)
      refute Persistence.supports_projection?(StoreETS)
      refute Persistence.supports_projection?(:not_a_module)
      refute Persistence.supports_projection?(nil)
      refute Persistence.supports_projection?("Elixir.Nope")
    end
  end

  describe "project_committed_events/4" do
    test "projects already-committed events at their exact positions", %{name: name} do
      events = [
        event(id: "evt_a", stream_id: "alpha", event_number: 4, global_position: 88),
        event(id: "evt_b", stream_id: "alpha", event_number: 5, global_position: 91)
      ]

      assert {:ok, %{projected: 2, skipped: 0}} =
               Persistence.project_committed_events(name, ETS, events)

      assert {:ok, [first, second]} = Persistence.read_stream(name, ETS, "alpha")
      assert {first.event_number, first.global_position} == {4, 88}
      assert {second.event_number, second.global_position} == {5, 91}

      assert {:ok, %{projected: 0, skipped: 2}} =
               Persistence.project_committed_events(name, ETS, events)
    end

    test "surfaces the per-surface conflict vocabulary", %{name: name} do
      assert {:ok, _} =
               Persistence.project_committed_events(name, ETS, [
                 event(id: "evt_a", event_number: 1, global_position: 1)
               ])

      assert {:error, :global_position_conflict} =
               Persistence.project_committed_events(name, ETS, [
                 event(id: "evt_b", event_number: 2, global_position: 1)
               ])

      assert {:error, :stream_position_conflict} =
               Persistence.project_committed_events(name, ETS, [
                 event(id: "evt_c", event_number: 1, global_position: 2)
               ])

      assert {:error, :event_id_conflict} =
               Persistence.project_committed_events(name, ETS, [
                 event(id: "evt_a", event_number: 1, global_position: 1, data: %{"v" => 2})
               ])
    end

    test "rejects a backend that does not implement projection", %{name: name} do
      assert {:error, :projection_not_supported} =
               Persistence.project_committed_events(name, StoreETS, [
                 event(id: "evt_a", event_number: 1, global_position: 1)
               ])

      assert {:error, :projection_not_supported} =
               Persistence.project_committed_events(name, NotALoadedModule, [])
    end

    test "rejects an invalid store name and invalid options", %{name: name} do
      events = [event(id: "evt_a", event_number: 1, global_position: 1)]

      assert {:error, :invalid_precondition} =
               Persistence.project_committed_events("not_an_atom", ETS, events)

      assert {:error, :invalid_precondition} =
               Persistence.project_committed_events(name, ETS, events, %{not: :a_keyword_list})
    end

    test "refuses an authoritative backend without touching it" do
      authoritative = unique_name("el_auth")
      start_supervised!({ETS, name: authoritative}, id: authoritative)

      assert {:error, :projection_mode_required} =
               Persistence.project_committed_events(authoritative, ETS, [
                 event(id: "evt_a", event_number: 1, global_position: 1)
               ])

      assert {:ok, 0} = Persistence.event_count(authoritative, ETS)
      assert {:ok, []} = Persistence.list_streams(authoritative, ETS)
    end
  end

  describe "the verbose contract callback" do
    test "delegates to the same boundary", %{name: name} do
      events = [event(id: "evt_a", event_number: 1, global_position: 1)]

      assert {:ok, %{projected: 1, skipped: 0}} =
               Persistence.project_already_committed_events_into_backend(name, ETS, events, [])

      assert {:ok, %{projected: 0, skipped: 1}} =
               Persistence.project_already_committed_events_into_backend(name, ETS, events, [])
    end
  end

  test "reads through the facade describe resident rows only", %{name: name} do
    assert {:ok, _} =
             Persistence.project_committed_events(name, ETS, [
               event(id: "evt_a", stream_id: "alpha", event_number: 2, global_position: 700)
             ])

    assert {:ok, 1} = Persistence.event_count(name, ETS)
    assert {:ok, 1} = Persistence.stream_count(name, ETS)
    assert {:ok, ["alpha"]} = Persistence.list_streams(name, ETS)
    assert Persistence.stream_exists?(name, ETS, "alpha")
    assert {:error, :head_unavailable} = Persistence.read_stream_head(name, ETS, "alpha")
  end

  test "the facade refuses to assert absence on a projection", %{name: name} do
    assert {:error, :absence_not_supported} =
             Persistence.event_stream_absent?(name, ETS, "alpha")
  end

  # --- helpers ---

  defp start_projection do
    name = unique_name("el_projection_boundary")
    start_supervised!({ETS, name: name, mode: :projection}, id: name)
    name
  end

  defp unique_name(prefix) do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    :"#{prefix}_#{:erlang.unique_integer([:positive])}"
  end

  defp event(opts) do
    stream_id = Keyword.get(opts, :stream_id, "stream")

    event = %Event{
      id: Keyword.fetch!(opts, :id),
      stream_id: stream_id,
      event_number: Keyword.fetch!(opts, :event_number),
      global_position: Keyword.fetch!(opts, :global_position),
      type: "projected",
      data: Keyword.get(opts, :data, %{"value" => "v"}),
      metadata: %{},
      timestamp: @timestamp
    }

    %Event{event | operation_fingerprint: EventLog.event_fingerprint(stream_id, event)}
  end
end
