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
  alias Arbor.Comms.EngagementStore
  alias Arbor.Comms.InteractionRegistry.DurableLifecycleCore
  alias Arbor.Comms.InteractionRouter
  alias Arbor.Comms.PresenceTracker
  alias Arbor.Contracts.Comms.Engagement
  alias Arbor.Contracts.Comms.Interaction
  require Logger

  alias Arbor.Comms.Config
  alias Arbor.Comms.Dispatcher

  @doc "Request a human interaction through the public comms facade."
  @spec request_interaction(map() | Arbor.Contracts.Comms.Interaction.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def request_interaction(attrs_or_interaction, opts \\ []) do
    InteractionRouter.request(attrs_or_interaction, opts)
  end

  @typedoc "Authoritative identity receipt for a durable interaction operation."
  @type durable_interaction_receipt :: %{
          request_id: String.t(),
          operation_id: String.t(),
          owner_deadline_unix_ms: non_neg_integer()
        }

  @doc """
  Pure validation of a durable interaction payload against the closed durable
  serialization contract.

  Callers must keep `description` as short operator prose and place exact
  evidence in `metadata`. This check is side-effect free and does not consult
  Authority readiness or the durable store.
  """
  @spec validate_durable_interaction_payload(Interaction.t()) ::
          :ok | {:error, {:invalid_durable_interaction, term()}}
  def validate_durable_interaction_payload(%Interaction{} = interaction) do
    case DurableLifecycleCore.serialize_interaction(interaction) do
      {:ok, _serialized} -> :ok
      {:error, reason} -> {:error, {:invalid_durable_interaction, reason}}
    end
  end

  def validate_durable_interaction_payload(_interaction),
    do: {:error, {:invalid_durable_interaction, :invalid_interaction}}

  @doc """
  Request a durable interaction with an absolute owner deadline.

  The deadline is persisted in the initial durable record before discovery
  publication or adapter dispatch. Retries return the stored operation identity
  and may wake the supervised outbox dispatcher, but an accepted record is never
  sent again after Authority or dispatcher restart.

  Adapter delivery is at-least-once: a crash after the external adapter returns
  `:ok` but before the accepted-state CAS can redeliver the same `request_id`.
  Exactly-once delivery requires an idempotent adapter receipt that the current
  contract does not provide. Duplicate responses are still fenced by the
  durable first-terminal lifecycle transition.

  Caller-invalid payloads are rejected with
  `{:error, {:invalid_durable_interaction, reason}}` before Authority is
  consulted. Backend/readiness failures remain `{:error, :durable_unavailable}`.
  """
  @spec request_durable_interaction(Arbor.Contracts.Comms.Interaction.t(), keyword()) ::
          {:ok, durable_interaction_receipt()} | {:error, term()}
  def request_durable_interaction(%Interaction{} = interaction, opts)
      when is_list(opts) do
    with :ok <- validate_durable_interaction_payload(interaction) do
      InteractionRouter.request_durable(interaction, opts)
    end
  end

  def request_durable_interaction(_interaction, _opts), do: {:error, :invalid_options}

  @doc "Return readiness for opt-in node-restart durable interactions."
  @spec durable_interaction_readiness() :: term()
  def durable_interaction_readiness, do: Arbor.Comms.InteractionRegistry.durable_readiness()

  @doc "Alias for durable interaction readiness."
  def durable_readiness, do: durable_interaction_readiness()

  @doc "Return whether opt-in node-restart durable interactions are ready."
  @spec durable_ready?() :: boolean()
  def durable_ready?, do: Arbor.Comms.InteractionRegistry.durable_ready?()

  @doc """
  Register a process as an active interaction-delivery presence.

  Presence is scoped to `user_id` and `channel` and is removed automatically
  when `pid` exits.
  """
  @spec track_presence(pid(), String.t(), atom(), map()) ::
          {:ok, term()} | {:error, term()}
  def track_presence(pid, user_id, channel, metadata \\ %{})
      when is_pid(pid) and is_binary(user_id) and is_atom(channel) and is_map(metadata) do
    PresenceTracker.track(pid, user_id, channel, metadata)
  end

  @doc "Remove one interaction-delivery presence registration."
  @spec untrack_presence(pid(), String.t(), atom()) :: :ok
  def untrack_presence(pid, user_id, channel)
      when is_pid(pid) and is_binary(user_id) and is_atom(channel) do
    PresenceTracker.untrack(pid, user_id, channel)
  end

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
  Observe a durable interaction response for one exact operation.

  This observer never arms, extends, or settles the owner deadline. The
  authority validates the request, agent, operation, and deadline before the
  observer waits.
  """
  @spec await_durable_interaction_response(String.t(), String.t(), keyword()) ::
          {:ok, term(), map()} | {:error, :timeout | term()}
  def await_durable_interaction_response(request_id, agent_id, opts)
      when is_binary(request_id) and is_binary(agent_id) and is_list(opts) do
    InteractionRouter.await_durable_response(request_id, agent_id, opts)
  end

  def await_durable_interaction_response(_request_id, _agent_id, _opts),
    do: {:error, :invalid_options}

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
  Source-owned compare-and-settle for a pending approval interaction.

  Settlement abandons the exact pending interaction after reprojecting its
  closed identity. Never approves. Discovery miss is not treated as absence.
  """
  @spec compare_and_settle_pending_approval(map()) :: {:ok, map()} | {:error, term()}
  def compare_and_settle_pending_approval(fields) when is_map(fields) do
    InteractionRouter.compare_and_settle_pending_approval(fields)
  end

  def compare_and_settle_pending_approval(_fields),
    do: {:error, :invalid_reconciliation_settle_fields}

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

  # -- Voice/dashboard engagement transcript (VP-04A) --
  #
  # Canonical public path for a transport (dashboard ChatLive, voice) to resolve
  # a human's private, user-scoped engagement and atomically append/load
  # engagement-stamped transcript entries — without importing
  # Arbor.Comms.EngagementStore or Arbor.Persistence.SessionStore directly.

  @id_max_bytes 256
  @content_max_bytes 8192
  # Default per-value bound for transport/backend/mode (both roles).
  @metadata_value_max_bytes 1024
  # User whole-map budget (transport/backend/mode only).
  @user_metadata_max_bytes 2048
  # Closed public-boundary contract for assistant delegation metadata.
  # Independently mirrored from voice source bounds (Comms cannot depend
  # upward on arbor_voice): intent ceiling, control-char reject, task-id grammar.
  @delegation_task_max_bytes 2048
  @delegation_task_id_max_bytes 256
  @delegation_task_id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @delegation_control_chars ~r/[\x00-\x1F\x7F]/
  @delegation_provider_values MapSet.new(["grok"])
  @delegation_outcome_values MapSet.new(["dispatched"])
  # Assistant whole-map budget: exact smallest measured ceiling that admits a
  # maximal valid delegation receipt plus transport/backend/mode at their
  # per-value ceilings. Measured on the pinned OTP/Elixir runtime as
  # byte_size(:erlang.term_to_binary(max_meta)) == 4537 for:
  #   transport="voice", backend/mode at 1024, delegation_task at 2048,
  #   delegation_task_id at 256, provider/outcome enums.
  # Do not globally raise per-value bounds for transport/backend/mode.
  @assistant_metadata_max_bytes 4537
  @user_metadata_keys [:transport, :backend, :mode]
  # Shared atom source for assistant allowlist + all-or-none receipt keys.
  @delegation_receipt_key_atoms [
    :delegation_provider,
    :delegation_task,
    :delegation_task_id,
    :delegation_outcome
  ]
  @assistant_metadata_keys Enum.concat(
                             [:transport, :backend, :mode],
                             @delegation_receipt_key_atoms
                           )
  # String form after allowlist bounding — derived so lists cannot drift.
  @delegation_receipt_keys Enum.map(@delegation_receipt_key_atoms, &Atom.to_string/1)
  @resolve_opts_allowlist [:engagement_store]
  @turn_opts_allowlist [:persistence]
  @load_opts_allowlist [:limit, :before_timestamp, :persistence]

  @doc """
  Resolve (or create) the human's private, `:user`-scoped engagement with
  `agent_id`.

  Always resolves with the canonical, non-overridable creation options
  `scope: :user`, `visibility: :private`, `owner_tenant: user_id` — callers
  cannot widen or narrow those authority-bearing fields via `opts`.
  `opts[:engagement_store]` may inject a test double implementing
  `resolve_or_create/3`.
  """
  @spec resolve_user_engagement(String.t(), String.t(), keyword()) ::
          {:ok, Engagement.t()} | {:error, term()}
  def resolve_user_engagement(agent_id, user_id, opts \\ []) do
    with :ok <- validate_opts(opts, @resolve_opts_allowlist),
         :ok <- validate_id(agent_id, :agent_id),
         :ok <- validate_id(user_id, :user_id) do
      store = Keyword.get(opts, :engagement_store, EngagementStore)

      store.resolve_or_create(agent_id, user_id,
        scope: :user,
        visibility: :private,
        owner_tenant: user_id
      )
    end
  end

  @doc """
  Record one completed two-sided turn as exactly two ordered, atomically
  appended session entries under `"agent-session-\#{agent_id}"`.

  Both entries are stamped with `metadata["engagement_id"] = engagement_id`
  (source-owned, never overridable). `user_entry` and `assistant_entry` are
  maps of the shape `%{content: String.t(), sent_at | completed_at: DateTime.t(),
  metadata: map()}` (the user entry uses `:sent_at`, the assistant entry uses
  `:completed_at`). `content` must be nonblank, valid UTF-8, and within
  `#{@content_max_bytes}` bytes; it is converted to the existing text-block
  persistence shape (`[%{"type" => "text", "text" => content}]`). User
  `metadata` admits only `"transport"`, `"backend"`, `"mode"`. Assistant
  metadata may additionally carry flat delegation receipt keys
  (`delegation_provider`, `delegation_task`, `delegation_task_id`,
  `delegation_outcome`) with field-specific bounds; those four keys are
  all-or-none (zero present, or exactly all four). Any nonempty proper
  subset is rejected before persistence. Delegation keys supplied on the
  user entry are dropped. `"utterance_end_at"` is derived server-side from
  the user entry's `:sent_at` and cannot be supplied by the caller.
  Returns an explicit error for invalid input or a failed append; never
  reports success after a failed append. `opts[:persistence]` may inject a
  test double implementing the `Arbor.Persistence` session functions.
  """
  @spec record_engagement_turn(String.t(), String.t(), map(), map(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def record_engagement_turn(agent_id, engagement_id, user_entry, assistant_entry, opts \\ []) do
    with :ok <- validate_opts(opts, @turn_opts_allowlist),
         :ok <- validate_id(agent_id, :agent_id),
         :ok <- validate_id(engagement_id, :engagement_id),
         {:ok, user_attrs} <- build_turn_entry_attrs(:user, user_entry),
         {:ok, assistant_attrs} <- build_turn_entry_attrs(:assistant, assistant_entry),
         :ok <- validate_chronological(user_attrs.timestamp, assistant_attrs.timestamp) do
      persistence = Keyword.get(opts, :persistence, Arbor.Persistence)

      stamped_user =
        stamp_entry(user_attrs, engagement_id, derive_utterance_end_at(user_attrs.timestamp))

      stamped_assistant = stamp_entry(assistant_attrs, engagement_id, %{})
      session_id = "agent-session-#{agent_id}"

      with {:ok, session} <- persistence.ensure_session(session_id, agent_id, []) do
        persistence.append_session_entries(session.id, [stamped_user, stamped_assistant])
      end
    end
  end

  @doc """
  Load the display-ready transcript for one engagement, the same maps ChatLive
  consumes, via the public `Arbor.Persistence` facade with the engagement
  filter applied. Returns an explicit `{:error, reason}` for invalid ids or
  opts rather than an empty list. `opts` accepts only `:limit`,
  `:before_timestamp`, and `:persistence` (the test seam); any other key is
  rejected.
  """
  @spec load_engagement_transcript(String.t(), String.t(), keyword()) ::
          [map()] | {:error, term()}
  def load_engagement_transcript(agent_id, engagement_id, opts \\ []) do
    with :ok <- validate_opts(opts, @load_opts_allowlist),
         :ok <- validate_id(agent_id, :agent_id),
         :ok <- validate_id(engagement_id, :engagement_id) do
      persistence = Keyword.get(opts, :persistence, Arbor.Persistence)
      session_id = "agent-session-#{agent_id}"

      forward_opts =
        Keyword.take(opts, [:limit, :before_timestamp]) ++ [engagement_id: engagement_id]

      persistence.load_recent_session_messages(session_id, forward_opts)
    end
  end

  # -- Voice/dashboard engagement transcript: validation and shaping (private) --

  defp validate_opts(opts, allowlist) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, {:invalid_opts, :not_a_keyword_list}}

      has_duplicate_keys?(opts) ->
        {:error, {:invalid_opts, :duplicate_keys}}

      true ->
        case Enum.reject(Keyword.keys(opts), &(&1 in allowlist)) do
          [] -> :ok
          unknown -> {:error, {:invalid_opts, {:unknown_keys, unknown}}}
        end
    end
  end

  defp has_duplicate_keys?(opts) do
    keys = Keyword.keys(opts)
    length(keys) != length(Enum.uniq(keys))
  end

  # Byte-size is checked FIRST, before any Unicode validity/trim scan — those
  # scans walk the whole binary, so an untrusted oversized value (valid or
  # malformed UTF-8) is rejected on a cheap byte_size/1 call rather than after
  # a full scan of attacker-controlled bytes.
  defp validate_id(v, field) when is_binary(v) do
    cond do
      byte_size(v) > @id_max_bytes -> {:error, {:invalid_id, field, :too_large}}
      not String.valid?(v) -> {:error, {:invalid_id, field, :not_utf8}}
      String.trim(v) == "" -> {:error, {:invalid_id, field, :blank}}
      true -> :ok
    end
  end

  defp validate_id(_v, field), do: {:error, {:invalid_id, field, :not_a_string}}

  defp validate_content(v, field) when is_binary(v) do
    cond do
      byte_size(v) > @content_max_bytes -> {:error, {:invalid_content, field, :too_large}}
      not String.valid?(v) -> {:error, {:invalid_content, field, :not_utf8}}
      String.trim(v) == "" -> {:error, {:invalid_content, field, :blank}}
      true -> :ok
    end
  end

  defp validate_content(_v, field), do: {:error, {:invalid_content, field, :not_a_string}}

  defp validate_timestamp(%DateTime{}, _field), do: :ok
  defp validate_timestamp(_v, field), do: {:error, {:invalid_timestamp, field}}

  defp build_turn_entry_attrs(kind, entry) when is_map(entry) do
    ts_field = if kind == :user, do: :sent_at, else: :completed_at
    content = Map.get(entry, :content)
    ts = Map.get(entry, ts_field)

    with :ok <- validate_content(content, :content),
         :ok <- validate_timestamp(ts, ts_field),
         {:ok, meta} <- bound_and_validate_metadata(kind, Map.get(entry, :metadata, %{})) do
      entry_type = Atom.to_string(kind)

      {:ok,
       %{
         entry_type: entry_type,
         role: entry_type,
         content: [%{"type" => "text", "text" => content}],
         timestamp: ts,
         metadata: meta
       }}
    else
      {:error, reason} -> {:error, {invalid_entry_tag(kind), reason}}
    end
  end

  # Non-map user_entry/assistant_entry (nil, a list, a string, ...) — reject
  # with a typed error instead of raising inside Map.get/2 above.
  defp build_turn_entry_attrs(kind, _entry), do: {:error, {invalid_entry_tag(kind), :not_a_map}}

  defp invalid_entry_tag(:user), do: :invalid_user_entry
  defp invalid_entry_tag(:assistant), do: :invalid_assistant_entry

  defp validate_chronological(sent_at, completed_at) do
    if DateTime.compare(sent_at, completed_at) == :gt do
      {:error, :timestamps_out_of_order}
    else
      :ok
    end
  end

  # Looks up OUR fixed compiled-in atoms as either their atom or string form
  # in the CALLER's map. to_string/1 (via Atom.to_string/1) is only ever
  # called on those known-safe atoms, never on a caller-supplied key — key
  # allowlisting alone would not bound an arbitrary/adversarial key.
  # User and assistant use separate allowlists; delegation keys are
  # assistant-only and are dropped (not rejected) when present on user.
  defp bound_and_validate_metadata(kind, m) when is_map(m) and kind in [:user, :assistant] do
    keys = metadata_keys_for(kind)

    bounded =
      Enum.reduce(keys, %{}, fn key, acc ->
        case Map.fetch(m, key) do
          {:ok, value} ->
            Map.put(acc, Atom.to_string(key), value)

          :error ->
            case Map.fetch(m, Atom.to_string(key)) do
              {:ok, value} -> Map.put(acc, Atom.to_string(key), value)
              :error -> acc
            end
        end
      end)

    with :ok <- validate_delegation_receipt_shape(kind, bounded),
         :ok <- validate_metadata_values(kind, bounded),
         :ok <- validate_metadata_size(kind, bounded) do
      {:ok, bounded}
    end
  end

  defp bound_and_validate_metadata(_kind, _m), do: {:error, :metadata_must_be_a_map}

  defp metadata_keys_for(:user), do: @user_metadata_keys
  defp metadata_keys_for(:assistant), do: @assistant_metadata_keys

  # Public-boundary integrity: assistant delegation receipt keys are all-or-none.
  # Zero keys (no receipt) and exactly four keys (complete receipt) are admitted;
  # any nonempty proper subset fails before field validation and persistence.
  defp validate_delegation_receipt_shape(:assistant, metadata) when is_map(metadata) do
    present = Enum.count(@delegation_receipt_keys, &Map.has_key?(metadata, &1))

    case present do
      0 -> :ok
      4 -> :ok
      _ -> {:error, :incomplete_delegation_receipt}
    end
  end

  defp validate_delegation_receipt_shape(_kind, _metadata), do: :ok

  defp validate_metadata_values(kind, metadata) do
    Enum.reduce_while(metadata, :ok, fn {key, value}, :ok ->
      case validate_metadata_value(kind, key, value) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # Byte-size is checked FIRST, before String.valid?/1 — same reasoning as
  # validate_id/2 and validate_content/2 above: bound each individual
  # caller-supplied metadata string BEFORE it is scanned for UTF-8 validity or
  # folded into the whole-map `:erlang.term_to_binary/1` size check below, so
  # an oversized single value never reaches either scan.
  defp validate_metadata_value(_kind, key, v)
       when key in ["transport", "backend", "mode"] and is_binary(v) do
    if byte_size(v) <= @metadata_value_max_bytes and String.valid?(v) do
      :ok
    else
      {:error, :invalid_metadata_value}
    end
  end

  defp validate_metadata_value(_kind, key, v)
       when key in ["transport", "backend", "mode"] and
              (is_boolean(v) or is_number(v) or is_nil(v)) do
    :ok
  end

  defp validate_metadata_value(:assistant, "delegation_provider", v) when is_binary(v) do
    if MapSet.member?(@delegation_provider_values, v) and String.valid?(v) do
      :ok
    else
      {:error, :invalid_metadata_value}
    end
  end

  defp validate_metadata_value(:assistant, "delegation_outcome", v) when is_binary(v) do
    if MapSet.member?(@delegation_outcome_values, v) and String.valid?(v) do
      :ok
    else
      {:error, :invalid_metadata_value}
    end
  end

  defp validate_metadata_value(:assistant, "delegation_task", v) when is_binary(v) do
    cond do
      byte_size(v) > @delegation_task_max_bytes ->
        {:error, :invalid_metadata_value}

      not String.valid?(v) ->
        {:error, :invalid_metadata_value}

      String.trim(v) == "" ->
        {:error, :invalid_metadata_value}

      String.match?(v, @delegation_control_chars) ->
        {:error, :invalid_metadata_value}

      true ->
        :ok
    end
  end

  defp validate_metadata_value(:assistant, "delegation_task_id", v) when is_binary(v) do
    cond do
      byte_size(v) == 0 ->
        {:error, :invalid_metadata_value}

      byte_size(v) > @delegation_task_id_max_bytes ->
        {:error, :invalid_metadata_value}

      not String.valid?(v) ->
        {:error, :invalid_metadata_value}

      not Regex.match?(@delegation_task_id_pattern, v) ->
        {:error, :invalid_metadata_value}

      true ->
        :ok
    end
  end

  defp validate_metadata_value(_kind, _key, _v), do: {:error, :invalid_metadata_value}

  defp validate_metadata_size(kind, metadata) do
    ceiling = metadata_size_ceiling(kind)

    if byte_size(:erlang.term_to_binary(metadata)) <= ceiling do
      :ok
    else
      {:error, :metadata_too_large}
    end
  end

  defp metadata_size_ceiling(:user), do: @user_metadata_max_bytes
  defp metadata_size_ceiling(:assistant), do: @assistant_metadata_max_bytes

  # Source-owned: derived from the SAME sent_at already validated/persisted on
  # the user entry, so it can never diverge from it. Not in metadata allowlists,
  # so any caller-supplied "utterance_end_at" is unreachable, not compared.
  defp derive_utterance_end_at(%DateTime{} = sent_at) do
    %{"utterance_end_at" => DateTime.to_iso8601(sent_at)}
  end

  defp stamp_entry(attrs, engagement_id, extra_metadata) do
    metadata =
      attrs.metadata
      |> Map.merge(extra_metadata)
      |> Map.put("engagement_id", engagement_id)

    %{attrs | metadata: metadata}
  end
end
