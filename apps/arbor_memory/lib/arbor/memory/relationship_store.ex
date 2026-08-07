defmodule Arbor.Memory.RelationshipStore do
  @moduledoc """
  Memory-owned relationship adapter.

  Converts `Arbor.Memory.Relationship` structs to/from closed plain maps and
  delegates durable effects to the public `Arbor.Persistence` facade. Tracks
  access, emits signals, and records events. Does not reach into Persistence
  internals (repo, queries, or relationship schema modules).
  """

  alias Arbor.Memory.{Events, Relationship, Signals}
  alias Arbor.Persistence

  require Logger

  # ============================================================================
  # CRUD Operations
  # ============================================================================

  @doc """
  Store a relationship for an agent.

  If a relationship with the same name already exists, it will be updated.
  Returns the saved relationship with any generated fields (like id).
  """
  @spec put(String.t(), Relationship.t()) :: {:ok, Relationship.t()} | {:error, term()}
  def put(agent_id, %Relationship{} = relationship) do
    attrs = relationship_to_attrs(relationship)

    case Persistence.put_relationship(agent_id, attrs) do
      {:ok, plain} ->
        {:ok, attrs_to_relationship(plain)}

      {:error, reason} ->
        Logger.warning("Failed to save relationship: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get a relationship by ID for an agent.
  """
  @spec get(String.t(), String.t()) :: {:ok, Relationship.t()} | {:error, :not_found}
  def get(agent_id, relationship_id) do
    case Persistence.fetch_relationship(agent_id, relationship_id) do
      {:ok, plain} -> {:ok, attrs_to_relationship(plain)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get a relationship by name for an agent.
  """
  @spec get_by_name(String.t(), String.t()) :: {:ok, Relationship.t()} | {:error, :not_found}
  def get_by_name(agent_id, name) do
    case Persistence.fetch_relationship_by_name(agent_id, name) do
      {:ok, plain} -> {:ok, attrs_to_relationship(plain)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  List relationships for an agent.

  ## Options

  - `:sort_by` - Sort by field: `:salience` (default), `:last_interaction`, `:name`, `:access_count`
  - `:sort_dir` - Sort direction: `:desc` (default), `:asc`
  - `:limit` - Maximum relationships to return (default: 100 via Persistence; max 1000)
  """
  @spec list(String.t(), keyword()) :: {:ok, [Relationship.t()]} | {:error, term()}
  def list(agent_id, opts \\ []) do
    case Persistence.list_relationships(agent_id, opts) do
      {:ok, plains} -> {:ok, Enum.map(plains, &attrs_to_relationship/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delete a relationship by ID.
  """
  @spec delete(String.t(), String.t()) :: :ok | {:error, :not_found}
  def delete(agent_id, relationship_id) do
    Persistence.delete_relationship(agent_id, relationship_id)
  end

  @doc """
  Update a relationship by ID.

  Accepts a map of changes to apply to the relationship.
  """
  @spec update(String.t(), String.t(), map()) :: {:ok, Relationship.t()} | {:error, term()}
  def update(agent_id, relationship_id, changes) when is_map(changes) do
    attrs = prepare_update_attrs(changes)

    case Persistence.update_relationship(agent_id, relationship_id, attrs) do
      {:ok, plain} -> {:ok, attrs_to_relationship(plain)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get the primary relationship for an agent (highest salience).
  """
  @spec get_primary(String.t()) :: {:ok, Relationship.t()} | {:error, :not_found}
  def get_primary(agent_id) do
    case Persistence.fetch_primary_relationship(agent_id) do
      {:ok, plain} -> {:ok, attrs_to_relationship(plain)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Touch a relationship to update access tracking.

  Increments access_count and updates last_interaction timestamp.
  """
  @spec touch(String.t(), String.t()) :: {:ok, Relationship.t()} | {:error, term()}
  def touch(agent_id, relationship_id) do
    case Persistence.touch_relationship(agent_id, relationship_id) do
      {:ok, plain} -> {:ok, attrs_to_relationship(plain)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Count relationships for an agent.
  """
  @spec count(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(agent_id) do
    Persistence.count_relationships(agent_id)
  end

  @doc """
  Idempotently delete every relationship for exactly one agent.

  Content-only: does not delete provenance, identity, profile, events, or any
  other Memory domain. Precondition for C3I coordinators: the future agent
  mutation gate must be closed and drained before invoking this primitive.
  This module does not implement or check that gate.
  """
  @spec delete_all(String.t()) :: :ok | {:error, term()}
  def delete_all(agent_id) do
    Persistence.delete_all_relationships(agent_id)
  end

  @doc """
  Authoritative absence check for an agent's relationship rows.
  """
  @spec absent?(String.t()) :: {:ok, true} | {:ok, false} | {:error, term()}
  def absent?(agent_id) do
    Persistence.relationships_absent?(agent_id)
  end

  # ============================================================================
  # Facade-Level Operations (with touch/signals/events)
  # ============================================================================

  @doc """
  Get a relationship by ID with access tracking and signal emission.
  """
  @spec get_with_tracking(String.t(), String.t()) ::
          {:ok, Relationship.t()} | {:error, :not_found}
  def get_with_tracking(agent_id, relationship_id) do
    case get(agent_id, relationship_id) do
      {:ok, rel} ->
        touch(agent_id, relationship_id)
        Signals.emit_relationship_accessed(agent_id, relationship_id)
        {:ok, rel}

      error ->
        error
    end
  end

  @doc """
  Get a relationship by name with access tracking and signal emission.
  """
  @spec get_by_name_with_tracking(String.t(), String.t()) ::
          {:ok, Relationship.t()} | {:error, :not_found}
  def get_by_name_with_tracking(agent_id, name) do
    case get_by_name(agent_id, name) do
      {:ok, rel} ->
        touch(agent_id, rel.id)
        Signals.emit_relationship_accessed(agent_id, rel.id)
        {:ok, rel}

      error ->
        error
    end
  end

  @doc """
  Get the primary relationship with access tracking and signal emission.
  """
  @spec get_primary_with_tracking(String.t()) ::
          {:ok, Relationship.t()} | {:error, :not_found}
  def get_primary_with_tracking(agent_id) do
    case get_primary(agent_id) do
      {:ok, rel} ->
        touch(agent_id, rel.id)
        Signals.emit_relationship_accessed(agent_id, rel.id)
        {:ok, rel}

      error ->
        error
    end
  end

  @doc """
  Save a relationship with signal/event emission for create vs update.

  Fail-closed on existence reads: only `{:error, :not_found}` is treated as a
  create. Any other read error (`:backend_failure`, `:indeterminate`, etc.) is
  returned without putting or emitting created/updated signals/events.
  """
  @spec save(String.t(), Relationship.t()) ::
          {:ok, Relationship.t()} | {:error, term()}
  def save(agent_id, %Relationship{} = relationship) do
    case get(agent_id, relationship.id) do
      {:ok, _} ->
        put_and_emit(agent_id, relationship, _is_new = false)

      {:error, :not_found} ->
        put_and_emit(agent_id, relationship, _is_new = true)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_and_emit(agent_id, relationship, is_new) do
    case put(agent_id, relationship) do
      {:ok, saved_rel} ->
        if is_new do
          Signals.emit_relationship_created(agent_id, saved_rel.id, saved_rel.name)
          Events.record_relationship_created(agent_id, saved_rel.id, saved_rel.name)
        else
          Signals.emit_relationship_updated(agent_id, saved_rel.id, %{action: :saved})
        end

        {:ok, saved_rel}

      error ->
        error
    end
  end

  @doc """
  Add a key moment to a relationship with signal/event emission.
  """
  @spec add_moment(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Relationship.t()} | {:error, term()}
  def add_moment(agent_id, relationship_id, summary, opts \\ []) do
    case get(agent_id, relationship_id) do
      {:ok, rel} ->
        updated_rel = Relationship.add_moment(rel, summary, opts)

        case put(agent_id, updated_rel) do
          {:ok, saved_rel} ->
            Signals.emit_moment_added(agent_id, relationship_id, summary)

            Events.record_relationship_moment(agent_id, relationship_id, %{
              summary: summary,
              emotional_markers: Keyword.get(opts, :emotional_markers, []),
              salience: Keyword.get(opts, :salience, 0.5)
            })

            {:ok, saved_rel}

          error ->
            error
        end

      error ->
        error
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp relationship_to_attrs(%Relationship{} = rel) do
    %{
      id: rel.id,
      name: rel.name,
      preferred_name: rel.preferred_name,
      background: rel.background,
      values: rel.values,
      connections: rel.connections,
      key_moments: Enum.map(rel.key_moments, &moment_to_attrs/1),
      relationship_dynamic: rel.relationship_dynamic,
      personal_details: rel.personal_details,
      current_focus: rel.current_focus,
      uncertainties: rel.uncertainties,
      first_encountered: rel.first_encountered,
      last_interaction: rel.last_interaction,
      salience: rel.salience,
      access_count: rel.access_count
    }
  end

  defp moment_to_attrs(moment) when is_map(moment) do
    markers = Map.get(moment, :emotional_markers) || Map.get(moment, "emotional_markers") || []

    %{
      summary: Map.get(moment, :summary) || Map.get(moment, "summary"),
      timestamp: Map.get(moment, :timestamp) || Map.get(moment, "timestamp"),
      emotional_markers: Enum.map(markers, &to_string/1),
      salience: Map.get(moment, :salience) || Map.get(moment, "salience") || 0.5
    }
  end

  defp attrs_to_relationship(plain) when is_map(plain) do
    Relationship.from_map(plain)
  end

  defp prepare_update_attrs(changes) when is_map(changes) do
    Map.new(changes, fn
      {:key_moments, moments} when is_list(moments) ->
        {:key_moments, Enum.map(moments, &moment_to_attrs/1)}

      {key, value} when is_atom(key) ->
        {key, value}

      other ->
        other
    end)
  end
end
