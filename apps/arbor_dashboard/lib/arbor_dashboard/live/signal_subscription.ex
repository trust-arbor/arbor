defmodule Arbor.Dashboard.Live.SignalSubscription do
  @moduledoc """
  Eliminates signal subscription boilerplate in LiveViews.

  Provides two things:

  1. `subscribe_signals/3` — wraps the `connected?` guard around
     `Arbor.Web.SignalLive.subscribe/3` so mount functions don't repeat it.

  2. `use Arbor.Dashboard.Live.SignalSubscription` — injects a default
     `terminate/2` that calls `Arbor.Web.SignalLive.unsubscribe/1` and a
     catch-all `handle_info/2` that returns `{:noreply, socket}`.

  ## Usage — reload mode (most dashboards)

      use Arbor.Dashboard.Live.SignalSubscription

      def mount(_params, _session, socket) do
        socket =
          socket
          |> assign(...)
          |> subscribe_signals("agent.*", &reload_agents/1)

        {:ok, socket}
      end

  The `use` adds `terminate/2` and a catch-all `handle_info/2` so you
  don't have to define them. If you need custom terminate or handle_info
  logic, define your own — Elixir's pattern matching and `defoverridable`
  let your definitions take precedence.

  ## Usage — raw mode (signal feeds)

  For LiveViews that handle `{:signal_received, signal}` directly, call
  `Arbor.Web.SignalLive.subscribe_raw/2` as before and only `use` this
  module for the terminate cleanup:

      use Arbor.Dashboard.Live.SignalSubscription

      def mount(_params, _session, socket) do
        socket =
          if connected?(socket) do
            Arbor.Web.SignalLive.subscribe_raw(socket, "demo.*")
          else
            socket
          end

        {:ok, socket}
      end

      # Your own handle_info for raw signals:
      def handle_info({:signal_received, signal}, socket) do
        ...
      end

  The catch-all `handle_info(_msg, socket)` from this module handles
  any messages not matched by your clauses.
  """

  @doc """
  Subscribe to signals in reload mode, guarded by `connected?/1`.

  Returns the socket unchanged during static render (not connected),
  and subscribes to debounced signal reloads when connected.

  Must be called from within a LiveView `mount/3` callback.
  """
  @spec subscribe_signals(
          Phoenix.LiveView.Socket.t(),
          String.t(),
          (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t())
        ) :: Phoenix.LiveView.Socket.t()
  def subscribe_signals(socket, pattern, reload_fn) do
    if Phoenix.LiveView.connected?(socket) do
      Arbor.Web.SignalLive.subscribe(socket, pattern, reload_fn)
    else
      socket
    end
  end

  defmacro __using__(_opts) do
    quote do
      import Arbor.Dashboard.Live.SignalSubscription, only: [subscribe_signals: 3]

      @before_compile Arbor.Dashboard.Live.SignalSubscription
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    # Only inject terminate/2 if the module hasn't defined one
    has_terminate? =
      Module.defines?(env.module, {:terminate, 2})

    has_catch_all_handle_info? =
      Module.defines?(env.module, {:handle_info, 2})

    terminate_ast =
      unless has_terminate? do
        quote do
          @impl true
          def terminate(_reason, socket) do
            Arbor.Web.SignalLive.unsubscribe(socket)
          end
        end
      end

    handle_info_ast =
      unless has_catch_all_handle_info? do
        quote do
          @impl true
          def handle_info(_msg, socket), do: {:noreply, socket}
        end
      end

    quote do
      unquote(terminate_ast)
      unquote(handle_info_ast)
    end
  end
end
