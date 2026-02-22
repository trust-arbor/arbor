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
  @similarity_threshold 0.6
  @max_entries_per_category 15
  @max_concept_words 4
  @embedding_similarity_threshold 0.75

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
    {normalized, original_as_evidence} = normalize_entry_name(name)
    evidence = evidence || original_as_evidence

    case find_similar(sk.capabilities, :name, normalized) do
      {:similar, existing} ->
        # Merge: keep existing name, take max proficiency, update if newer
        capabilities =
          Enum.map(sk.capabilities, fn cap ->
            if cap == existing do
              %{
                cap
                | proficiency: max(cap.proficiency, proficiency),
                  added_at: DateTime.utc_now()
              }
              |> maybe_update(:evidence, evidence)
            else
              cap
            end
          end)

        %{sk | capabilities: capabilities}

      :none ->
        capability = %{
          name: normalized,
          proficiency: proficiency,
          evidence: evidence,
          added_at: DateTime.utc_now()
        }

        # Replace existing capability with exact same name or add new
        capabilities =
          sk.capabilities
          |> Enum.reject(&(&1.name == normalized))
          |> List.insert_at(0, capability)
          |> enforce_cap(:proficiency)

        %{sk | capabilities: capabilities}
    end
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
    {normalized, original_as_evidence} = normalize_entry_name(trait)
    evidence = evidence || original_as_evidence

    case find_similar(sk.personality_traits, :trait, normalized) do
      {:similar, existing} ->
        traits =
          Enum.map(sk.personality_traits, fn t ->
            if t == existing do
              %{t | strength: max(t.strength, strength), added_at: DateTime.utc_now()}
              |> maybe_update(:evidence, evidence)
            else
              t
            end
          end)

        %{sk | personality_traits: traits}

      :none ->
        entry = %{
          trait: normalized,
          strength: strength,
          evidence: evidence,
          added_at: DateTime.utc_now()
        }

        traits =
          sk.personality_traits
          |> Enum.reject(&(&1.trait == normalized))
          |> List.insert_at(0, entry)
          |> enforce_cap(:strength)

        %{sk | personality_traits: traits}
    end
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
    {normalized, original_as_evidence} = normalize_entry_name(value)
    evidence = evidence || original_as_evidence

    case find_similar(sk.values, :value, normalized) do
      {:similar, existing} ->
        values =
          Enum.map(sk.values, fn v ->
            if v == existing do
              %{v | importance: max(v.importance, importance), added_at: DateTime.utc_now()}
              |> maybe_update(:evidence, evidence)
            else
              v
            end
          end)

        %{sk | values: values}

      :none ->
        entry = %{
          value: normalized,
          importance: importance,
          evidence: evidence,
          added_at: DateTime.utc_now()
        }

        values =
          sk.values
          |> Enum.reject(&(&1.value == normalized))
          |> List.insert_at(0, entry)
          |> enforce_cap(:importance)

        %{sk | values: values}
    end
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
  # Deduplication
  # ============================================================================

  @doc """
  Remove semantically duplicate entries from all self-knowledge categories.

  Uses Jaccard word-set similarity to merge near-duplicate traits, values,
  and capabilities. Keeps the entry with the highest strength/proficiency/importance,
  merges evidence from duplicates.

  Useful for cleaning up accumulated duplicates from repeated heartbeat cycles.

  ## Options

  - `:mode` - `:word_set` (default, fast) or `:embedding` (uses Ollama vectors)
  - `:embedding_threshold` - Cosine similarity threshold for embedding mode (default 0.75)

  ## Examples

      sk = SelfKnowledge.deduplicate(sk)
      sk = SelfKnowledge.deduplicate(sk, mode: :embedding)
  """
  @spec deduplicate(t(), keyword()) :: t()
  def deduplicate(%__MODULE__{} = sk, opts \\ []) do
    mode = Keyword.get(opts, :mode, :word_set)

    case mode do
      :embedding ->
        deduplicate_with_embeddings(sk, opts)

      _ ->
        %{
          sk
          | capabilities: deduplicate_list(sk.capabilities, :name, :proficiency),
            personality_traits: deduplicate_list(sk.personality_traits, :trait, :strength),
            values: deduplicate_list(sk.values, :value, :importance)
        }
    end
  end

  defp deduplicate_list(entries, key_field, score_field) do
    Enum.reduce(entries, [], fn entry, acc ->
      entry_text = to_string(Map.get(entry, key_field))
      entry_stemmed = tokenize_stemmed(entry_text)

      case find_dedup_match(acc, key_field, entry_text, entry_stemmed) do
        nil ->
          acc ++ [entry]

        idx ->
          existing = Enum.at(acc, idx)

          merged =
            if Map.get(entry, score_field) > Map.get(existing, score_field) do
              %{existing | score_field => Map.get(entry, score_field)}
            else
              existing
            end

          List.replace_at(acc, idx, merged)
      end
    end)
  end

  defp find_dedup_match(acc, key_field, entry_text, entry_stemmed) do
    Enum.find_index(acc, fn existing ->
      existing_text = to_string(Map.get(existing, key_field))
      existing_stemmed = tokenize_stemmed(existing_text)
      entries_similar?(existing_text, entry_text, existing_stemmed, entry_stemmed)
    end)
  end

  defp entries_similar?(existing_text, new_text, existing_stemmed, new_stemmed) do
    raw_sim = text_similarity(existing_text, new_text)
    stem_sim = stemmed_similarity(existing_stemmed, new_stemmed)
    both_short = MapSet.size(existing_stemmed) <= 6 and MapSet.size(new_stemmed) <= 6
    stem_threshold = if both_short, do: 0.5, else: @similarity_threshold

    raw_sim >= @similarity_threshold or stem_sim >= stem_threshold
  end

  defp deduplicate_with_embeddings(%__MODULE__{} = sk, opts) do
    threshold = Keyword.get(opts, :embedding_threshold, @embedding_similarity_threshold)

    case generate_embeddings_batch(sk) do
      {:ok, %{trait_embs: trait_embs, value_embs: value_embs, cap_embs: cap_embs}} ->
        %{
          sk
          | personality_traits:
              deduplicate_list_with_embeddings(
                sk.personality_traits,
                trait_embs,
                :trait,
                :strength,
                threshold
              ),
            values:
              deduplicate_list_with_embeddings(
                sk.values,
                value_embs,
                :value,
                :importance,
                threshold
              ),
            capabilities:
              deduplicate_list_with_embeddings(
                sk.capabilities,
                cap_embs,
                :name,
                :proficiency,
                threshold
              )
        }

      {:error, _reason} ->
        # Fall back to word-set dedup when embeddings unavailable
        deduplicate(sk, mode: :word_set)
    end
  end

  defp deduplicate_list_with_embeddings(entries, embeddings, key_field, score_field, threshold) do
    entries_with_embs = Enum.zip(entries, embeddings)

    {kept, _kept_embs} =
      Enum.reduce(entries_with_embs, {[], []}, fn {entry, emb}, {acc_entries, acc_embs} ->
        entry_text = to_string(Map.get(entry, key_field))

        # Check word-set similarity first (free)
        word_match_idx =
          Enum.find_index(acc_entries, fn existing ->
            text_similarity(to_string(Map.get(existing, key_field)), entry_text) >=
              @similarity_threshold
          end)

        # Check embedding similarity if word-set didn't match
        match_idx =
          word_match_idx ||
            Enum.find_index(acc_embs, fn kept_emb ->
              cosine_similarity(kept_emb, emb) >= threshold
            end)

        case match_idx do
          nil ->
            {acc_entries ++ [entry], acc_embs ++ [emb]}

          idx ->
            existing = Enum.at(acc_entries, idx)

            merged =
              if Map.get(entry, score_field) > Map.get(existing, score_field) do
                %{existing | score_field => Map.get(entry, score_field)}
              else
                existing
              end

            {List.replace_at(acc_entries, idx, merged), acc_embs}
        end
      end)

    kept
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
      personality_traits:
        deserialize_personality_traits(get_field(data, "personality_traits", [])),
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

  # ============================================================================
  # Semantic Similarity
  # ============================================================================

  @doc """
  Compute semantic similarity between two strings based on word tokens.

  Uses the maximum of Jaccard similarity and containment similarity:
  - Jaccard = |A ∩ B| / |A ∪ B| (overall word overlap)
  - Containment = |A ∩ B| / min(|A|, |B|) (shorter phrase contained in longer)

  Containment catches "same phrase plus extra words" that Jaccard misses.
  Returns a float between 0.0 (no overlap) and 1.0 (identical/fully contained).

  ## Examples

      iex> SelfKnowledge.text_similarity("methodical approach to knowledge", "methodical approach to knowledge management")
      0.8
  """
  @spec text_similarity(String.t(), String.t()) :: float()
  def text_similarity(a, b) do
    set_a = tokenize(a)
    set_b = tokenize(b)

    intersection_size = MapSet.intersection(set_a, set_b) |> MapSet.size()
    union_size = MapSet.union(set_a, set_b) |> MapSet.size()
    min_size = min(MapSet.size(set_a), MapSet.size(set_b))

    jaccard = if union_size == 0, do: 1.0, else: intersection_size / union_size
    containment = if min_size == 0, do: 1.0, else: intersection_size / min_size

    max(jaccard, containment)
  end

  @stop_words MapSet.new(
                ~w(a an the is are was were be been being in on at to for of and or but with by from as i my its)
              )

  defp tokenize(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&MapSet.member?(@stop_words, &1))
    |> MapSet.new()
  end

  defp find_similar(entries, key_field, new_key) do
    new_text = to_string(new_key)
    new_stemmed = tokenize_stemmed(new_text)

    Enum.find_value(entries, :none, fn entry ->
      existing_text = to_string(Map.get(entry, key_field))

      # Standard word-bag similarity (original tokenizer)
      raw_sim = text_similarity(existing_text, new_text)

      # Stemmed + filler-stripped similarity for verbose trait names.
      # Use a lower threshold for short concept keys (≤6 tokens) because
      # sharing 2 of 4 concept words (0.5) is strong evidence of duplication.
      existing_stemmed = tokenize_stemmed(existing_text)
      stemmed_sim = stemmed_similarity(existing_stemmed, new_stemmed)

      both_short = MapSet.size(existing_stemmed) <= 6 and MapSet.size(new_stemmed) <= 6
      stemmed_threshold = if both_short, do: 0.5, else: @similarity_threshold

      if raw_sim >= @similarity_threshold or stemmed_sim >= stemmed_threshold do
        {:similar, entry}
      end
    end)
  end

  defp stemmed_similarity(set_a, set_b) do
    intersection_size = MapSet.intersection(set_a, set_b) |> MapSet.size()
    union_size = MapSet.union(set_a, set_b) |> MapSet.size()
    min_size = min(MapSet.size(set_a), MapSet.size(set_b))

    jaccard = if union_size == 0, do: 1.0, else: intersection_size / union_size
    containment = if min_size == 0, do: 1.0, else: intersection_size / min_size
    max(jaccard, containment)
  end

  # Normalize verbose entry names to short concept keys (max @max_concept_words).
  # LLMs generate trait names like "prioritizes_systematic_investigation_over_quick_fixes"
  # which defeat Jaccard dedup. This extracts core concepts and stores the full
  # description as evidence.
  #
  # Returns {normalized_name, original_as_evidence_or_nil}
  @entry_filler_words MapSet.new(~w(
    approach approaches demonstrates demonstrate demonstrating shown shows show
    strong strongly maintaining maintains maintain currently constraints constrained
    despite apparent faced working memory system systems operations operational
    issues issue potential workflows workflow processes process during
    establishing established establishing establish exhibited exhibiting
    even particularly especially also
  ))

  defp normalize_entry_name(name) when is_atom(name) do
    str = Atom.to_string(name)
    {normalized, evidence} = normalize_entry_name(str)

    case SafeAtom.to_existing(normalized) do
      {:ok, atom} -> {atom, evidence}
      {:error, _} -> {normalized, evidence}
    end
  end

  defp normalize_entry_name(name) when is_binary(name) do
    words =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s]/, " ")
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reject(fn w ->
        String.length(w) < 3 or MapSet.member?(@stop_words, w) or
          MapSet.member?(@entry_filler_words, w)
      end)

    if length(words) <= @max_concept_words do
      # Already short enough, no normalization needed
      {name, nil}
    else
      normalized = words |> Enum.take(@max_concept_words) |> Enum.join("_")
      {normalized, "Original: #{name}"}
    end
  end

  # Naive English stemmer used for similarity comparison (not stored names).
  # Applies suffixes recursively until stable:
  # "proactively" -> "proactive" -> "proact"
  # "identifies" -> "identifi" -> applies again -> "identif"
  @stem_suffixes ~w(ation tion sion ment ness ity ies tics ting sing zing ing ates izes ence ance ous ive ful les es ed ly al er or en s)
  defp naive_stem(word), do: naive_stem_pass(word, word)

  defp naive_stem_pass(word, _prev) do
    result =
      Enum.reduce_while(@stem_suffixes, word, fn suffix, acc ->
        base = String.replace_suffix(acc, suffix, "")
        if base != acc and String.length(base) >= 3, do: {:halt, base}, else: {:cont, acc}
      end)

    if result == word, do: word, else: naive_stem_pass(result, word)
  end

  # Tokenize with stemming for similarity comparison
  defp tokenize_stemmed(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(fn w ->
      MapSet.member?(@stop_words, w) or MapSet.member?(@entry_filler_words, w)
    end)
    |> Enum.map(&naive_stem/1)
    |> Enum.reject(fn w -> String.length(w) < 3 end)
    |> MapSet.new()
  end

  # Enforce max entries per category. Keeps the highest-scored entries.
  defp enforce_cap(entries, score_field) do
    if length(entries) > @max_entries_per_category do
      entries
      |> Enum.sort_by(&(Map.get(&1, score_field) || 0), :desc)
      |> Enum.take(@max_entries_per_category)
    else
      entries
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: dt
  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  # ============================================================================
  # Embedding-Based Similarity
  # ============================================================================

  @doc """
  Check if embedding-based dedup is available.

  Requires a running Ollama instance with an embedding model.
  Uses the model configured in `:arbor_memory, :embedding_model`
  or defaults to "nomic-embed-text:latest".

  ## Examples

      true = SelfKnowledge.embeddings_available?()
  """
  @spec embeddings_available?() :: boolean()
  def embeddings_available? do
    url = String.to_charlist(ollama_base_url() <> "/api/tags")
    opts = [timeout: 3000, connect_timeout: 2000]

    case :httpc.request(:get, {url, []}, opts, []) do
      {:ok, {{_, 200, _}, _, _}} -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc """
  Compute cosine similarity between two embedding vectors.

  Returns a float between -1.0 (opposite) and 1.0 (identical).

  ## Examples

      sim = SelfKnowledge.cosine_similarity([0.1, 0.2], [0.1, 0.2])
      # => 1.0
  """
  @spec cosine_similarity([float()], [float()]) :: float()
  def cosine_similarity(vec_a, vec_b) do
    dot = Enum.zip(vec_a, vec_b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    norm_a = :math.sqrt(Enum.reduce(vec_a, 0.0, fn x, acc -> acc + x * x end))
    norm_b = :math.sqrt(Enum.reduce(vec_b, 0.0, fn x, acc -> acc + x * x end))

    if norm_a == 0.0 or norm_b == 0.0, do: 0.0, else: dot / (norm_a * norm_b)
  end

  @doc """
  Generate embeddings for a list of texts via Ollama.

  Returns `{:ok, [embedding]}` or `{:error, reason}`.

  ## Examples

      {:ok, embeddings} = SelfKnowledge.generate_embeddings(["hello", "world"])
  """
  @spec generate_embeddings([String.t()]) :: {:ok, [[float()]]} | {:error, term()}
  def generate_embeddings([]), do: {:ok, []}

  def generate_embeddings(texts) when is_list(texts) do
    model = embedding_model()
    url = ollama_embeddings_url()
    body = Jason.encode!(%{model: model, input: texts})

    case :httpc.request(
           :post,
           {String.to_charlist(url), [{~c"content-type", ~c"application/json"}],
            ~c"application/json", body},
           [timeout: 30_000, connect_timeout: 5_000],
           []
         ) do
      {:ok, {{_, 200, _}, _, resp_body}} ->
        %{"data" => emb_data} = Jason.decode!(resp_body)
        {:ok, Enum.map(emb_data, & &1["embedding"])}

      {:ok, {{_, status, _}, _, resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp generate_embeddings_batch(%__MODULE__{} = sk) do
    trait_texts = Enum.map(sk.personality_traits, &to_string(&1.trait))
    value_texts = Enum.map(sk.values, &to_string(&1.value))
    cap_texts = Enum.map(sk.capabilities, &to_string(&1.name))

    all_texts = trait_texts ++ value_texts ++ cap_texts

    if all_texts == [] do
      {:ok, %{trait_embs: [], value_embs: [], cap_embs: []}}
    else
      case generate_embeddings(all_texts) do
        {:ok, all_embs} ->
          trait_count = length(trait_texts)
          value_count = length(value_texts)

          trait_embs = Enum.slice(all_embs, 0, trait_count)
          value_embs = Enum.slice(all_embs, trait_count, value_count)
          cap_embs = Enum.slice(all_embs, trait_count + value_count, length(cap_texts))

          {:ok, %{trait_embs: trait_embs, value_embs: value_embs, cap_embs: cap_embs}}

        error ->
          error
      end
    end
  end

  defp ollama_base_url do
    Application.get_env(:arbor_memory, :ollama_url, "http://localhost:11434")
  end

  defp ollama_embeddings_url do
    ollama_base_url() <> "/v1/embeddings"
  end

  defp embedding_model do
    Application.get_env(:arbor_memory, :embedding_model, "nomic-embed-text:latest")
  end
end
