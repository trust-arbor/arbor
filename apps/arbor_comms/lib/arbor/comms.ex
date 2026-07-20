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
  alias Arbor.Comms.Channels.Voice
  alias Arbor.Comms.ChatLogger
  alias Arbor.Comms.InteractionRouter
  require Logger

  alias Arbor.Comms.Config
  alias Arbor.Comms.Dispatcher

  @doc """
  Resolve the human operator's `user_id` for routing an interaction
  on behalf of `agent_id`.

  Single-operator deployments (current default) return the configured
  `:arbor_comms, :signal, :interaction_user_id` for any agent — the
  same identifier `Signal.PresenceKeeper` registers with
  `PresenceTracker`. Multi-operator deployments will eventually plug in
  a per-agent owner lookup here; for now the configured operator is
  the universal target.

  Falls back to `agent_id` itself when no operator is configured (the
  pre-this-helper behavior), so deployments without a Signal config
  see no behavior change.
  """
  @spec operator_for_agent(String.t()) :: String.t()
  def operator_for_agent(agent_id) when is_binary(agent_id) do
    case Application.get_env(:arbor_comms, :signal, []) |> Keyword.get(:interaction_user_id) do
      nil -> agent_id
      "" -> agent_id
      operator when is_binary(operator) -> operator
    end
  end

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

  # -- Human-in-the-loop interactions (public facade) --

  @doc "List interactions whose authority still reports them as pending."
  @spec pending_interactions() :: [Arbor.Contracts.Comms.Interaction.t()]
  def pending_interactions do
    InteractionRouter.pending()
  end

  @doc """
  Wait for an operator response to an interaction request.

  Delegates to `Arbor.Comms.InteractionRouter.await_response/3`. Prefer this
  facade over reaching into the router module from other libraries.
  """
  @spec await_interaction_response(String.t(), String.t(), keyword()) ::
          {:ok, term(), map()} | {:error, :timeout | term()}
  def await_interaction_response(request_id, agent_id, opts \\ [])
      when is_binary(request_id) and is_binary(agent_id) do
    InteractionRouter.await_response(request_id, agent_id, opts)
  end

  @doc """
  Submit a response to a pending interaction.

  Public facade over `InteractionRouter.respond/3`.
  """
  @spec respond_to_interaction(String.t(), term(), map()) :: :ok | {:error, term()}
  def respond_to_interaction(request_id, response, metadata \\ %{})
      when is_binary(request_id) do
    InteractionRouter.respond(request_id, response, metadata)
  end

  @doc """
  Abandon a pending interaction with an explicit lifecycle reason.

  Public facade over `InteractionRouter.abandon/2`.
  """
  @spec abandon_interaction(String.t(), atom() | String.t()) :: :ok | {:error, term()}
  def abandon_interaction(request_id, reason)
      when is_binary(request_id) and (is_atom(reason) or is_binary(reason)) do
    InteractionRouter.abandon(request_id, reason)
  end

  @doc """
  Look up a retained response from the interaction's authority node.
  """
  @spec get_interaction_response(String.t()) ::
          {:ok, %{response: term(), metadata: map()}} | :not_found
  def get_interaction_response(request_id) when is_binary(request_id) do
    InteractionRouter.get_response(request_id)
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
    channel_id =
      Keyword.get_lazy(opts, :channel_id, fn ->
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
      {:ok, pid} ->
        Channel.send_message(pid, sender_id, sender_name, sender_type, content, metadata)

      error ->
        error
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
    e ->
      Logger.debug("[Comms] list_channels failed: #{Exception.message(e)}")
      []
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

  @doc """
  Verify a channel message's cryptographic signature.

  Returns:
  - `true` — signature present and valid
  - `false` — signature present but invalid (tampered or wrong key)
  - `nil` — no signature present or public key unavailable
  """
  @spec verify_message_signature(map()) :: boolean() | nil
  def verify_message_signature(message) do
    Channel.verify_message_signature(message)
  end

  @doc """
  Search channels with composable filters.

  When persistence is available, delegates to ChannelStore.search_channels/1.
  Falls back to in-memory Registry scan with client-side filtering.

  ## Options

  - `:name` — substring match on channel name
  - `:type` — exact type match (string)
  - `:owner_id` — exact owner match
  - `:member_id` — member containment check
  - `:limit` — max results (default: 50)
  """
  @spec search_channels(keyword()) :: [map()]
  def search_channels(opts \\ []) do
    if channel_store_available?() do
      apply(Arbor.Persistence.ChannelStore, :search_channels, [opts])
      |> Enum.map(&channel_schema_to_info/1)
    else
      # Fallback: in-memory scan
      limit = Keyword.get(opts, :limit, 50)

      list_channels()
      |> Enum.map(fn {channel_id, _pid} ->
        case get_channel_info(channel_id) do
          {:ok, info} -> info
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> maybe_filter(:name, Keyword.get(opts, :name))
      |> maybe_filter(:type, Keyword.get(opts, :type))
      |> maybe_filter(:owner_id, Keyword.get(opts, :owner_id))
      |> Enum.take(limit)
    end
  rescue
    e ->
      Logger.warning("[Comms] search_channels failed: #{Exception.message(e)}")
      []
  catch
    :exit, reason ->
      Logger.warning("[Comms] search_channels exited: #{inspect(reason)}")
      []
  end

  @doc """
  Update a channel's name and/or topic.

  Updates both in-memory GenServer state and persistence.
  """
  @spec update_channel(String.t(), keyword()) :: :ok | {:error, term()}
  def update_channel(channel_id, opts) when is_list(opts) do
    # Update in-memory GenServer
    with {:ok, pid} <- lookup_channel(channel_id) do
      Channel.update_info(pid, opts)

      # Persist changes async
      if channel_store_available?() do
        attrs = %{}
        attrs = if opts[:name], do: Map.put(attrs, :name, opts[:name]), else: attrs

        attrs =
          if opts[:topic],
            do: Map.put(attrs, :metadata, %{"topic" => opts[:topic]}),
            else: attrs

        if map_size(attrs) > 0 do
          Task.start(fn ->
            apply(Arbor.Persistence.ChannelStore, :update_channel, [channel_id, attrs])
          end)
        end
      end

      :ok
    end
  end

  @doc """
  Delete a channel — terminates GenServer and removes from persistence.
  """
  @spec delete_channel(String.t()) :: :ok | {:error, term()}
  def delete_channel(channel_id) do
    # Terminate GenServer if running
    case lookup_channel(channel_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(Arbor.Comms.ChannelSupervisor, pid)

      {:error, :not_found} ->
        :ok
    end

    # Delete from persistence
    if channel_store_available?() do
      apply(Arbor.Persistence.ChannelStore, :delete_channel, [channel_id])
    end

    :ok
  rescue
    e ->
      Logger.warning("[Comms] delete_channel failed for #{channel_id}: #{Exception.message(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("[Comms] delete_channel exited for #{channel_id}: #{inspect(reason)}")
      :ok
  end

  defp channel_store_available? do
    Code.ensure_loaded?(Arbor.Persistence.ChannelStore) and
      apply(Arbor.Persistence.ChannelStore, :available?, [])
  end

  defp channel_schema_to_info(schema) do
    members = schema.members || []

    %{
      channel_id: schema.channel_id,
      name: schema.name || schema.channel_id,
      type: String.to_existing_atom(schema.type),
      owner_id: schema.owner_id,
      member_count: length(members),
      message_count: 0,
      encrypted: schema.type in ["private", "dm"],
      encryption_type: encryption_type_for(schema.type)
    }
  rescue
    # String.to_existing_atom can fail for unknown types
    _ ->
      %{
        channel_id: schema.channel_id,
        name: schema.name || schema.channel_id,
        type: :group,
        owner_id: schema.owner_id,
        member_count: length(schema.members || []),
        message_count: 0,
        encrypted: false,
        encryption_type: nil
      }
  end

  defp encryption_type_for("private"), do: :aes_256_gcm
  defp encryption_type_for("dm"), do: :double_ratchet
  defp encryption_type_for(_), do: nil

  defp maybe_filter(channels, :name, nil), do: channels

  defp maybe_filter(channels, :name, name) do
    name_down = String.downcase(name)
    Enum.filter(channels, fn c -> String.downcase(to_string(c.name)) =~ name_down end)
  end

  defp maybe_filter(channels, :type, nil), do: channels

  defp maybe_filter(channels, :type, type) do
    type_atom =
      if is_atom(type), do: type, else: String.to_existing_atom(type)

    Enum.filter(channels, fn c -> c.type == type_atom end)
  rescue
    _ -> channels
  end

  defp maybe_filter(channels, :owner_id, nil), do: channels

  defp maybe_filter(channels, :owner_id, owner_id) do
    Enum.filter(channels, fn c -> c.owner_id == owner_id end)
  end

  defp lookup_channel(channel_id) do
    case Registry.lookup(Arbor.Comms.ChannelRegistry, channel_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  # -- Voice --

  @doc """
  Start a voice session with a phone node.

  Returns `{:ok, pid}` for the session GenServer.

  ## Options

    - `:agent_id` — agent to converse with (default: first running agent)
    - `:listen_mode` — `:listen`, `:stream_listen`, or `:buddie_listen`
    - `:listen_seconds` — STT recording duration (default: 5)
    - `:voice` — TTS voice index (0-7)
    - `:thinking_sound` — show thinking toast (default: true)
  """
  @spec start_voice_session(node(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_voice_session(phone_node, opts \\ []) do
    Voice.Session.start_link(Keyword.put(opts, :phone_node, phone_node))
  end

  @doc "Execute a single voice turn: listen -> agent -> speak."
  @spec voice_turn(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def voice_turn(session, opts \\ []) do
    Voice.Session.voice_turn(session, opts)
  end

  @doc "Send text to agent and speak the response."
  @spec voice_say(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def voice_say(session, text, opts \\ []) do
    Voice.Session.conversation_turn(session, text, opts)
  end

  @doc "Speak text on the phone without agent processing."
  @spec voice_speak(node(), String.t(), keyword()) :: :ok | {:error, term()}
  def voice_speak(phone_node, text, opts \\ []) do
    Voice.speak(phone_node, text, opts)
  end

  @doc "Check if a phone node is reachable."
  @spec voice_ping(node()) :: boolean()
  def voice_ping(phone_node) do
    Voice.ping(phone_node)
  end

  @doc "Stop any in-progress listen on the phone."
  @spec voice_stop_listen(node()) :: :ok | {:error, term()}
  def voice_stop_listen(phone_node) do
    Voice.stop_listen(phone_node)
  end

  @doc "Cancel in-progress TTS playback on the phone."
  @spec voice_tts_stop(node()) :: :ok | {:error, term()}
  def voice_tts_stop(phone_node) do
    Voice.tts_stop(phone_node)
  end

  @doc "Verify the current speaker against phone-side enrollments (VOICE-21)."
  @spec voice_speaker_verify(node(), keyword()) :: {:ok, map()} | {:error, term()}
  def voice_speaker_verify(phone_node, opts \\ []) do
    Voice.speaker_verify(phone_node, opts)
  end

  @doc "Enroll the current speaker on the phone (records ~5 s phone-side)."
  @spec voice_speaker_enroll(node(), String.t() | atom(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def voice_speaker_enroll(phone_node, name, opts \\ []) do
    Voice.speaker_enroll(phone_node, name, opts)
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
