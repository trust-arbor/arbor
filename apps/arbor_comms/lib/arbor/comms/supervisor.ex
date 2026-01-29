defmodule Arbor.Comms.Supervisor do
  @moduledoc """
  Supervises comms channel workers, polling processes, and message handler.
  """

  use Supervisor

  alias Arbor.Comms.Channels.Limitless
  alias Arbor.Comms.Channels.Signal
  alias Arbor.Comms.Config
  alias Arbor.Comms.MessageHandler

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = build_children()
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp build_children do
    []
    |> maybe_add_handler()
    |> maybe_add_signal()
    |> maybe_add_limitless()
  end

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
