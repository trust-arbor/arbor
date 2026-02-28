defmodule Arbor.Comms.Supervisor do
  @moduledoc """
  Supervises comms channel workers, polling processes, and message handler.
  """

  use Supervisor

  alias Arbor.Comms.Channels.Limitless
  alias Arbor.Comms.Channels.Signal
  alias Arbor.Comms.Config
  alias Arbor.Comms.MessageHandler

  require Logger

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = build_children()
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp build_children do
    # Channel infrastructure starts first (Registry → DynamicSupervisor → restore)
    [
      {Registry, keys: :unique, name: Arbor.Comms.ChannelRegistry},
      {DynamicSupervisor, name: Arbor.Comms.ChannelSupervisor, strategy: :one_for_one}
    ]
    |> maybe_add_channel_restore()
    |> maybe_add_handler()
    |> maybe_add_signal()
    |> maybe_add_limitless()
  end

  defp maybe_add_channel_restore(children) do
    children ++ [{Task, fn -> restore_channels() end}]
  end

  defp restore_channels do
    if Code.ensure_loaded?(Arbor.Persistence.ChannelStore) and
         apply(Arbor.Persistence.ChannelStore, :available?, []) do
      channels = apply(Arbor.Persistence.ChannelStore, :list_channels, [[]])

      Enum.each(channels, fn channel ->
        opts = [
          channel_id: channel.channel_id,
          name: channel.name,
          type: safe_channel_type(channel.type),
          owner_id: channel.owner_id,
          members: channel.members || []
        ]

        case DynamicSupervisor.start_child(
               Arbor.Comms.ChannelSupervisor,
               {Arbor.Comms.Channel, opts}
             ) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, reason} ->
            Logger.warning("Failed to restore channel #{channel.channel_id}: #{inspect(reason)}")
        end
      end)
    end
  rescue
    e -> Logger.warning("Channel restore failed: #{inspect(e)}")
  catch
    :exit, reason -> Logger.warning("Channel restore exit: #{inspect(reason)}")
  end

  defp safe_channel_type("dm"), do: :dm
  defp safe_channel_type("group"), do: :group
  defp safe_channel_type("public"), do: :public
  defp safe_channel_type("ops_room"), do: :ops_room
  defp safe_channel_type("private"), do: :private
  defp safe_channel_type(_), do: :group

  # Start handler before pollers so it's ready to receive messages
  defp maybe_add_handler(children) do
    if Config.handler_enabled?() do
      children ++ [{MessageHandler, []}]
    else
      children
    end
  end

  defp maybe_add_signal(children) do
    if Config.channel_enabled?(:signal) do
      children ++ [{Signal.Poller, []}]
    else
      children
    end
  end

  defp maybe_add_limitless(children) do
    if Config.channel_enabled?(:limitless) do
      children ++ [{Limitless.Poller, []}]
    else
      children
    end
  end
end
