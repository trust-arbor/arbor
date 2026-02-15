defmodule Arbor.Web.SignalLive do
  @moduledoc """
  Shared signal safety for LiveViews that subscribe to Arbor signals.

  Prevents the signal flood that blocks LiveView event processing
  (e.g., phx-click handlers never firing because the mailbox is full
  of `{:signal_received, _}` messages).

  Provides two subscription modes:

  ## Reload mode (most dashboards)

  Debounces rapid signals into a single reload call:

      # In mount/3:
      socket = Arbor.Web.SignalLive.subscribe(socket, "agent.*", fn socket ->
        profiles = load_profiles()
        stream(socket, :agents, profiles, reset: true)
      end)

  ## Raw mode (signal feed displays)

  Delivers signals individually with backpressure — the LiveView handles
  each `{:signal_received, signal}` in its own `handle_info`:

      # In mount/3:
      socket =
        socket
        |> Arbor.Web.SignalLive.subscribe_raw("demo.*")
        |> Arbor.Web.SignalLive.subscribe_raw("monitor.*")

  Multiple `subscribe_raw` calls can be chained — all subscription IDs
  are tracked and cleaned up by `unsubscribe/1`.

  ## Cleanup

      # In terminate/2:
      Arbor.Web.SignalLive.unsubscribe(socket)

  ## Safety guarantees

  - **Subscriber backpressure**: Signals are dropped when the LiveView
    mailbox exceeds 500 messages, preventing unbounded growth.
  - **Debounce** (reload mode): Multiple signals within 500ms
    trigger a single reload.
  - **Drain** (reload mode): If the queue is still large at reload time,
    pending signal messages are drained and reload is retried after a
    longer backoff.
  """

  @max_queue 500
  @debounce_ms 500
  @backoff_ms 1000

  @doc """
  Subscribe to signals in reload mode.

  Attaches a LiveView hook that debounces incoming signals and calls
  `reload_fn` when it's safe to reload. The function receives the
  current socket and must return the updated socket.
  """
  @spec subscribe(
          Phoenix.LiveView.Socket.t(),
          String.t(),
          (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t())
        ) ::
          Phoenix.LiveView.Socket.t()
  def subscribe(socket, pattern, reload_fn) when is_function(reload_fn, 1) do
    pid = self()
    sub_id = safe_subscribe(pattern, pid)

    socket
    |> append_sub_id(sub_id)
    |> Phoenix.Component.assign(__signal_reload_pending__: false)
    |> Phoenix.LiveView.attach_hook(:signal_safety, :handle_info, fn
      {:signal_received, _signal}, socket ->
        if socket.assigns[:__signal_reload_pending__] do
          {:halt, socket}
        else
          Process.send_after(self(), :__signal_reload_tick__, @debounce_ms)
          {:halt, Phoenix.Component.assign(socket, __signal_reload_pending__: true)}
        end

      :__signal_reload_tick__, socket ->
        case Process.info(self(), :message_queue_len) do
          {:message_queue_len, len} when len > @max_queue ->
            drain()
            Process.send_after(self(), :__signal_reload_tick__, @backoff_ms)
            {:halt, socket}

          _ ->
            socket = reload_fn.(socket)
            {:halt, Phoenix.Component.assign(socket, __signal_reload_pending__: false)}
        end

      _other, socket ->
        {:cont, socket}
    end)
  end

  @doc """
  Subscribe to signals in raw mode (append/feed displays).

  Signals are delivered as `{:signal_received, signal}` messages to the
  LiveView's `handle_info`, with backpressure at the subscriber — messages
  are dropped when the mailbox exceeds the queue limit.

  The LiveView must handle `{:signal_received, signal}` in its own
  `handle_info/2`. Can be called multiple times for different patterns.
  """
  @spec subscribe_raw(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def subscribe_raw(socket, pattern) do
    pid = self()
    sub_id = safe_subscribe(pattern, pid)
    append_sub_id(socket, sub_id)
  end

  @doc """
  Unsubscribe from all signal subscriptions. Call in `terminate/2`.
  """
  @spec unsubscribe(Phoenix.LiveView.Socket.t()) :: :ok
  def unsubscribe(socket) do
    for sub_id <- socket.assigns[:__signal_sub_ids__] || [] do
      safe_unsubscribe(sub_id)
    end

    :ok
  end

  # ── Private ────────────────────────────────────────────────────────

  defp append_sub_id(socket, nil), do: socket

  defp append_sub_id(socket, sub_id) do
    existing = socket.assigns[:__signal_sub_ids__] || []
    Phoenix.Component.assign(socket, __signal_sub_ids__: [sub_id | existing])
  end

  defp safe_subscribe(pattern, pid) do
    if signals_available?() do
      handler = fn signal ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, len} when len < @max_queue ->
            send(pid, {:signal_received, signal})

          _ ->
            :ok
        end

        :ok
      end

      case apply(Arbor.Signals, :subscribe, [pattern, handler]) do
        {:ok, id} -> id
        _ -> nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_unsubscribe(sub_id) do
    if signals_available?() do
      apply(Arbor.Signals, :unsubscribe, [sub_id])
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp signals_available? do
    Code.ensure_loaded?(Arbor.Signals) and
      function_exported?(Arbor.Signals, :subscribe, 2) and
      Process.whereis(Arbor.Signals.Bus) != nil
  end

  defp drain do
    receive do
      {:signal_received, _} -> drain()
    after
      0 -> :ok
    end
  end
end
