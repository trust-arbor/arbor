defmodule Arbor.Comms.Channels.Signal.PresenceKeeper do
  @moduledoc """
  Keeps a Signal-channel presence entry alive for the configured
  operator so `Arbor.Comms.PresenceTracker.primary_channel/1` can
  route to `:signal` when no other channel is more recently active.

  ## Why a dedicated process

  `PresenceTracker` is built on `Phoenix.Tracker`, which keys entries
  by `{topic, pid}`. When the pid exits, the entry is removed. For
  presence sources that ARE pids (e.g., a dashboard LiveView),
  presence dies naturally when the user closes the tab. Signal has no
  such pid — the operator's phone is "always there" as long as
  signal-cli is configured. This GenServer's PID stands in for
  "Signal presence active for this user" — it lives for the lifetime
  of the supervisor, so the tracker entry persists too.

  ## Joined_at semantics

  `PresenceTracker.primary_channel/1` uses `joined_at` to pick
  most-recently-active when multiple channels are present. We set
  `joined_at: 0` (deliberately low) so any real-time channel
  (dashboard mount, etc.) wins by recency. Signal is the fallback
  when nothing more interactive is available.

  ## Configuration

      config :arbor_comms, :signal,
        enabled: true,
        interaction_user_id: "hysun",
        interaction_recipient: "+1..."

  All three must be present for the keeper to register. If any is
  missing, the GenServer still starts (so it can be supervised
  cleanly) but does nothing.
  """

  use GenServer

  require Logger

  alias Arbor.Comms.PresenceTracker

  # Deliberately low: any real-time channel's joined_at is in
  # milliseconds-since-epoch and wins by recency.
  @signal_joined_at 0

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = Application.get_env(:arbor_comms, :signal, [])
    enabled = Keyword.get(config, :enabled, false)
    user_id = Keyword.get(config, :interaction_user_id)
    phone = Keyword.get(config, :interaction_recipient)

    if enabled and is_binary(user_id) and user_id != "" and is_binary(phone) and phone != "" do
      register_presence(user_id, phone)
    else
      Logger.debug(
        "[Signal.PresenceKeeper] not registering — incomplete config (enabled=#{enabled}, user_id=#{inspect(user_id)})"
      )
    end

    {:ok, %{user_id: user_id, phone: phone, enabled: enabled}}
  end

  defp register_presence(user_id, phone) do
    meta = %{
      phone: phone,
      joined_at: @signal_joined_at,
      always_present: true
    }

    case PresenceTracker.track(self(), user_id, :signal, meta) do
      {:ok, _ref} ->
        Logger.info("[Signal.PresenceKeeper] registered :signal presence for user #{user_id}")
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Signal.PresenceKeeper] failed to register presence for #{user_id}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "[Signal.PresenceKeeper] exception registering presence: #{Exception.message(e)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning("[Signal.PresenceKeeper] exit registering presence: #{inspect(reason)}")
      :ok
  end
end
