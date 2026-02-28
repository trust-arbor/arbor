defmodule Arbor.Comms do
  @moduledoc """
  Unified external communications for Arbor.

  Provides a single facade for sending and receiving messages across
  multiple channels (Signal, Limitless, Email, Voice).

  ## Sending Messages

      Arbor.Comms.send(:signal, "+1XXXXXXXXXX", "Hello from Arbor!")
      Arbor.Comms.send_signal("+1XXXXXXXXXX", "Hello!")

  ## Checking Status

      Arbor.Comms.channels()
      #=> [:signal]

      Arbor.Comms.healthy?()
      #=> true

  ## Reading History

      Arbor.Comms.recent_messages(:signal)
  """

  alias Arbor.Comms.Channel
  alias Arbor.Comms.Channels.Limitless
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

  @doc "Send an email via the Email channel."
  @spec send_email(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def send_email(to, subject, body, opts \\ []) do
    Dispatcher.send(:email, to, body, Keyword.put(opts, :subject, subject))
  end

  # -- Receiving --

  @doc """
  Poll a specific channel for new messages.

  Returns `{:ok, messages}` or `{:error, reason}`.
  """
  @spec poll(atom()) :: {:ok, [Arbor.Contracts.Comms.Message.t()]} | {:error, term()}
  def poll(channel) do
    case Dispatcher.receiver_module(channel) do
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

  @doc "Check Limitless API connectivity."
  @spec limitless_status() :: {:ok, :connected} | {:error, term()}
  def limitless_status do
    Limitless.Client.test_connection()
  end

  @doc "Returns whether the comms system is healthy."
  @spec healthy?() :: boolean()
  def healthy? do
    # Healthy if at least one channel is configured, or if none are expected
    true
  end

  # -- Channels (unified message containers) --

  @doc """
  Create a new channel under the ChannelSupervisor.

  Returns `{:ok, channel_id}` on success.

  ## Options

  - `:type` — `:group`, `:dm`, `:public`, `:private`, `:ops_room` (default: `:group`)
  - `:owner_id` — creator ID
  - `:members` — list of `%{id, name, type}` maps
  - `:rate_limit_ms` — per-sender cooldown (default: 2000ms)
  """
  @spec create_channel(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_channel(name, opts \\ []) do
    channel_id = Keyword.get_lazy(opts, :channel_id, fn ->
      suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
      "chan_#{suffix}"
    end)

    child_opts = Keyword.merge(opts, channel_id: channel_id, name: name)

    case DynamicSupervisor.start_child(
           Arbor.Comms.ChannelSupervisor,
           {Channel, child_opts}
         ) do
      {:ok, _pid} -> {:ok, channel_id}
      {:error, {:already_started, _}} -> {:ok, channel_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Send a message to a channel by ID."
  @spec send_to_channel(String.t(), String.t(), String.t(), atom(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def send_to_channel(channel_id, sender_id, sender_name, sender_type, content, metadata \\ %{}) do
    case lookup_channel(channel_id) do
      {:ok, pid} -> Channel.send_message(pid, sender_id, sender_name, sender_type, content, metadata)
      error -> error
    end
  end

  @doc "Add a member to a channel."
  @spec join_channel(String.t(), map()) :: :ok | {:error, term()}
  def join_channel(channel_id, member) do
    case lookup_channel(channel_id) do
      {:ok, pid} -> Channel.add_member(pid, member)
      error -> error
    end
  end

  @doc "Remove a member from a channel."
  @spec leave_channel(String.t(), String.t()) :: :ok | {:error, term()}
  def leave_channel(channel_id, member_id) do
    case lookup_channel(channel_id) do
      {:ok, pid} -> Channel.remove_member(pid, member_id)
      error -> error
    end
  end

  @doc "List all active channels as `[{channel_id, pid}]`."
  @spec list_channels() :: [{String.t(), pid()}]
  def list_channels do
    Registry.select(Arbor.Comms.ChannelRegistry, [
      {{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
  rescue
    _ -> []
  end

  @doc "Get channel info by ID."
  @spec get_channel_info(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_channel_info(channel_id) do
    case lookup_channel(channel_id) do
      {:ok, pid} -> {:ok, Channel.channel_info(pid)}
      error -> error
    end
  end

  @doc "Get message history for a channel."
  @spec channel_history(String.t(), keyword()) :: {:ok, [map()]} | {:error, :not_found}
  def channel_history(channel_id, opts \\ []) do
    case lookup_channel(channel_id) do
      {:ok, pid} -> {:ok, Channel.get_history(pid, opts)}
      error -> error
    end
  end

  @doc "Get members of a channel."
  @spec channel_members(String.t()) :: {:ok, [map()]} | {:error, :not_found}
  def channel_members(channel_id) do
    case lookup_channel(channel_id) do
      {:ok, pid} -> {:ok, Channel.get_members(pid)}
      error -> error
    end
  end

  defp lookup_channel(channel_id) do
    case Registry.lookup(Arbor.Comms.ChannelRegistry, channel_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
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
