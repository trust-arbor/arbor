defmodule Arbor.Memory.SelfKnowledge do
  @moduledoc """
  Agent's structured understanding of own capabilities, traits, values, and architecture.

  SelfKnowledge is a pure struct that represents what an agent knows about itself.
  This includes capabilities (skills and proficiency), personality traits, values,
  preferences, and growth over time.

  ## Versioning

  SelfKnowledge supports snapshotting and rollback. Before any significant change,
  call `snapshot/1` to save the current state. If needed, call `rollback/1` to
  restore a previous version. Up to 10 versions are kept.

  ## Usage

      sk = SelfKnowledge.new("agent_001")
      sk = SelfKnowledge.add_capability(sk, "elixir_programming", 0.8, "multiple projects completed")
      sk = SelfKnowledge.add_trait(sk, :curious, 0.9, "frequently asks exploratory questions")
      sk = SelfKnowledge.add_value(sk, :honesty, 0.95, "prioritizes truthful responses")

      summary = SelfKnowledge.summarize(sk)
      # => "Agent agent_001: 1 capability(s), 1 trait(s), 1 value(s)..."
  """

  @type capability :: %{
          name: String.t(),
          proficiency: float(),
          evidence: String.t() | nil,
          added_at: DateTime.t()
        }

  @type personality_trait :: %{
          trait: atom(),
          strength: float(),
          evidence: String.t() | nil,
          added_at: DateTime.t()
        }

  @type value :: %{
          value: atom(),
          importance: float(),
          evidence: String.t() | nil,
          added_at: DateTime.t()
        }

  @type preference :: %{
          preference: atom() | String.t(),
          strength: float(),
          added_at: DateTime.t()
        }

  @type growth_entry :: %{
          area: atom() | String.t(),
          change: String.t(),
          timestamp: DateTime.t()
        }

  @type t :: %__MODULE__{
          agent_id: String.t(),
          capabilities: [capability()],
          personality_traits: [personality_trait()],
          values: [value()],
          preferences: [preference()],
          growth_log: [growth_entry()],
          architecture: map(),
          version: pos_integer(),
          version_history: [map()]
        }

  @enforce_keys [:agent_id]
  defstruct [
    :agent_id,
    capabilities: [],
    personality_traits: [],
    values: [],
    preferences: [],
    growth_log: [],
    architecture: %{},
    version: 1,
    version_history: []
  ]

  alias Arbor.Common.SafeAtom

  @max_version_history 10

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create a new SelfKnowledge struct for an agent.

  ## Options

  - `:capabilities` - Initial list of capabilities
  - `:personality_traits` - Initial list of traits
  - `:values` - Initial list of values
  - `:preferences` - Initial list of preferences
  - `:architecture` - Understanding of own system

  ## Examples

      sk = SelfKnowledge.new("agent_001")
      sk = SelfKnowledge.new("agent_001", architecture: %{memory_system: "arbor_memory"})
  """
  @spec new(String.t(), keyword()) :: t()
  def new(agent_id, opts \\ []) do
    %__MODULE__{
      agent_id: agent_id,
      capabilities: Keyword.get(opts, :capabilities, []),
      personality_traits: Keyword.get(opts, :personality_traits, []),
      values: Keyword.get(opts, :values, []),
      preferences: Keyword.get(opts, :preferences, []),
      architecture: Keyword.get(opts, :architecture, %{}),
      version: 1,
      version_history: []
    }
  end

  # ============================================================================
  # Capabilities
  # ============================================================================

  @doc """
  Add a capability to the agent's self-knowledge.

  Proficiency should be a float between 0.0 and 1.0.

  ## Examples

      sk = SelfKnowledge.add_capability(sk, "elixir", 0.8)
      sk = SelfKnowledge.add_capability(sk, "debugging", 0.7, "resolved 50+ issues")
  """
  @spec add_capability(t(), String.t(), float(), String.t() | nil) :: t()
  def add_capability(%__MODULE__{} = sk, name, proficiency, evidence \\ nil) do
    proficiency = clamp_float(proficiency)

    capability = %{
      name: name,
      proficiency: proficiency,
      evidence: evidence,
      added_at: DateTime.utc_now()
    }

    # Replace existing capability with same name or add new
    capabilities =
      sk.capabilities
      |> Enum.reject(&(&1.name == name))
      |> List.insert_at(0, capability)

    %{sk | capabilities: capabilities}
  end

  @doc """
  Update an existing capability.

  ## Changes

  - `:proficiency` - New proficiency level
  - `:evidence` - Updated evidence

  ## Examples

      sk = SelfKnowledge.update_capability(sk, "elixir", proficiency: 0.9)
  """
  @spec update_capability(t(), String.t(), keyword()) :: t()
  def update_capability(%__MODULE__{} = sk, name, changes) do
    capabilities =
      Enum.map(sk.capabilities, fn cap ->
        if cap.name == name do
          cap
          |> maybe_update(:proficiency, Keyword.get(changes, :proficiency))
          |> maybe_update(:evidence, Keyword.get(changes, :evidence))
        else
          cap
        end
      end)

    %{sk | capabilities: capabilities}
  end

  @doc """
  Get capabilities, optionally filtered by proficiency.

  ## Options

  - `:min_proficiency` - Minimum proficiency to include
  - `:max_proficiency` - Maximum proficiency to include

  ## Examples

      all = SelfKnowledge.get_capabilities(sk)
      expert = SelfKnowledge.get_capabilities(sk, min_proficiency: 0.8)
  """
  @spec get_capabilities(t(), keyword()) :: [capability()]
  def get_capabilities(%__MODULE__{} = sk, opts \\ []) do
    min = Keyword.get(opts, :min_proficiency, 0.0)
    max = Keyword.get(opts, :max_proficiency, 1.0)

    Enum.filter(sk.capabilities, fn cap ->
      cap.proficiency >= min and cap.proficiency <= max
    end)
  end

  # ============================================================================
  # Personality & Values
  # ============================================================================

  @doc """
  Add a personality trait to the agent's self-knowledge.

  Strength should be a float between 0.0 and 1.0.

  ## Examples

      sk = SelfKnowledge.add_trait(sk, :curious, 0.9)
      sk = SelfKnowledge.add_trait(sk, :methodical, 0.7, "follows structured approaches")
  """
  @spec add_trait(t(), atom(), float(), String.t() | nil) :: t()
  def add_trait(%__MODULE__{} = sk, trait, strength, evidence \\ nil) do
    strength = clamp_float(strength)

    entry = %{
      trait: trait,
      strength: strength,
      evidence: evidence,
      added_at: DateTime.utc_now()
    }

    # Replace existing trait or add new
    traits =
      sk.personality_traits
      |> Enum.reject(&(&1.trait == trait))
      |> List.insert_at(0, entry)

    %{sk | personality_traits: traits}
  end

  @doc """
  Add a value to the agent's self-knowledge.

  Importance should be a float between 0.0 and 1.0.

  ## Examples

      sk = SelfKnowledge.add_value(sk, :honesty, 0.95)
      sk = SelfKnowledge.add_value(sk, :helpfulness, 0.9, "core purpose")
  """
  @spec add_value(t(), atom(), float(), String.t() | nil) :: t()
  def add_value(%__MODULE__{} = sk, value, importance, evidence \\ nil) do
    importance = clamp_float(importance)

    entry = %{
      value: value,
      importance: importance,
      evidence: evidence,
      added_at: DateTime.utc_now()
    }

    # Replace existing value or add new
    values =
      sk.values
      |> Enum.reject(&(&1.value == value))
      |> List.insert_at(0, entry)

    %{sk | values: values}
  end

  @doc """
  Add a preference to the agent's self-knowledge.

  ## Examples

      sk = SelfKnowledge.add_preference(sk, :concise_responses, 0.8)
  """
  @spec add_preference(t(), atom() | String.t(), float()) :: t()
  def add_preference(%__MODULE__{} = sk, preference, strength) do
    strength = clamp_float(strength)

    entry = %{
      preference: preference,
      strength: strength,
      added_at: DateTime.utc_now()
    }

    # Replace existing preference or add new
    preferences =
      sk.preferences
      |> Enum.reject(&(&1.preference == preference))
      |> List.insert_at(0, entry)

    %{sk | preferences: preferences}
  end

  # ============================================================================
  # Growth Tracking
  # ============================================================================

  @doc """
  Record a growth event in the agent's development.

  ## Examples

      sk = SelfKnowledge.record_growth(sk, :debugging, "improved from 0.6 to 0.8 proficiency")
  """
  @spec record_growth(t(), atom() | String.t(), String.t()) :: t()
  def record_growth(%__MODULE__{} = sk, area, change) do
    entry = %{
      area: area,
      change: change,
      timestamp: DateTime.utc_now()
    }

    # Keep last 100 growth entries
    growth_log =
      [entry | sk.growth_log]
      |> Enum.take(100)

    %{sk | growth_log: growth_log}
  end

  @doc """
  Get a summary of growth in different areas.

  Returns a map of area => list of changes.
  """
  @spec growth_summary(t()) :: map()
  def growth_summary(%__MODULE__{} = sk) do
    Enum.group_by(sk.growth_log, & &1.area, & &1.change)
  end

  # ============================================================================
  # Self-Query
  # ============================================================================

  @doc """
  Query a specific aspect of self-knowledge.

  ## Aspects

  - `:memory_system` - Understanding of memory architecture
  - `:identity` - Core identity (traits + values)
  - `:tools` - Tool capabilities
  - `:cognition` - Cognitive patterns and preferences
  - `:capabilities` - Skills and proficiency
  - `:all` - Everything

  ## Examples

      identity = SelfKnowledge.query(sk, :identity)
  """
  @spec query(t(), atom()) :: map()
  def query(%__MODULE__{} = sk, aspect) do
    case aspect do
      :memory_system ->
        Map.get(sk.architecture, :memory_system, %{})

      :identity ->
        %{
          agent_id: sk.agent_id,
          traits: Enum.map(sk.personality_traits, &{&1.trait, &1.strength}),
          values: Enum.map(sk.values, &{&1.value, &1.importance})
        }

      :tools ->
        Map.get(sk.architecture, :tools, %{})

      :cognition ->
        %{
          preferences: Enum.map(sk.preferences, &{&1.preference, &1.strength}),
          cognitive_patterns: Map.get(sk.architecture, :cognitive_patterns, %{})
        }

      :capabilities ->
        %{
          capabilities: Enum.map(sk.capabilities, &{&1.name, &1.proficiency}),
          growth_areas: growth_summary(sk)
        }

      :all ->
        %{
          agent_id: sk.agent_id,
          capabilities: sk.capabilities,
          personality_traits: sk.personality_traits,
          values: sk.values,
          preferences: sk.preferences,
          growth_log: sk.growth_log,
          architecture: sk.architecture,
          version: sk.version
        }

      _ ->
        %{}
    end
  end

  # ============================================================================
  # Versioning
  # ============================================================================

  @doc """
  Snapshot the current state for potential rollback.

  Should be called before significant changes to enable rollback.
  Keeps up to 10 versions.

  ## Examples

      sk = SelfKnowledge.snapshot(sk)
      # Make changes...
      sk = SelfKnowledge.rollback(sk)  # Restore previous state
  """
  @spec snapshot(t()) :: t()
  def snapshot(%__MODULE__{} = sk) do
    # Create a snapshot of current state (without version_history to avoid nesting)
    snapshot_data = %{
      capabilities: sk.capabilities,
      personality_traits: sk.personality_traits,
      values: sk.values,
      preferences: sk.preferences,
      growth_log: sk.growth_log,
      architecture: sk.architecture,
      version: sk.version,
      snapshotted_at: DateTime.utc_now()
    }

    history =
      [snapshot_data | sk.version_history]
      |> Enum.take(@max_version_history)

    %{sk | version_history: history, version: sk.version + 1}
  end

  @doc """
  Rollback to a previous version.

  ## Options

  - `:previous` (default) - Roll back to the most recent snapshot
  - Integer - Roll back to a specific version

  ## Examples

      sk = SelfKnowledge.rollback(sk)
      sk = SelfKnowledge.rollback(sk, 3)
  """
  @spec rollback(t(), :previous | pos_integer()) :: t() | {:error, :no_history}
  def rollback(%__MODULE__{version_history: []}, _version) do
    {:error, :no_history}
  end

  def rollback(%__MODULE__{} = sk, :previous) do
    [previous | rest] = sk.version_history

    %{
      sk
      | capabilities: previous.capabilities,
        personality_traits: previous.personality_traits,
        values: previous.values,
        preferences: previous.preferences,
        growth_log: previous.growth_log,
        architecture: previous.architecture,
        version: previous.version,
        version_history: rest
    }
  end

  def rollback(%__MODULE__{} = sk, target_version) when is_integer(target_version) do
    case Enum.find(sk.version_history, &(&1.version == target_version)) do
      nil ->
        {:error, :version_not_found}

      snapshot ->
        # Remove versions newer than target
        remaining_history =
          Enum.drop_while(sk.version_history, &(&1.version > target_version))

        %{
          sk
          | capabilities: snapshot.capabilities,
            personality_traits: snapshot.personality_traits,
            values: snapshot.values,
            preferences: snapshot.preferences,
            growth_log: snapshot.growth_log,
            architecture: snapshot.architecture,
            version: snapshot.version,
            version_history: remaining_history
        }
    end
  end

  # ============================================================================
  # Serialization
  # ============================================================================

  @doc """
  Generate a human-readable summary of self-knowledge.

  ## Examples

      summary = SelfKnowledge.summarize(sk)
  """
  @spec summarize(t()) :: String.t()
  def summarize(%__MODULE__{} = sk) do
    parts = ["Agent #{sk.agent_id} (version #{sk.version})"]

    parts =
      if sk.capabilities != [] do
        cap_summary =
          sk.capabilities
          |> Enum.take(5)
          |> Enum.map_join(", ", fn c -> "#{c.name} (#{Float.round(c.proficiency * 100, 0)}%)" end)

        ["Capabilities: #{cap_summary}" | parts]
      else
        parts
      end

    parts =
      if sk.personality_traits != [] do
        trait_summary =
          sk.personality_traits
          |> Enum.take(5)
          |> Enum.map_join(", ", fn t -> "#{t.trait}" end)

        ["Traits: #{trait_summary}" | parts]
      else
        parts
      end

    parts =
      if sk.values != [] do
        value_summary =
          sk.values
          |> Enum.take(5)
          |> Enum.map_join(", ", fn v -> "#{v.value}" end)

        ["Values: #{value_summary}" | parts]
      else
        parts
      end

    parts =
      if sk.growth_log != [] do
        ["Growth entries: #{length(sk.growth_log)}" | parts]
      else
        parts
      end

    parts
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  @doc """
  Serialize self-knowledge to a map for persistence.

  ## Examples

      data = SelfKnowledge.serialize(sk)
      {:ok, json} = Jason.encode(data)
  """
  @spec serialize(t()) :: map()
  def serialize(%__MODULE__{} = sk) do
    %{
      agent_id: sk.agent_id,
      capabilities:
        Enum.map(sk.capabilities, fn c ->
          %{
            name: c.name,
            proficiency: c.proficiency,
            evidence: c.evidence,
            added_at: DateTime.to_iso8601(c.added_at)
          }
        end),
      personality_traits:
        Enum.map(sk.personality_traits, fn t ->
          %{
            trait: to_string(t.trait),
            strength: t.strength,
            evidence: t.evidence,
            added_at: DateTime.to_iso8601(t.added_at)
          }
        end),
      values:
        Enum.map(sk.values, fn v ->
          %{
            value: to_string(v.value),
            importance: v.importance,
            evidence: v.evidence,
            added_at: DateTime.to_iso8601(v.added_at)
          }
        end),
      preferences:
        Enum.map(sk.preferences, fn p ->
          %{
            preference: serialize_preference_key(p.preference),
            strength: p.strength,
            added_at: DateTime.to_iso8601(p.added_at)
          }
        end),
      growth_log:
        Enum.map(sk.growth_log, fn g ->
          %{
            area: serialize_preference_key(g.area),
            change: g.change,
            timestamp: DateTime.to_iso8601(g.timestamp)
          }
        end),
      architecture: sk.architecture,
      version: sk.version,
      version_history:
        Enum.map(sk.version_history, fn h ->
          %{
            version: h.version,
            snapshotted_at: DateTime.to_iso8601(h.snapshotted_at)
          }
        end)
    }
  end

  @doc """
  Deserialize a map back to a SelfKnowledge struct.

  Uses SafeAtom for atom conversion to prevent atom exhaustion.

  ## Examples

      sk = SelfKnowledge.deserialize(data)
  """
  @spec deserialize(map()) :: t()
  def deserialize(data) do
    %__MODULE__{
      agent_id: get_field(data, "agent_id", nil),
      capabilities: deserialize_capabilities(get_field(data, "capabilities", [])),
      personality_traits: deserialize_personality_traits(get_field(data, "personality_traits", [])),
      values: deserialize_values(get_field(data, "values", [])),
      preferences: deserialize_preferences_list(get_field(data, "preferences", [])),
      growth_log: deserialize_growth_log(get_field(data, "growth_log", [])),
      architecture: get_field(data, "architecture", %{}),
      version: get_field(data, "version", 1),
      version_history: []
    }
  end

  # ============================================================================
  # Deserialization Helpers
  # ============================================================================

  defp get_field(data, string_key, default) do
    case data[string_key] do
      nil ->
        atom_key = String.to_existing_atom(string_key)
        data[atom_key] || default

      value ->
        value
    end
  end

  defp deserialize_capabilities(items) do
    Enum.map(items, fn c ->
      %{
        name: get_field(c, "name", nil),
        proficiency: get_field(c, "proficiency", 0) * 1.0,
        evidence: get_field(c, "evidence", nil),
        added_at: parse_datetime(get_field(c, "added_at", nil))
      }
    end)
  end

  defp deserialize_personality_traits(items) do
    Enum.map(items, fn t ->
      trait_str = get_field(t, "trait", nil)

      %{
        trait: safe_atom_or_new(trait_str),
        strength: get_field(t, "strength", 0) * 1.0,
        evidence: get_field(t, "evidence", nil),
        added_at: parse_datetime(get_field(t, "added_at", nil))
      }
    end)
  end

  defp deserialize_values(items) do
    Enum.map(items, fn v ->
      value_str = get_field(v, "value", nil)

      %{
        value: safe_atom_or_new(value_str),
        importance: get_field(v, "importance", 0) * 1.0,
        evidence: get_field(v, "evidence", nil),
        added_at: parse_datetime(get_field(v, "added_at", nil))
      }
    end)
  end

  defp deserialize_preferences_list(items) do
    Enum.map(items, fn p ->
      pref = get_field(p, "preference", nil)

      %{
        preference: deserialize_preference_key(pref),
        strength: get_field(p, "strength", 0) * 1.0,
        added_at: parse_datetime(get_field(p, "added_at", nil))
      }
    end)
  end

  defp deserialize_growth_log(items) do
    Enum.map(items, fn g ->
      area = get_field(g, "area", nil)

      %{
        area: deserialize_preference_key(area),
        change: get_field(g, "change", nil),
        timestamp: parse_datetime(get_field(g, "timestamp", nil))
      }
    end)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp clamp_float(value) when is_number(value) do
    value
    |> max(0.0)
    |> min(1.0)
    |> Float.round(3)
  end

  defp maybe_update(map, _key, nil), do: map

  defp maybe_update(map, :proficiency, value) do
    Map.put(map, :proficiency, clamp_float(value))
  end

  defp maybe_update(map, key, value), do: Map.put(map, key, value)

  defp serialize_preference_key(key) when is_atom(key), do: to_string(key)
  defp serialize_preference_key(key) when is_binary(key), do: key

  defp deserialize_preference_key(key) when is_atom(key), do: key

  defp deserialize_preference_key(key) when is_binary(key) do
    case SafeAtom.to_existing(key) do
      {:ok, atom} -> atom
      {:error, _} -> key
    end
  end

  # L4: Use to_existing_atom with string fallback instead of unbounded String.to_atom.
  # Traits/values are controlled by the memory system's own serialized output,
  # but we avoid unbounded atom creation by falling back to the string form
  # when the atom doesn't already exist.
  defp safe_atom_or_new(str) when is_binary(str) do
    case SafeAtom.to_existing(str) do
      {:ok, atom} -> atom
      {:error, _} -> str
    end
  end

  defp safe_atom_or_new(atom) when is_atom(atom), do: atom

  defp parse_datetime(%DateTime{} = dt), do: dt
  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end
end
