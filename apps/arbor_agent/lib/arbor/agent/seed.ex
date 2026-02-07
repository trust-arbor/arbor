defmodule Arbor.Agent.Seed do
  @moduledoc """
  Agent Seed manifest — the complete portable identity of an agent.

  The Seed is a **manifest struct**: it knows where all agent state lives and can
  gather (capture) or push back (restore) that state, while each subsystem keeps
  its data in its natural home (ETS, GenServers, structs).

  ## Capabilities

  - **Capture** — snapshot every subsystem into one struct
  - **Restore** — push a snapshot back to all subsystems
  - **Serialize** — ETF binary or JSON-safe map
  - **File I/O** — save/load seeds to disk
  - **Identity evolution** — rate-limited self-model updates with rollback
  - **Learned capabilities** — track action outcomes over time
  - **Checkpoint integration** — implements `Arbor.Checkpoint` behaviour

  ## Example

      # Capture the current agent state
      {:ok, seed} = Arbor.Agent.Seed.capture("agent_001", reason: :checkpoint)

      # Save to disk
      :ok = Arbor.Agent.Seed.save_to_file(seed, "/tmp/agent_001.seed")

      # Later, restore
      {:ok, seed} = Arbor.Agent.Seed.load_from_file("/tmp/agent_001.seed")
      {:ok, _seed} = Arbor.Agent.Seed.restore(seed)
  """

  @behaviour Arbor.Checkpoint

  require Logger

  alias Arbor.Common.SafeAtom
  alias Arbor.Memory
  alias Arbor.Memory.{GoalStore, IntentStore, Preferences, SelfKnowledge, WorkingMemory}

  @seed_version 1

  # Identity rate limits
  @max_changes_per_day 3
  @cooldown_hours 4
  @max_self_model_versions 10
  @max_action_history 50

  defstruct [
    # --- Manifest Metadata ---
    :id,
    :agent_id,
    seed_version: @seed_version,
    captured_at: nil,
    captured_on_node: nil,
    capture_reason: :manual,

    # --- Identity (inline, always present) ---
    name: nil,
    profile: nil,
    self_model: %{},
    self_model_versions: [],
    identity_rate_limit: %{
      last_change_at: nil,
      changes_today: 0,
      cooldown_until: nil
    },

    # --- Learned State (inline) ---
    learned_capabilities: %{},
    action_history: [],

    # --- Captured Subsystem Snapshots ---
    working_memory: nil,
    context_window: nil,
    knowledge_graph: nil,
    self_knowledge: nil,
    preferences: nil,
    goals: [],
    recent_intents: [],
    recent_percepts: [],

    # --- Consolidation & Checkpoint Tracking ---
    consolidation_state: %{
      last_consolidation_at: nil,
      consolidation_count: 0
    },
    checkpoint_ref: nil,
    last_checkpoint_at: nil,
    version: 0,

    # --- Extensible metadata ---
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          agent_id: String.t(),
          seed_version: pos_integer(),
          captured_at: DateTime.t() | nil,
          captured_on_node: atom() | nil,
          capture_reason: atom(),
          name: String.t() | nil,
          profile: map() | nil,
          self_model: map(),
          self_model_versions: [map()],
          identity_rate_limit: map(),
          learned_capabilities: map(),
          action_history: [map()],
          working_memory: map() | nil,
          context_window: map() | nil,
          knowledge_graph: map() | nil,
          self_knowledge: map() | nil,
          preferences: map() | nil,
          goals: [map()],
          recent_intents: [map()],
          recent_percepts: [map()],
          consolidation_state: map(),
          checkpoint_ref: String.t() | nil,
          last_checkpoint_at: DateTime.t() | nil,
          version: non_neg_integer(),
          metadata: map()
        }

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create a new empty seed for an agent.

  ## Options

  - `:name` — human-friendly name
  - `:self_model` — initial self-model map
  - `:metadata` — arbitrary metadata
  - `:profile` — serialized profile map
  """
  @spec new(String.t(), keyword()) :: t()
  def new(agent_id, opts \\ []) do
    %__MODULE__{
      id: generate_id(),
      agent_id: agent_id,
      name: opts[:name],
      self_model: opts[:self_model] || %{},
      metadata: opts[:metadata] || %{},
      profile: opts[:profile]
    }
  end

  @doc """
  Load a Seed from file, or create a new one if the file doesn't exist.

  Convenience for CLI agents that need persistent identity across sessions.

  ## Options

  - `:agent_id` — Agent identifier for new seeds (default: "cli_agent")
  - All other options are passed to `new/2`
  """
  @spec load_or_new(String.t(), keyword()) :: {:ok, t()}
  def load_or_new(path, opts \\ []) do
    case load_from_file(path) do
      {:ok, seed} -> {:ok, seed}
      {:error, :enoent} -> {:ok, new(opts[:agent_id] || "cli_agent", opts)}
      {:error, _} -> {:ok, new(opts[:agent_id] || "cli_agent", opts)}
    end
  end

  # ============================================================================
  # Capture
  # ============================================================================

  @doc """
  Capture the current state of all subsystems for an agent.

  Gathers data from WorkingMemory, KnowledgeGraph, SelfKnowledge,
  Preferences, GoalStore, and IntentStore into a single Seed struct.

  ## Options

  - `:reason` — capture reason atom (default: `:manual`)
  - `:intent_limit` — max recent intents/percepts to capture (default: 100)
  - `:name` — agent name
  - `:self_model` — self-model map to include
  - `:profile` — serialized profile map
  - `:metadata` — metadata map to merge
  - `:context_window` — pre-serialized context window map
  """
  @spec capture(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def capture(agent_id, opts \\ []) do
    reason = Keyword.get(opts, :reason, :manual)
    intent_limit = Keyword.get(opts, :intent_limit, 100)

    seed = %__MODULE__{
      id: generate_id(),
      agent_id: agent_id,
      seed_version: @seed_version,
      captured_at: DateTime.utc_now(),
      captured_on_node: node(),
      capture_reason: reason,
      name: opts[:name],
      profile: opts[:profile],
      self_model: opts[:self_model] || %{},
      metadata: opts[:metadata] || %{},
      context_window: opts[:context_window],
      working_memory: capture_working_memory(agent_id),
      knowledge_graph: capture_knowledge_graph(agent_id),
      self_knowledge: capture_self_knowledge(agent_id),
      preferences: capture_preferences(agent_id),
      goals: capture_goals(agent_id),
      recent_intents: capture_intents(agent_id, intent_limit),
      recent_percepts: capture_percepts(agent_id, intent_limit),
      version: 1
    }

    emit_signal(:captured, %{agent_id: agent_id, seed_id: seed.id, reason: reason})

    Logger.info("Seed captured for #{agent_id}: #{seed.id} (reason: #{reason})")

    {:ok, seed}
  rescue
    e ->
      Logger.error("Seed capture failed for #{agent_id}: #{inspect(e)}")
      {:error, {:capture_failed, e}}
  end

  # ============================================================================
  # Restore
  # ============================================================================

  @doc """
  Restore seed state to all subsystems.

  Pushes captured data back to WorkingMemory, KnowledgeGraph, GoalStore, etc.

  ## Options

  - `:skip` — list of subsystem atoms to skip
    (e.g., `[:knowledge_graph, :context_window]`)
  - `:emit_signals` — whether to emit restore signal (default: true)
  """
  @spec restore(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def restore(%__MODULE__{} = seed, opts \\ []) do
    skip = Keyword.get(opts, :skip, [])
    emit = Keyword.get(opts, :emit_signals, true)
    agent_id = seed.agent_id

    unless :working_memory in skip do
      restore_working_memory(agent_id, seed.working_memory)
    end

    unless :knowledge_graph in skip do
      restore_knowledge_graph(agent_id, seed.knowledge_graph)
    end

    unless :preferences in skip do
      restore_preferences(agent_id, seed.preferences)
    end

    unless :goals in skip do
      restore_goals(agent_id, seed.goals)
    end

    # context_window, self_knowledge, intents, and percepts are stored
    # in the seed for the caller to use but not pushed to GenServers
    # (those subsystems need special handling by the agent process)

    if emit do
      emit_signal(:restored, %{agent_id: agent_id, seed_id: seed.id})
    end

    Logger.info("Seed restored for #{agent_id}: #{seed.id}")

    {:ok, seed}
  rescue
    e ->
      Logger.error("Seed restore failed for #{seed.agent_id}: #{inspect(e)}")
      {:error, {:restore_failed, e}}
  end

  # ============================================================================
  # Serialization — ETF Binary
  # ============================================================================

  @doc """
  Serialize a seed to ETF binary format.
  """
  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{} = seed) do
    seed |> to_map() |> :erlang.term_to_binary()
  end

  @doc """
  Deserialize a seed from ETF binary format.

  Uses `:safe` mode to prevent atom table exhaustion.
  """
  @spec deserialize(binary()) :: {:ok, t()} | {:error, term()}
  def deserialize(binary) when is_binary(binary) do
    data = :erlang.binary_to_term(binary, [:safe])
    from_map(data)
  rescue
    e -> {:error, {:deserialize_failed, e}}
  end

  # ============================================================================
  # Serialization — JSON-safe Map
  # ============================================================================

  @doc """
  Convert a seed to a JSON-safe map.

  All DateTime values are converted to ISO8601 strings, atoms to strings.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = seed) do
    %{
      "id" => seed.id,
      "agent_id" => seed.agent_id,
      "seed_version" => seed.seed_version,
      "captured_at" => maybe_to_iso8601(seed.captured_at),
      "captured_on_node" => to_string(seed.captured_on_node),
      "capture_reason" => to_string(seed.capture_reason),
      "name" => seed.name,
      "profile" => seed.profile,
      "self_model" => seed.self_model,
      "self_model_versions" => seed.self_model_versions,
      "identity_rate_limit" => serialize_rate_limit(seed.identity_rate_limit),
      "learned_capabilities" => serialize_learned_capabilities(seed.learned_capabilities),
      "action_history" => seed.action_history,
      "working_memory" => seed.working_memory,
      "context_window" => seed.context_window,
      "knowledge_graph" => seed.knowledge_graph,
      "self_knowledge" => seed.self_knowledge,
      "preferences" => seed.preferences,
      "goals" => seed.goals,
      "recent_intents" => seed.recent_intents,
      "recent_percepts" => seed.recent_percepts,
      "consolidation_state" => serialize_consolidation_state(seed.consolidation_state),
      "checkpoint_ref" => seed.checkpoint_ref,
      "last_checkpoint_at" => maybe_to_iso8601(seed.last_checkpoint_at),
      "version" => seed.version,
      "metadata" => seed.metadata
    }
  end

  @doc """
  Reconstruct a seed from a map (reverse of `to_map/1`).
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(data) when is_map(data) do
    seed =
      build_seed_metadata(data)
      |> Map.merge(build_seed_identity(data))
      |> Map.merge(build_seed_learned(data))
      |> Map.merge(build_seed_snapshots(data))
      |> Map.merge(build_seed_tracking(data))
      |> then(&struct(__MODULE__, &1))

    {:ok, seed}
  rescue
    e -> {:error, {:from_map_failed, e}}
  end

  # ============================================================================
  # File I/O
  # ============================================================================

  @doc """
  Save a seed to a file (ETF binary format).
  """
  @spec save_to_file(t(), String.t()) :: :ok | {:error, term()}
  def save_to_file(%__MODULE__{} = seed, path) do
    binary = serialize(seed)
    File.write(path, binary)
  end

  @doc """
  Load a seed from a file (ETF binary format).
  """
  @spec load_from_file(String.t()) :: {:ok, t()} | {:error, term()}
  def load_from_file(path) do
    case File.read(path) do
      {:ok, binary} -> deserialize(binary)
      {:error, _} = error -> error
    end
  end

  # ============================================================================
  # Identity Evolution
  # ============================================================================

  @doc """
  Update the agent's self-model with rate limiting.

  Changes are deep-merged into the existing self_model. The previous
  version is snapshotted for rollback (max #{@max_self_model_versions} versions kept).

  Rate limit: max #{@max_changes_per_day} changes per 24 hours with a
  #{@cooldown_hours}-hour cooldown between changes.

  ## Options

  - `:force` — bypass rate limiting (default: false)
  """
  @spec update_self_model(t(), map(), keyword()) :: {:ok, t()} | {:error, :rate_limited}
  def update_self_model(%__MODULE__{} = seed, changes, opts \\ []) when is_map(changes) do
    force = Keyword.get(opts, :force, false)

    if force || within_rate_limit?(seed.identity_rate_limit) do
      now = DateTime.utc_now()

      # Snapshot current version
      versions =
        [seed.self_model | seed.self_model_versions]
        |> Enum.take(@max_self_model_versions)

      # Deep merge changes
      updated_model = deep_merge(seed.self_model, changes)

      # Update rate limit
      rate_limit = %{
        last_change_at: now,
        changes_today: reset_or_increment_counter(seed.identity_rate_limit, now),
        cooldown_until: DateTime.add(now, @cooldown_hours * 3600, :second)
      }

      updated = %{
        seed
        | self_model: updated_model,
          self_model_versions: versions,
          identity_rate_limit: rate_limit,
          version: seed.version + 1
      }

      {:ok, updated}
    else
      {:error, :rate_limited}
    end
  end

  @doc """
  Roll back the self-model to the previous version.
  """
  @spec rollback_self_model(t()) :: {:ok, t()} | {:error, :no_versions}
  def rollback_self_model(%__MODULE__{self_model_versions: []}), do: {:error, :no_versions}

  def rollback_self_model(%__MODULE__{self_model_versions: [prev | rest]} = seed) do
    updated = %{
      seed
      | self_model: prev,
        self_model_versions: rest,
        version: seed.version + 1
    }

    {:ok, updated}
  end

  # ============================================================================
  # Learned Capabilities
  # ============================================================================

  @doc """
  Record the outcome of an action, updating learned capabilities.

  Tracks attempts, successes, failures, last outcome, and last used time.
  Also prepends to action_history (capped at #{@max_action_history}).
  """
  @spec record_action_outcome(t(), atom(), :success | :failure, map()) :: t()
  def record_action_outcome(%__MODULE__{} = seed, action, outcome, result_meta \\ %{}) do
    now = DateTime.utc_now()

    cap =
      Map.get(seed.learned_capabilities, action, %{
        attempts: 0,
        successes: 0,
        failures: 0,
        last_outcome: nil,
        last_used: nil
      })

    cap =
      cap
      |> Map.update!(:attempts, &(&1 + 1))
      |> Map.put(:last_outcome, outcome)
      |> Map.put(:last_used, now)
      |> then(fn c ->
        case outcome do
          :success -> Map.update!(c, :successes, &(&1 + 1))
          :failure -> Map.update!(c, :failures, &(&1 + 1))
        end
      end)

    history_entry = %{
      action: action,
      outcome: outcome,
      at: now,
      meta: result_meta
    }

    action_history =
      [history_entry | seed.action_history]
      |> Enum.take(@max_action_history)

    %{
      seed
      | learned_capabilities: Map.put(seed.learned_capabilities, action, cap),
        action_history: action_history
    }
  end

  # ============================================================================
  # Introspection
  # ============================================================================

  @doc """
  Return summary statistics about the seed's contents.
  """
  @spec stats(t()) :: map()
  def stats(%__MODULE__{} = seed) do
    %{
      agent_id: seed.agent_id,
      seed_id: seed.id,
      seed_version: seed.seed_version,
      version: seed.version,
      captured_at: seed.captured_at,
      has_working_memory: seed.working_memory != nil,
      has_context_window: seed.context_window != nil,
      has_knowledge_graph: seed.knowledge_graph != nil,
      has_self_knowledge: seed.self_knowledge != nil,
      has_preferences: seed.preferences != nil,
      has_profile: seed.profile != nil,
      goal_count: length(seed.goals),
      intent_count: length(seed.recent_intents),
      percept_count: length(seed.recent_percepts),
      learned_capability_count: map_size(seed.learned_capabilities),
      action_history_count: length(seed.action_history),
      self_model_version_count: length(seed.self_model_versions),
      self_model_keys: Map.keys(seed.self_model)
    }
  end

  # ============================================================================
  # Checkpoint Behaviour
  # ============================================================================

  @doc """
  Extract checkpoint data by capturing current agent state.
  """
  @impl Arbor.Checkpoint
  def extract_checkpoint_data(agent_id) when is_binary(agent_id) do
    case capture(agent_id, reason: :checkpoint) do
      {:ok, seed} -> to_map(seed)
      {:error, reason} -> raise "Seed capture failed: #{inspect(reason)}"
    end
  end

  @doc """
  Restore state from checkpoint data.
  """
  @impl Arbor.Checkpoint
  def restore_from_checkpoint(checkpoint_data, _initial_state) do
    {:ok, seed} = from_map(checkpoint_data)
    seed
  end

  # ============================================================================
  # Private — Capture Helpers
  # ============================================================================

  defp capture_working_memory(agent_id) do
    case Memory.get_working_memory(agent_id) do
      nil -> nil
      wm -> WorkingMemory.serialize(wm)
    end
  rescue
    _ -> nil
  end

  defp capture_knowledge_graph(agent_id) do
    case Memory.export_knowledge_graph(agent_id) do
      {:ok, graph_map} -> graph_map
      {:error, _} -> nil
    end
  rescue
    _ -> nil
  end

  defp capture_self_knowledge(agent_id) do
    case Memory.get_self_knowledge(agent_id) do
      nil -> nil
      sk -> SelfKnowledge.serialize(sk)
    end
  rescue
    _ -> nil
  end

  defp capture_preferences(agent_id) do
    case Memory.get_preferences(agent_id) do
      nil -> nil
      prefs -> Preferences.serialize(prefs)
    end
  rescue
    _ -> nil
  end

  defp capture_goals(agent_id) do
    GoalStore.export_all_goals(agent_id)
  rescue
    _ -> []
  end

  defp capture_intents(agent_id, limit) do
    IntentStore.recent_intents(agent_id, limit: limit)
    |> Enum.map(&safe_from_struct/1)
  rescue
    _ -> []
  end

  defp capture_percepts(agent_id, limit) do
    IntentStore.recent_percepts(agent_id, limit: limit)
    |> Enum.map(&safe_from_struct/1)
  rescue
    _ -> []
  end

  defp safe_from_struct(%_{} = struct), do: Map.from_struct(struct)
  defp safe_from_struct(map) when is_map(map), do: map

  # ============================================================================
  # Private — Restore Helpers
  # ============================================================================

  defp restore_working_memory(_agent_id, nil), do: :ok

  defp restore_working_memory(agent_id, wm_map) do
    wm = WorkingMemory.deserialize(wm_map)
    Memory.save_working_memory(agent_id, wm)
  rescue
    e ->
      Logger.warning("Failed to restore working memory for #{agent_id}: #{inspect(e)}")
      :ok
  end

  defp restore_knowledge_graph(_agent_id, nil), do: :ok

  defp restore_knowledge_graph(agent_id, graph_map) do
    Memory.import_knowledge_graph(agent_id, graph_map)
  rescue
    e ->
      Logger.warning("Failed to restore knowledge graph for #{agent_id}: #{inspect(e)}")
      :ok
  end

  defp restore_preferences(_agent_id, nil), do: :ok

  defp restore_preferences(agent_id, prefs_map) do
    prefs = Preferences.deserialize(prefs_map)
    Memory.save_preferences_for_agent(agent_id, prefs)
  rescue
    e ->
      Logger.warning("Failed to restore preferences for #{agent_id}: #{inspect(e)}")
      :ok
  end

  defp restore_goals(_agent_id, []), do: :ok

  defp restore_goals(agent_id, goals) do
    GoalStore.import_goals(agent_id, goals)
  rescue
    e ->
      Logger.warning("Failed to restore goals for #{agent_id}: #{inspect(e)}")
      :ok
  end

  # ============================================================================
  # Private — from_map Builders (extracted for complexity reduction)
  # ============================================================================

  defp build_seed_metadata(data) do
    %{
      id: data["id"],
      agent_id: data["agent_id"],
      seed_version: data["seed_version"] || @seed_version,
      captured_at: parse_datetime(data["captured_at"]),
      captured_on_node: safe_to_atom(data["captured_on_node"]),
      capture_reason: safe_to_atom(data["capture_reason"] || "manual")
    }
  end

  defp build_seed_identity(data) do
    %{
      name: data["name"],
      profile: data["profile"],
      self_model: data["self_model"] || %{},
      self_model_versions: data["self_model_versions"] || [],
      identity_rate_limit: deserialize_rate_limit(data["identity_rate_limit"])
    }
  end

  defp build_seed_learned(data) do
    %{
      learned_capabilities: deserialize_learned_capabilities(data["learned_capabilities"]),
      action_history: data["action_history"] || []
    }
  end

  defp build_seed_snapshots(data) do
    %{
      working_memory: data["working_memory"],
      context_window: data["context_window"],
      knowledge_graph: data["knowledge_graph"],
      self_knowledge: data["self_knowledge"],
      preferences: data["preferences"],
      goals: data["goals"] || [],
      recent_intents: data["recent_intents"] || [],
      recent_percepts: data["recent_percepts"] || []
    }
  end

  defp build_seed_tracking(data) do
    %{
      consolidation_state: deserialize_consolidation_state(data["consolidation_state"]),
      checkpoint_ref: data["checkpoint_ref"],
      last_checkpoint_at: parse_datetime(data["last_checkpoint_at"]),
      version: data["version"] || 0,
      metadata: data["metadata"] || %{}
    }
  end

  # ============================================================================
  # Private — Serialization Helpers
  # ============================================================================

  defp serialize_rate_limit(rl) do
    %{
      "last_change_at" => maybe_to_iso8601(rl[:last_change_at] || rl["last_change_at"]),
      "changes_today" => rl[:changes_today] || rl["changes_today"] || 0,
      "cooldown_until" => maybe_to_iso8601(rl[:cooldown_until] || rl["cooldown_until"])
    }
  end

  defp deserialize_rate_limit(nil) do
    %{last_change_at: nil, changes_today: 0, cooldown_until: nil}
  end

  defp deserialize_rate_limit(rl) do
    %{
      last_change_at: parse_datetime(rl["last_change_at"]),
      changes_today: rl["changes_today"] || 0,
      cooldown_until: parse_datetime(rl["cooldown_until"])
    }
  end

  defp serialize_learned_capabilities(caps) do
    Map.new(caps, fn {action, data} ->
      key = to_string(action)

      val =
        Map.new(data, fn
          {:last_used, dt} -> {"last_used", maybe_to_iso8601(dt)}
          {k, v} -> {to_string(k), v}
        end)

      {key, val}
    end)
  end

  defp deserialize_learned_capabilities(nil), do: %{}

  defp deserialize_learned_capabilities(caps) do
    Map.new(caps, fn {action_str, data} ->
      action = safe_to_atom(action_str)

      val =
        Map.new(data, fn
          {"last_used", dt_str} -> {:last_used, parse_datetime(dt_str)}
          {"last_outcome", outcome} -> {:last_outcome, safe_to_atom(outcome)}
          {k, v} -> {safe_to_atom(k), v}
        end)

      {action, val}
    end)
  end

  defp serialize_consolidation_state(cs) do
    %{
      "last_consolidation_at" =>
        maybe_to_iso8601(cs[:last_consolidation_at] || cs["last_consolidation_at"]),
      "consolidation_count" => cs[:consolidation_count] || cs["consolidation_count"] || 0
    }
  end

  defp deserialize_consolidation_state(nil) do
    %{last_consolidation_at: nil, consolidation_count: 0}
  end

  defp deserialize_consolidation_state(cs) do
    %{
      last_consolidation_at: parse_datetime(cs["last_consolidation_at"]),
      consolidation_count: cs["consolidation_count"] || 0
    }
  end

  defp maybe_to_iso8601(nil), do: nil
  defp maybe_to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp maybe_to_iso8601(str) when is_binary(str), do: str

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp safe_to_atom(nil), do: nil
  defp safe_to_atom(a) when is_atom(a), do: a

  defp safe_to_atom(str) when is_binary(str) do
    case SafeAtom.to_existing(str) do
      {:ok, atom} -> atom
      {:error, _} -> str
    end
  end

  # ============================================================================
  # Private — Identity Helpers
  # ============================================================================

  defp within_rate_limit?(rate_limit) do
    now = DateTime.utc_now()

    # Check cooldown
    cooldown_ok =
      case rate_limit[:cooldown_until] do
        nil -> true
        cooldown -> DateTime.compare(now, cooldown) != :lt
      end

    # Check daily limit
    daily_ok =
      case rate_limit[:last_change_at] do
        nil ->
          true

        last ->
          if same_day?(now, last) do
            (rate_limit[:changes_today] || 0) < @max_changes_per_day
          else
            true
          end
      end

    cooldown_ok && daily_ok
  end

  defp same_day?(%DateTime{} = a, %DateTime{} = b) do
    Date.compare(DateTime.to_date(a), DateTime.to_date(b)) == :eq
  end

  defp reset_or_increment_counter(rate_limit, now) do
    case rate_limit[:last_change_at] do
      nil ->
        1

      last ->
        if same_day?(now, last) do
          (rate_limit[:changes_today] || 0) + 1
        else
          1
        end
    end
  end

  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn
      _k, v1, v2 when is_map(v1) and is_map(v2) -> deep_merge(v1, v2)
      _k, _v1, v2 -> v2
    end)
  end

  # ============================================================================
  # Private — Misc
  # ============================================================================

  defp generate_id do
    "seed_" <> Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)
  end

  @seed_signals %{
    captured: :seed_captured,
    restored: :seed_restored
  }

  defp emit_signal(event, data) do
    signal_type = Map.fetch!(@seed_signals, event)
    Arbor.Signals.emit(:agent, signal_type, data)
  rescue
    _ -> :ok
  end
end
