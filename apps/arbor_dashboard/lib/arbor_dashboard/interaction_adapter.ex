defmodule Arbor.Dashboard.InteractionAdapter do
  @moduledoc """
  Dashboard channel adapter for `Arbor.Comms.InteractionRouter`.

  Delivers interaction requests to LiveView via PubSub. Each ChatLive
  process subscribes (at mount time) to the dashboard-interaction
  channel for its user; when the router dispatches an interaction here,
  this adapter broadcasts to that channel and the LiveView renders an
  approval banner. The LiveView's approve/reject events call back to
  `Arbor.Comms.InteractionRouter.respond/3` directly.

  Phase 1 scope. Multi-node correct because the broadcast uses the
  cluster-aware PubSub server; whichever node hosts the user's LiveView
  receives the message.
  """

  @behaviour Arbor.Contracts.Comms.ChannelAdapter

  require Logger

  alias Arbor.Contracts.Comms.Interaction

  @impl true
  def channel_kind, do: :dashboard

  @impl true
  @doc """
  The router calls this with the channel meta from `PresenceTracker`.
  We pull the user_id from the interaction (the topic is per-user, not
  per-LiveView-pid, so a user with multiple browser tabs sees the
  banner in all of them).
  """
  def send_interaction(_channel_meta, %Interaction{} = interaction) do
    topic = topic_for_user(interaction.user_id)
    pubsub = pubsub_server()

    try do
      Phoenix.PubSub.broadcast(
        pubsub,
        topic,
        {:dashboard_interaction, interaction}
      )

      :ok
    rescue
      e -> {:error, {:broadcast_failed, Exception.message(e)}}
    catch
      :exit, reason -> {:error, {:broadcast_exit, reason}}
    end
  end

  @impl true
  @doc """
  The dashboard adapter doesn't parse incoming chat messages — responses
  come from LiveView click events, not from raw text. Always returns
  `:not_interaction`.
  """
  def parse_response(_raw), do: :not_interaction

  @doc """
  Topic the dashboard ChatLive subscribes to for incoming interactions
  targeted at this user.
  """
  @spec topic_for_user(String.t()) :: String.t()
  def topic_for_user(user_id) when is_binary(user_id) do
    "dashboard:interactions:" <> user_id
  end

  # HITL traffic is pinned to Arbor.Comms.PubSub (owned by Arbor.Comms.Application)
  # so the adapter, the InteractionRouter, the PresenceTracker, and ChatLive all
  # broadcast and subscribe on the same bus regardless of which app starts first.
  defp pubsub_server, do: Arbor.Comms.PubSub
end
