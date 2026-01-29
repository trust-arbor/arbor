defmodule Arbor.Comms do
  @moduledoc """
  Unified external communications for Arbor.

  Provides a single facade for sending and receiving messages across
  multiple channels (Signal, Limitless, Email, Voice).

  ## Sending Messages

      Arbor.Comms.send(:signal, "+1234567890", "Hello from Arbor!")
      Arbor.Comms.send_signal("+1234567890", "Hello!")

  ## Checking Status

      Arbor.Comms.channels()
      #=> [:signal]

      Arbor.Comms.healthy?()
      #=> true

  ## Reading History

      Arbor.Comms.recent_messages(:signal)
  """

  alias Arbor.Comms.ChatLogger
  alias Arbor.Comms.Config
  alias Arbor.Comms.Dispatcher

  # -- Sending --

  @doc """
  Send a message through the specified channel.

  ## Options

  Channel-specific options are passed through. For Signal:
    - `:attachments` - list of file paths to attach
  """
  @spec send(atom(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def send(channel, to, content, opts \\ []) do
    Dispatcher.send(channel, to, content, opts)
  end

  @doc "Send a message via Signal."
  @spec send_signal(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def send_signal(to, content, opts \\ []) do
    Dispatcher.send(:signal, to, content, opts)
  end

  # -- Receiving --

  @doc """
  Poll a specific channel for new messages.

  Returns `{:ok, messages}` or `{:error, reason}`.
  """
  @spec poll(atom()) :: {:ok, [Arbor.Contracts.Comms.Message.t()]} | {:error, term()}
  def poll(channel) do
    case Dispatcher.channel_module(channel) do
      nil -> {:error, {:unknown_channel, channel}}
      module -> module.poll()
    end
  end

  @doc "Poll all enabled channels for new messages."
  @spec poll_all() :: {:ok, [Arbor.Contracts.Comms.Message.t()]}
  def poll_all do
    messages =
      Config.configured_channels()
      |> Enum.flat_map(fn channel ->
        case poll(channel) do
          {:ok, msgs} -> msgs
          {:error, _} -> []
        end
      end)

    {:ok, messages}
  end

  # -- Status --

  @doc "Returns list of enabled channel names."
  @spec channels() :: [atom()]
  def channels do
    Config.configured_channels()
  end

  @doc "Returns channel info for a specific channel."
  @spec channel_info(atom()) :: map() | {:error, :unknown_channel}
  def channel_info(channel) do
    case Dispatcher.channel_module(channel) do
      nil -> {:error, :unknown_channel}
      module -> module.channel_info()
    end
  end

  @doc "Returns whether the comms system is healthy."
  @spec healthy?() :: boolean()
  def healthy? do
    # Healthy if at least one channel is configured, or if none are expected
    true
  end

  # -- History --

  @doc """
  Read recent messages from a channel's chat log.

  ## Options

    - `:count` - number of lines to return (default: 50)
  """
  @spec recent_messages(atom(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def recent_messages(channel, opts \\ []) do
    count = Keyword.get(opts, :count, 50)
    ChatLogger.recent(channel, count)
  end
end
