defmodule Arbor.Web.SignalLiveTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Web.SignalLive

  # Build a minimal socket-like struct for testing.
  # SignalLive only reads/writes socket.assigns via Phoenix.Component.assign,
  # so we build a real %Phoenix.LiveView.Socket{} with empty assigns.
  defp build_socket(extra_assigns \\ %{}) do
    assigns =
      extra_assigns
      |> Map.put_new(:__changed__, %{})
      |> Map.put_new(:flash, %{})

    %Phoenix.LiveView.Socket{
      assigns: assigns,
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }
  end

  describe "unsubscribe/1" do
    test "returns :ok when socket has no signal sub IDs" do
      socket = build_socket()
      assert SignalLive.unsubscribe(socket) == :ok
    end

    test "returns :ok when __signal_sub_ids__ is nil" do
      socket = build_socket(%{__signal_sub_ids__: nil})
      assert SignalLive.unsubscribe(socket) == :ok
    end

    test "returns :ok when __signal_sub_ids__ is empty list" do
      socket = build_socket(%{__signal_sub_ids__: []})
      assert SignalLive.unsubscribe(socket) == :ok
    end

    test "returns :ok when __signal_sub_ids__ has entries but Signals unavailable" do
      # With Arbor.Signals.Bus not running, safe_unsubscribe will gracefully handle it
      socket = build_socket(%{__signal_sub_ids__: ["sub-1", "sub-2"]})
      assert SignalLive.unsubscribe(socket) == :ok
    end
  end

  describe "subscribe_raw/2" do
    test "returns socket with nil sub_id appended when Signals unavailable" do
      # When Arbor.Signals.Bus is not running, safe_subscribe returns nil
      # and append_sub_id(socket, nil) returns the socket unchanged
      socket = build_socket()
      result = SignalLive.subscribe_raw(socket, "test.*")

      # Socket is returned (no crash), sub_ids not set since sub_id was nil
      assert %Phoenix.LiveView.Socket{} = result
    end

    test "preserves existing assigns" do
      socket = build_socket(%{my_data: "hello"})
      result = SignalLive.subscribe_raw(socket, "test.*")

      assert result.assigns[:my_data] == "hello"
    end
  end

  describe "subscribe/3" do
    test "returns socket with reload hook attached when Signals unavailable" do
      socket = build_socket()

      reload_fn = fn sock -> sock end
      result = SignalLive.subscribe(socket, "test.*", reload_fn)

      # Should have the __signal_reload_pending__ assign set to false
      assert result.assigns[:__signal_reload_pending__] == false
    end

    test "attaches :signal_safety hook to lifecycle" do
      socket = build_socket()

      reload_fn = fn sock -> sock end
      result = SignalLive.subscribe(socket, "test.*", reload_fn)

      # The hook should be in the lifecycle as a map with :id field
      hooks = result.private.lifecycle.handle_info
      hook_ids = Enum.map(hooks, fn hook -> hook.id end)
      assert :signal_safety in hook_ids
    end

    test "sets __signal_reload_pending__ to false initially" do
      socket = build_socket()

      reload_fn = fn sock -> sock end
      result = SignalLive.subscribe(socket, "agent.*", reload_fn)

      assert result.assigns[:__signal_reload_pending__] == false
    end

    test "raises for non-function reload_fn" do
      socket = build_socket()

      assert_raise FunctionClauseError, fn ->
        SignalLive.subscribe(socket, "test.*", :not_a_function)
      end
    end

    test "raises for function with wrong arity" do
      socket = build_socket()

      assert_raise FunctionClauseError, fn ->
        SignalLive.subscribe(socket, "test.*", fn -> :ok end)
      end
    end
  end
end
