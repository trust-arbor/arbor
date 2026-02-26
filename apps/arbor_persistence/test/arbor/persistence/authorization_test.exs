defmodule Arbor.Persistence.AuthorizationTest do
  @moduledoc """
  Tests for authorization rejection paths in Arbor.Persistence.

  These tests verify that the authorize_write/6, authorize_read/5,
  authorize_append/6, and authorize_read_stream/5 functions correctly
  reject unauthorized agents and wrap rejection reasons properly.

  An agent with no granted capabilities should always be rejected by
  the Security system, producing {:error, {:unauthorized, reason}}.
  """

  use ExUnit.Case, async: false

  alias Arbor.Persistence
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.Store

  # Use a unique agent ID that has NO capabilities granted.
  # This ensures the Security system denies all operations.
  @unauthorized_agent "agent_unauthorized_#{:erlang.unique_integer([:positive])}"

  setup do
    # Security infrastructure needed for authorization checks
    ensure_started(Arbor.Security.Identity.Registry)
    ensure_started(Arbor.Security.SystemAuthority)
    ensure_started(Arbor.Security.CapabilityStore)

    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    store_name = :"auth_test_store_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Store.ETS, name: store_name})

    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    el_name = :"auth_test_el_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Arbor.Persistence.EventLog.ETS, name: el_name})

    {:ok, store: store_name, el: el_name}
  end

  defp ensure_started(module, opts \\ []) do
    if Process.whereis(module) do
      :already_running
    else
      start_supervised!({module, opts})
    end
  end

  describe "authorize_write/6 rejection" do
    @tag :fast
    test "rejects unauthorized agent with {:error, {:unauthorized, _}}", %{store: store} do
      result =
        Persistence.authorize_write(
          @unauthorized_agent,
          store,
          Store.ETS,
          "test_key",
          "test_value"
        )

      assert {:error, {:unauthorized, reason}} = result
      assert reason != nil
    end

    @tag :fast
    test "does not write data when unauthorized", %{store: store} do
      Persistence.authorize_write(
        @unauthorized_agent,
        store,
        Store.ETS,
        "secret_key",
        "secret_value"
      )

      # Verify the data was NOT stored (direct read, bypassing auth)
      assert {:error, :not_found} = Persistence.get(store, Store.ETS, "secret_key")
    end

    @tag :fast
    test "includes trace_id in authorization check", %{store: store} do
      result =
        Persistence.authorize_write(
          @unauthorized_agent,
          store,
          Store.ETS,
          "key",
          "value",
          trace_id: "trace-123"
        )

      assert {:error, {:unauthorized, _reason}} = result
    end
  end

  describe "authorize_read/5 rejection" do
    @tag :fast
    test "rejects unauthorized agent with {:error, {:unauthorized, _}}", %{store: store} do
      # First, store a value directly (bypassing auth)
      :ok = Persistence.put(store, Store.ETS, "readable_key", "readable_value")

      result =
        Persistence.authorize_read(
          @unauthorized_agent,
          store,
          Store.ETS,
          "readable_key"
        )

      assert {:error, {:unauthorized, reason}} = result
      assert reason != nil
    end

    @tag :fast
    test "does not return data when unauthorized", %{store: store} do
      :ok = Persistence.put(store, Store.ETS, "data_key", "sensitive_data")

      result =
        Persistence.authorize_read(
          @unauthorized_agent,
          store,
          Store.ETS,
          "data_key"
        )

      # Should NOT return the data
      refute match?({:ok, "sensitive_data"}, result)
      assert {:error, {:unauthorized, _}} = result
    end

    @tag :fast
    test "includes trace_id in authorization check", %{store: store} do
      result =
        Persistence.authorize_read(
          @unauthorized_agent,
          store,
          Store.ETS,
          "key",
          trace_id: "trace-456"
        )

      assert {:error, {:unauthorized, _reason}} = result
    end
  end

  describe "authorize_append/6 rejection" do
    @tag :fast
    test "rejects unauthorized agent with {:error, {:unauthorized, _}}", %{el: el} do
      event = Event.new("stream_1", "test_event", %{data: "payload"})

      result =
        Persistence.authorize_append(
          @unauthorized_agent,
          el,
          Arbor.Persistence.EventLog.ETS,
          "stream_1",
          event
        )

      assert {:error, {:unauthorized, reason}} = result
      assert reason != nil
    end

    @tag :fast
    test "does not append events when unauthorized", %{el: el} do
      event = Event.new("stream_2", "test_event", %{data: "payload"})

      Persistence.authorize_append(
        @unauthorized_agent,
        el,
        Arbor.Persistence.EventLog.ETS,
        "stream_2",
        event
      )

      # Verify the event was NOT appended (direct read, bypassing auth)
      refute Persistence.stream_exists?(el, Arbor.Persistence.EventLog.ETS, "stream_2")
    end

    @tag :fast
    test "rejects batch append of multiple events", %{el: el} do
      events = [
        Event.new("stream_3", "event_a", %{order: 1}),
        Event.new("stream_3", "event_b", %{order: 2})
      ]

      result =
        Persistence.authorize_append(
          @unauthorized_agent,
          el,
          Arbor.Persistence.EventLog.ETS,
          "stream_3",
          events
        )

      assert {:error, {:unauthorized, _}} = result
    end

    @tag :fast
    test "includes trace_id in authorization check", %{el: el} do
      event = Event.new("stream_4", "test_event", %{})

      result =
        Persistence.authorize_append(
          @unauthorized_agent,
          el,
          Arbor.Persistence.EventLog.ETS,
          "stream_4",
          event,
          trace_id: "trace-789"
        )

      assert {:error, {:unauthorized, _reason}} = result
    end
  end

  describe "authorize_read_stream/5 rejection" do
    @tag :fast
    test "rejects unauthorized agent with {:error, {:unauthorized, _}}", %{el: el} do
      # First, append an event directly (bypassing auth)
      event = Event.new("readable_stream", "test_event", %{data: "payload"})
      {:ok, _} = Persistence.append(el, Arbor.Persistence.EventLog.ETS, "readable_stream", event)

      result =
        Persistence.authorize_read_stream(
          @unauthorized_agent,
          el,
          Arbor.Persistence.EventLog.ETS,
          "readable_stream"
        )

      assert {:error, {:unauthorized, reason}} = result
      assert reason != nil
    end

    @tag :fast
    test "does not return events when unauthorized", %{el: el} do
      event = Event.new("secret_stream", "test_event", %{secret: "classified"})
      {:ok, _} = Persistence.append(el, Arbor.Persistence.EventLog.ETS, "secret_stream", event)

      result =
        Persistence.authorize_read_stream(
          @unauthorized_agent,
          el,
          Arbor.Persistence.EventLog.ETS,
          "secret_stream"
        )

      # Should NOT return the events
      refute match?({:ok, _events}, result)
      assert {:error, {:unauthorized, _}} = result
    end

    @tag :fast
    test "includes trace_id in authorization check", %{el: el} do
      result =
        Persistence.authorize_read_stream(
          @unauthorized_agent,
          el,
          Arbor.Persistence.EventLog.ETS,
          "some_stream",
          trace_id: "trace-abc"
        )

      assert {:error, {:unauthorized, _reason}} = result
    end
  end

  describe "authorization error wrapping consistency" do
    @tag :fast
    test "all authorize functions wrap errors consistently", %{store: store, el: el} do
      event = Event.new("s1", "t", %{})

      results = [
        Persistence.authorize_write(@unauthorized_agent, store, Store.ETS, "k", "v"),
        Persistence.authorize_read(@unauthorized_agent, store, Store.ETS, "k"),
        Persistence.authorize_append(
          @unauthorized_agent,
          el,
          Arbor.Persistence.EventLog.ETS,
          "s1",
          event
        ),
        Persistence.authorize_read_stream(
          @unauthorized_agent,
          el,
          Arbor.Persistence.EventLog.ETS,
          "s1"
        )
      ]

      for result <- results do
        assert {:error, {:unauthorized, _reason}} = result,
               "Expected {:error, {:unauthorized, _}} but got #{inspect(result)}"
      end
    end

    @tag :fast
    test "unauthorized error reasons are not nil", %{store: store} do
      {:error, {:unauthorized, reason}} =
        Persistence.authorize_write(@unauthorized_agent, store, Store.ETS, "k", "v")

      assert reason != nil
    end
  end
end
