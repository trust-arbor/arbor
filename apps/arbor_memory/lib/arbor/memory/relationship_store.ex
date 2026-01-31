defmodule Arbor.Memory.RelationshipStore do
  @moduledoc """
  Postgres-backed persistence for relationships.

  No decay, no eviction — relationships are permanent fixtures that persist
  across sessions and restarts.

  ## Usage

      # Store a relationship
      rel = Relationship.new("Hysun", relationship_dynamic: "Collaborative partnership")
      {:ok, saved_rel} = RelationshipStore.put("agent_001", rel)

      # Retrieve by ID
      {:ok, rel} = RelationshipStore.get("agent_001", relationship_id)

      # Retrieve by name
      {:ok, rel} = RelationshipStore.get_by_name("agent_001", "Hysun")

      # List all relationships (sorted by salience)
      {:ok, rels} = RelationshipStore.list("agent_001", sort_by: :salience)

      # Update a relationship
      {:ok, rel} = RelationshipStore.update("agent_001", relationship_id, %{
        salience: 0.9
      })

      # Delete a relationship
      :ok = RelationshipStore.delete("agent_001", relationship_id)
  """

  alias Arbor.Memory.Relationship
  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.Relationship, as: RelationshipSchema

  import Ecto.Query

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
    attrs = RelationshipSchema.from_relationship(relationship, agent_id)

    changeset = RelationshipSchema.changeset(%RelationshipSchema{}, attrs)

    result =
      Repo.insert(changeset,
        on_conflict: {:replace_all_except, [:id, :agent_id, :inserted_at]},
        conflict_target: [:agent_id, :name],
        returning: true
      )

    case result do
      {:ok, schema} ->
        saved_rel = schema_to_relationship(schema)
        {:ok, saved_rel}

      {:error, changeset} ->
        Logger.warning("Failed to save relationship: #{inspect(changeset.errors)}")
        {:error, {:validation_failed, changeset.errors}}
    end
  end

  @doc """
  Get a relationship by ID for an agent.
  """
  @spec get(String.t(), String.t()) :: {:ok, Relationship.t()} | {:error, :not_found}
  def get(agent_id, relationship_id) do
    query =
      from r in RelationshipSchema,
        where: r.agent_id == ^agent_id and r.id == ^relationship_id

    case Repo.one(query) do
      nil -> {:error, :not_found}
      schema -> {:ok, schema_to_relationship(schema)}
    end
  end

  @doc """
  Get a relationship by name for an agent.
  """
  @spec get_by_name(String.t(), String.t()) :: {:ok, Relationship.t()} | {:error, :not_found}
  def get_by_name(agent_id, name) do
    query =
      from r in RelationshipSchema,
        where: r.agent_id == ^agent_id and r.name == ^name

    case Repo.one(query) do
      nil -> {:error, :not_found}
      schema -> {:ok, schema_to_relationship(schema)}
    end
  end

  @doc """
  List all relationships for an agent.

  ## Options

  - `:sort_by` - Sort by field: `:salience` (default), `:last_interaction`, `:name`, `:access_count`
  - `:sort_dir` - Sort direction: `:desc` (default), `:asc`
  - `:limit` - Maximum relationships to return (default: no limit)
  """
  @spec list(String.t(), keyword()) :: {:ok, [Relationship.t()]}
  def list(agent_id, opts \\ []) do
    sort_by = Keyword.get(opts, :sort_by, :salience)
    sort_dir = Keyword.get(opts, :sort_dir, :desc)
    limit = Keyword.get(opts, :limit)

    query =
      from r in RelationshipSchema,
        where: r.agent_id == ^agent_id

    query = apply_sort(query, sort_by, sort_dir)
    query = if limit, do: from(r in query, limit: ^limit), else: query

    schemas = Repo.all(query)
    relationships = Enum.map(schemas, &schema_to_relationship/1)

    {:ok, relationships}
  end

  @doc """
  Delete a relationship by ID.
  """
  @spec delete(String.t(), String.t()) :: :ok | {:error, :not_found}
  def delete(agent_id, relationship_id) do
    query =
      from r in RelationshipSchema,
        where: r.agent_id == ^agent_id and r.id == ^relationship_id

    case Repo.delete_all(query) do
      {0, _} -> {:error, :not_found}
      {_, _} -> :ok
    end
  end

  @doc """
  Update a relationship by ID.

  Accepts a map of changes to apply to the relationship.
  """
  @spec update(String.t(), String.t(), map()) :: {:ok, Relationship.t()} | {:error, term()}
  def update(agent_id, relationship_id, changes) when is_map(changes) do
    query =
      from r in RelationshipSchema,
        where: r.agent_id == ^agent_id and r.id == ^relationship_id

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      schema ->
        # Merge changes, being careful about nested structures
        attrs = prepare_update_attrs(changes)
        changeset = RelationshipSchema.changeset(schema, attrs)

        case Repo.update(changeset) do
          {:ok, updated_schema} ->
            {:ok, schema_to_relationship(updated_schema)}

          {:error, changeset} ->
            {:error, {:validation_failed, changeset.errors}}
        end
    end
  end

  @doc """
  Get the primary relationship for an agent (highest salience).
  """
  @spec get_primary(String.t()) :: {:ok, Relationship.t()} | {:error, :not_found}
  def get_primary(agent_id) do
    query =
      from r in RelationshipSchema,
        where: r.agent_id == ^agent_id,
        order_by: [desc: r.salience],
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      schema -> {:ok, schema_to_relationship(schema)}
    end
  end

  @doc """
  Touch a relationship to update access tracking.

  Increments access_count and updates last_interaction timestamp.
  """
  @spec touch(String.t(), String.t()) :: {:ok, Relationship.t()} | {:error, term()}
  def touch(agent_id, relationship_id) do
    now = DateTime.utc_now()

    query =
      from r in RelationshipSchema,
        where: r.agent_id == ^agent_id and r.id == ^relationship_id

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      schema ->
        changeset =
          RelationshipSchema.changeset(schema, %{
            last_interaction: now,
            access_count: schema.access_count + 1
          })

        case Repo.update(changeset) do
          {:ok, updated_schema} ->
            {:ok, schema_to_relationship(updated_schema)}

          {:error, changeset} ->
            {:error, {:validation_failed, changeset.errors}}
        end
    end
  end

  @doc """
  Count relationships for an agent.
  """
  @spec count(String.t()) :: {:ok, non_neg_integer()}
  def count(agent_id) do
    query =
      from r in RelationshipSchema,
        where: r.agent_id == ^agent_id,
        select: count(r.id)

    {:ok, Repo.one(query)}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp schema_to_relationship(schema) do
    data = RelationshipSchema.to_relationship(schema)

    %Relationship{
      id: data.id,
      name: data.name,
      preferred_name: data.preferred_name,
      background: data.background,
      values: data.values,
      connections: data.connections,
      key_moments: data.key_moments,
      relationship_dynamic: data.relationship_dynamic,
      personal_details: data.personal_details,
      current_focus: data.current_focus,
      uncertainties: data.uncertainties,
      first_encountered: data.first_encountered,
      last_interaction: data.last_interaction,
      salience: data.salience,
      access_count: data.access_count
    }
  end

  defp apply_sort(query, :salience, :desc), do: from(r in query, order_by: [desc: r.salience])
  defp apply_sort(query, :salience, :asc), do: from(r in query, order_by: [asc: r.salience])

  defp apply_sort(query, :last_interaction, :desc),
    do: from(r in query, order_by: [desc_nulls_last: r.last_interaction])

  defp apply_sort(query, :last_interaction, :asc),
    do: from(r in query, order_by: [asc_nulls_last: r.last_interaction])

  defp apply_sort(query, :name, :desc), do: from(r in query, order_by: [desc: r.name])
  defp apply_sort(query, :name, :asc), do: from(r in query, order_by: [asc: r.name])

  defp apply_sort(query, :access_count, :desc),
    do: from(r in query, order_by: [desc: r.access_count])

  defp apply_sort(query, :access_count, :asc),
    do: from(r in query, order_by: [asc: r.access_count])

  defp apply_sort(query, _, _), do: from(r in query, order_by: [desc: r.salience])

  # Prepare update attrs, converting relationship struct fields if needed
  defp prepare_update_attrs(changes) do
    changes
    |> Enum.map(fn
      {:key_moments, moments} when is_list(moments) ->
        {:key_moments, serialize_moments(moments)}

      other ->
        other
    end)
    |> Map.new()
  end

  defp serialize_moments(moments) do
    Enum.map(moments, &serialize_single_moment/1)
  end

  defp serialize_single_moment(moment) do
    timestamp_str = serialize_moment_timestamp(moment_field(moment, :timestamp))
    markers = moment_field(moment, :emotional_markers) || []

    %{
      "summary" => moment_field(moment, :summary),
      "timestamp" => timestamp_str,
      "emotional_markers" => Enum.map(markers, &to_string/1),
      "salience" => moment_field(moment, :salience) || 0.5
    }
  end

  defp moment_field(moment, key) when is_map(moment) do
    Map.get(moment, key) || Map.get(moment, to_string(key))
  end

  defp moment_field(_moment, _key), do: nil

  defp serialize_moment_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_moment_timestamp(str) when is_binary(str), do: str
  defp serialize_moment_timestamp(_), do: nil
end
