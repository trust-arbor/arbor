defmodule Arbor.Comms.PresenceTracker do
  @moduledoc """
  Cluster-aware presence tracking for human users across communication
  channels.

  Built on `Phoenix.Tracker` so presence is correct across nodes — a
  user connected to the dashboard on Node A and Signal on Node B
  shows up on both. Other Arbor processes (specifically the
  `InteractionRouter`) consult this to pick an active channel for
  delivering an interaction request.

  ## Topic convention

  Presence is tracked per `user_id` under the topic `"presence:user:" <> user_id`.
  The `key` is the channel kind (`:dashboard`, `:signal`, `:telegram`, ...)
  and the `metadata` is whatever the channel adapter wants to surface
  (LiveView PID, phone number, last-activity timestamp, etc.).

  ## Usage

      # Dashboard adapter, on LiveView mount:
      PresenceTracker.track(self(), user_id, :dashboard, %{liveview_pid: self()})

      # InteractionRouter, when routing:
      case PresenceTracker.active_channels(user_id) do
        [] -> queue_for_later(interaction)
        channels -> deliver_via_first(channels, interaction)
      end

  Phase 1 wires only the dashboard adapter as a presence source; the
  shape supports Signal/Telegram/Discord/voice as additive future
  sources with no `PresenceTracker` changes.
  """

  use Phoenix.Tracker

  require Logger

  @doc false
  def start_link(opts) do
    pubsub = Keyword.get(opts, :pubsub_server, default_pubsub_server())
    opts = Keyword.merge([name: __MODULE__, pubsub_server: pubsub], opts)
    Phoenix.Tracker.start_link(__MODULE__, opts, opts)
  end

  @impl true
  def init(opts) do
    server = Keyword.fetch!(opts, :pubsub_server)
    {:ok, %{pubsub_server: server, node_name: Phoenix.PubSub.node_name(server)}}
  end

  @impl true
  def handle_diff(_diff, state) do
    # Phase 1: no subscribers care about diff events. Add later if
    # dashboards want to react to presence changes in real time.
    {:ok, state}
  end

  ## Public API

  @doc """
  Track this process as a presence for `user_id` on `channel`.
  Tracking ends when the calling process terminates.
  """
  @spec track(pid(), String.t(), atom(), map()) :: {:ok, term()} | {:error, term()}
  def track(pid, user_id, channel, metadata \\ %{})
      when is_pid(pid) and is_binary(user_id) and is_atom(channel) do
    topic = topic_for(user_id)
    meta = Map.merge(metadata, %{channel: channel, joined_at: System.system_time(:millisecond)})

    case Phoenix.Tracker.track(__MODULE__, pid, topic, channel, meta) do
      {:ok, ref} -> {:ok, ref}
      {:error, _} = err -> err
    end
  rescue
    e ->
      Logger.debug("[PresenceTracker] track failed: #{Exception.message(e)}")
      {:error, :tracker_unavailable}
  end

  @doc """
  Stop tracking this presence (idempotent).
  """
  @spec untrack(pid(), String.t(), atom()) :: :ok
  def untrack(pid, user_id, channel)
      when is_pid(pid) and is_binary(user_id) and is_atom(channel) do
    Phoenix.Tracker.untrack(__MODULE__, pid, topic_for(user_id), channel)
  rescue
    _ -> :ok
  end

  @doc """
  List the channels `user_id` is currently active on. Returns a list
  of `{channel_atom, metadata_map}` tuples across all cluster nodes.
  """
  @spec active_channels(String.t()) :: [{atom(), map()}]
  def active_channels(user_id) when is_binary(user_id) do
    __MODULE__
    |> Phoenix.Tracker.list(topic_for(user_id))
    |> Enum.map(fn {key, meta} -> {key, meta} end)
  rescue
    _ -> []
  end

  @doc """
  Return the primary channel for a user. Phase 1 policy: most recent
  `joined_at` wins. Future phases layer in user preference and channel
  priority.
  """
  @spec primary_channel(String.t()) :: {:ok, atom(), map()} | :no_presence
  def primary_channel(user_id) when is_binary(user_id) do
    case active_channels(user_id) do
      [] ->
        :no_presence

      channels ->
        {channel, meta} =
          Enum.max_by(channels, fn {_ch, meta} ->
            Map.get(meta, :joined_at, 0)
          end)

        {:ok, channel, meta}
    end
  end

  ## Helpers

  defp topic_for(user_id), do: "presence:user:#{user_id}"

  # The pubsub server name varies by deployment (dashboard, web, etc.).
  # Fall back to whichever is running.
  defp default_pubsub_server do
    cond do
      Process.whereis(Arbor.Dashboard.PubSub) -> Arbor.Dashboard.PubSub
      Process.whereis(Arbor.Web.PubSub) -> Arbor.Web.PubSub
      Process.whereis(Arbor.Comms.PubSub) -> Arbor.Comms.PubSub
      true -> nil
    end
  end
end
