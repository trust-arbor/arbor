defmodule Arbor.Dashboard.InteractionAdapter do
  @moduledoc """
  Dashboard channel adapter for `Arbor.Comms.InteractionRouter`.

  Broadcasts interaction requests on the per-user dashboard-interaction
  PubSub channel. The retired ChatLive was the only subscriber; since its
  removal (2026-10-08) no LiveView subscribes. The routed ConversationLive
  reads prompts and submits answers through `Arbor.Agent`'s authenticated
  conversation facade instead.

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
  Dashboard PubSub topic for incoming interactions targeted at this user.
  """
  @spec topic_for_user(String.t()) :: String.t()
  def topic_for_user(user_id) when is_binary(user_id) do
    "dashboard:interactions:" <> user_id
  end

  # HITL traffic is pinned to Arbor.Comms.PubSub (owned by Arbor.Comms.Application)
  # so the adapter, the InteractionRouter, the PresenceTracker, and any dashboard
  # subscriber share one bus regardless of which app starts first.
  defp pubsub_server, do: Arbor.Comms.PubSub
end
