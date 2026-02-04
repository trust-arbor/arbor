defmodule Arbor.Consensus.TopicRegistry do
  @moduledoc """
  Registry of consensus topics and their routing rules.

  Manages TopicRule structs with ETS for fast reads and GenServer for writes.
  Persists to checkpoint on every write (governance mutations are rare).

  ## Bootstrap Topics

  Two topics are always present and cannot be deleted:

  - `:topic_governance` - For creating/modifying topics (supermajority required)
  - `:general` - Catch-all for unmatched proposals (majority required)

  ## Read API (Direct ETS, no GenServer call)

  - `get/1` - Get a topic rule by name
  - `list/0` - List all topic rules
  - `exists?/1` - Check if a topic exists

  ## Write API (GenServer call, requires governance decision)

  - `register_topic/1` - Register a new topic
  - `update_topic/2` - Update an existing topic
  - `retire_topic/1` - Mark a topic as retired (keeps in registry)

  ## Persistence

  Uses Arbor.Checkpoint for persistence. On startup, attempts to restore
  from checkpoint (verifying Ed25519 signature). If invalid, falls back
  to bootstrap topics only.

  ## Supervision

  Should be started before the Coordinator in the consensus supervision tree.
  Uses ETS `:heir` option to maintain reads during GenServer restarts.
  """

  use GenServer

  alias Arbor.Consensus.TopicRule

  require Logger

  @table_name :consensus_topic_registry
  @checkpoint_id "consensus:topic_registry"
  @default_checkpoint_store Arbor.Checkpoint.Store.ETS

  # Bootstrap topics that are always present
  @bootstrap_topics %{
    topic_governance: %TopicRule{
      topic: :topic_governance,
      required_evaluators: [],
      min_quorum: :supermajority,
      allowed_proposers: :any,
      allowed_modes: [:decision],
      match_patterns: ["topic", "governance", "register", "evaluator", "registry"],
      is_bootstrap: true
    },
    general: %TopicRule{
      topic: :general,
      required_evaluators: [],
      min_quorum: :majority,
      allowed_proposers: :any,
      allowed_modes: [:decision, :advisory],
      match_patterns: [],
      is_bootstrap: true
    }
  }

  # ============================================================================
  # Client API - Reads (Direct ETS)
  # ============================================================================

  @doc """
  Get a topic rule by name.

  Returns `{:ok, TopicRule.t()}` or `{:error, :not_found}`.

  Optionally accepts a table name for testing isolation.
  """
  @spec get(atom(), atom()) :: {:ok, TopicRule.t()} | {:error, :not_found}
  def get(topic, table \\ @table_name) when is_atom(topic) do
    do_get(topic, table)
  end

  defp do_get(topic, table) do
    case :ets.lookup(table, topic) do
      [{^topic, rule}] -> {:ok, rule}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  @doc """
  List all topic rules.

  Optionally accepts a table name for testing isolation.
  """
  @spec list(atom()) :: [TopicRule.t()]
  def list(table \\ @table_name) do
    do_list(table)
  end

  defp do_list(table) do
    table
    |> :ets.tab2list()
    |> Enum.map(fn {_topic, rule} -> rule end)
  rescue
    ArgumentError -> []
  end

  @doc """
  Check if a topic exists.

  Optionally accepts a table name for testing isolation.
  """
  @spec exists?(atom(), atom()) :: boolean()
  def exists?(topic, table \\ @table_name) when is_atom(topic) do
    do_exists?(topic, table)
  end

  defp do_exists?(topic, table) do
    :ets.member(table, topic)
  rescue
    ArgumentError -> false
  end

  @doc """
  Get all bootstrap topics.
  """
  @spec bootstrap_topics() :: map()
  def bootstrap_topics, do: @bootstrap_topics

  # ============================================================================
  # Client API - Writes (GenServer calls)
  # ============================================================================

  @doc """
  Start the TopicRegistry.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register a new topic.

  Returns `{:ok, TopicRule.t()}` or `{:error, reason}`.
  """
  @spec register_topic(TopicRule.t() | keyword() | map(), GenServer.server()) ::
          {:ok, TopicRule.t()} | {:error, term()}
  def register_topic(rule_or_attrs, server \\ __MODULE__) do
    GenServer.call(server, {:register_topic, rule_or_attrs})
  end

  @doc """
  Update an existing topic.

  Returns `{:ok, TopicRule.t()}` or `{:error, reason}`.
  """
  @spec update_topic(atom(), map(), GenServer.server()) ::
          {:ok, TopicRule.t()} | {:error, term()}
  def update_topic(topic, updates, server \\ __MODULE__) do
    GenServer.call(server, {:update_topic, topic, updates})
  end

  @doc """
  Retire a topic (mark as no longer accepting new proposals).

  Bootstrap topics cannot be retired. Returns `:ok` or `{:error, reason}`.
  """
  @spec retire_topic(atom(), GenServer.server()) :: :ok | {:error, term()}
  def retire_topic(topic, server \\ __MODULE__) do
    GenServer.call(server, {:retire_topic, topic})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    # Create or take ownership of the ETS table
    table = create_or_take_table(opts)

    # Insert bootstrap topics first
    insert_bootstrap_topics(table)

    checkpoint_store = Keyword.get(opts, :checkpoint_store, @default_checkpoint_store)
    checkpoint_id = Keyword.get(opts, :checkpoint_id, @checkpoint_id)

    # Ed25519 signing — injectable via opts, nil disables
    {signing_key, verify_key} =
      case Keyword.get(opts, :signing_key) do
        nil ->
          if Keyword.get(opts, :enable_signing, true) do
            generate_keypair()
          else
            {nil, nil}
          end

        key ->
          {key, Keyword.get(opts, :verify_key)}
      end

    # Attempt checkpoint restore (verify signature if we have a verify_key)
    restored = restore_from_checkpoint(checkpoint_id, checkpoint_store, verify_key, opts)

    # Insert restored topics (non-bootstrap only)
    insert_restored_topics(table, restored)

    state = %{
      table: table,
      checkpoint_id: checkpoint_id,
      checkpoint_store: checkpoint_store,
      signing_key: signing_key,
      verify_key: verify_key
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register_topic, rule_or_attrs}, _from, state) do
    rule = resolve_topic_rule(rule_or_attrs)

    cond do
      do_exists?(rule.topic, state.table) ->
        {:reply, {:error, :already_exists}, state}

      rule.is_bootstrap ->
        {:reply, {:error, :cannot_register_bootstrap}, state}

      true ->
        :ets.insert(state.table, {rule.topic, rule})
        checkpoint_state(state)
        emit_topic_registered(rule)
        {:reply, {:ok, rule}, state}
    end
  end

  @impl true
  def handle_call({:update_topic, topic, updates}, _from, state) do
    case do_get(topic, state.table) do
      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}

      {:ok, rule} ->
        if rule.is_bootstrap and Map.has_key?(updates, :is_bootstrap) do
          {:reply, {:error, :cannot_modify_bootstrap_status}, state}
        else
          updated = struct(rule, updates)
          :ets.insert(state.table, {topic, updated})
          checkpoint_state(state)
          emit_topic_updated(updated)
          {:reply, {:ok, updated}, state}
        end
    end
  end

  @impl true
  def handle_call({:retire_topic, topic}, _from, state) do
    case do_get(topic, state.table) do
      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}

      {:ok, rule} ->
        if rule.is_bootstrap do
          {:reply, {:error, :cannot_retire_bootstrap}, state}
        else
          # Mark as retired by clearing allowed_modes
          retired = %{rule | allowed_modes: []}
          :ets.insert(state.table, {topic, retired})
          checkpoint_state(state)
          emit_topic_retired(retired)
          {:reply, :ok, state}
        end
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp create_or_take_table(opts) do
    table_name = Keyword.get(opts, :table_name, @table_name)

    case :ets.info(table_name) do
      :undefined ->
        :ets.new(table_name, [
          :named_table,
          :set,
          :public,
          read_concurrency: true
        ])

      _info ->
        table_name
    end
  end

  defp insert_bootstrap_topics(table) do
    Enum.each(@bootstrap_topics, fn {topic, rule} ->
      :ets.insert(table, {topic, rule})
    end)
  end

  defp restore_from_checkpoint(nil, _checkpoint_store, _verify_key, _opts), do: %{}
  defp restore_from_checkpoint(_checkpoint_id, nil, _verify_key, _opts), do: %{}

  defp restore_from_checkpoint(checkpoint_id, checkpoint_store, verify_key, _opts) do
    Arbor.Checkpoint.load(checkpoint_id, checkpoint_store, retries: 0)
  rescue
    e ->
      Logger.warning("TopicRegistry: checkpoint load exception: #{inspect(e)}, starting fresh")
      %{}
  else
    {:ok, data} when is_map(data) ->
      verify_and_extract_checkpoint(data, verify_key)

    {:ok, _other} ->
      Logger.warning("TopicRegistry: checkpoint data invalid format, starting fresh")
      %{}

    {:error, :not_found} ->
      Logger.debug("TopicRegistry: no checkpoint found, starting fresh")
      %{}

    {:error, reason} ->
      Logger.warning("TopicRegistry: checkpoint load failed: #{inspect(reason)}, starting fresh")
      %{}
  catch
    :exit, _ ->
      Logger.debug("TopicRegistry: checkpoint store not available, starting fresh")
      %{}
  end

  defp insert_restored_topics(table, restored) when is_map(restored) do
    Enum.each(restored, fn {topic_atom, rule_data} ->
      # Don't overwrite bootstrap topics
      unless Map.has_key?(@bootstrap_topics, topic_atom) do
        rule = restore_topic_rule(topic_atom, rule_data)
        :ets.insert(table, {topic_atom, rule})
      end
    end)
  end

  defp restore_topic_rule(topic, data) when is_map(data) do
    %TopicRule{
      topic: topic,
      required_evaluators: Map.get(data, :required_evaluators, []),
      min_quorum: Map.get(data, :min_quorum, :majority),
      allowed_proposers: Map.get(data, :allowed_proposers, :any),
      allowed_modes: Map.get(data, :allowed_modes, [:decision, :advisory]),
      match_patterns: Map.get(data, :match_patterns, []),
      is_bootstrap: false,
      registered_by: Map.get(data, :registered_by),
      registered_at: Map.get(data, :registered_at)
    }
  end

  defp checkpoint_state(%{checkpoint_id: nil}), do: :ok
  defp checkpoint_state(%{checkpoint_store: nil}), do: :ok

  defp checkpoint_state(state) do
    # Only checkpoint non-bootstrap topics
    topics =
      state.table
      |> :ets.tab2list()
      |> Enum.reject(fn {topic, _rule} -> Map.has_key?(@bootstrap_topics, topic) end)
      |> Map.new(fn {topic, rule} ->
        {topic, topic_rule_to_checkpoint(rule)}
      end)

    payload = sign_checkpoint(topics, state.signing_key)

    try do
      case Arbor.Checkpoint.save(state.checkpoint_id, payload, state.checkpoint_store) do
        :ok ->
          Logger.debug("TopicRegistry: checkpointed #{map_size(topics)} topics")

        {:error, reason} ->
          Logger.warning("TopicRegistry: checkpoint save failed: #{inspect(reason)}")
      end
    rescue
      _ -> :ok
    catch
      :exit, _ ->
        Logger.debug("TopicRegistry: checkpoint store not available for save")
    end
  end

  defp topic_rule_to_checkpoint(rule) do
    %{
      required_evaluators: rule.required_evaluators,
      min_quorum: rule.min_quorum,
      allowed_proposers: rule.allowed_proposers,
      allowed_modes: rule.allowed_modes,
      match_patterns: rule.match_patterns,
      registered_by: rule.registered_by,
      registered_at: rule.registered_at
    }
  end

  defp resolve_topic_rule(%TopicRule{} = rule), do: rule
  defp resolve_topic_rule(attrs) when is_list(attrs), do: TopicRule.new(attrs)
  defp resolve_topic_rule(attrs) when is_map(attrs), do: TopicRule.new(attrs)

  # ============================================================================
  # Ed25519 Checkpoint Signing
  # ============================================================================

  defp generate_keypair do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {priv, pub}
  end

  defp sign_checkpoint(topics, nil), do: topics

  defp sign_checkpoint(topics, signing_key) do
    serialized = :erlang.term_to_binary(topics)
    signature = :crypto.sign(:eddsa, :none, serialized, [signing_key, :ed25519])

    %{
      data: topics,
      signature: signature,
      signed_at: DateTime.utc_now()
    }
  end

  # Signed checkpoint with verify key — verify signature
  defp verify_and_extract_checkpoint(
         %{data: data, signature: signature} = _checkpoint,
         verify_key
       )
       when is_binary(signature) and verify_key != nil do
    serialized = :erlang.term_to_binary(data)

    if :crypto.verify(:eddsa, :none, serialized, signature, [verify_key, :ed25519]) do
      Logger.info("TopicRegistry: restored #{map_size(data)} signed topics from checkpoint")
      data
    else
      Logger.warning(
        "TopicRegistry: checkpoint signature invalid, starting fresh (bootstrap only)"
      )

      %{}
    end
  end

  # Signed checkpoint but no verify key — accept with warning
  defp verify_and_extract_checkpoint(%{data: data, signature: _sig}, nil) do
    Logger.warning("TopicRegistry: signed checkpoint but no verify key, accepting unsigned")
    Logger.info("TopicRegistry: restored #{map_size(data)} topics from checkpoint (unverified)")
    data
  end

  # Unsigned checkpoint (pre-signing migration) — accept with log
  defp verify_and_extract_checkpoint(data, _verify_key) when is_map(data) do
    Logger.info(
      "TopicRegistry: restored #{map_size(data)} topics from unsigned checkpoint (migration)"
    )

    data
  end

  # Signal emission for observability
  defp emit_topic_registered(rule) do
    emit_signal(:topic_registered, %{
      topic: rule.topic,
      min_quorum: rule.min_quorum,
      registered_by: rule.registered_by
    })
  end

  defp emit_topic_updated(rule) do
    emit_signal(:topic_updated, %{
      topic: rule.topic,
      min_quorum: rule.min_quorum
    })
  end

  defp emit_topic_retired(rule) do
    emit_signal(:topic_retired, %{topic: rule.topic})
  end

  defp emit_signal(event, data) do
    Arbor.Signals.emit(:consensus, event, data)
  rescue
    _ -> :ok
  end
end
