defmodule Arbor.Persistence.Schemas.Relationship do
  @moduledoc """
  Ecto schema for persisted relationships in the memory system.

  Maps to the `memory_relationships` table. Relationships are durable fixtures
  that don't decay — they persist permanently, unlike general knowledge.

  Provides conversion to/from `Arbor.Memory.Relationship` structs.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "memory_relationships" do
    field :agent_id, :string
    field :name, :string
    field :preferred_name, :string
    field :background, {:array, :string}, default: []
    field :values, {:array, :string}, default: []
    field :connections, {:array, :string}, default: []
    field :key_moments, {:array, :map}, default: []
    field :relationship_dynamic, :string
    field :personal_details, {:array, :string}, default: []
    field :current_focus, {:array, :string}, default: []
    field :uncertainties, {:array, :string}, default: []
    field :first_encountered, :utc_datetime_usec
    field :last_interaction, :utc_datetime_usec
    field :salience, :float, default: 0.5
    field :access_count, :integer, default: 0

    timestamps()
  end

  @required_fields [:id, :agent_id, :name]
  @optional_fields [
    :preferred_name,
    :background,
    :values,
    :connections,
    :key_moments,
    :relationship_dynamic,
    :personal_details,
    :current_focus,
    :uncertainties,
    :first_encountered,
    :last_interaction,
    :salience,
    :access_count
  ]

  @doc """
  Create a changeset for inserting or updating a relationship.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:salience, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:access_count, greater_than_or_equal_to: 0)
    |> unique_constraint([:agent_id, :name])
  end

  @doc """
  Convert an `Arbor.Memory.Relationship` struct to schema attrs map,
  including the agent_id for table scoping.
  """
  @spec from_relationship(map(), String.t()) :: map()
  def from_relationship(relationship, agent_id) when is_binary(agent_id) do
    base = from_rel_base_fields(relationship, agent_id)
    lists = from_rel_list_fields(relationship)

    Map.merge(base, lists)
  end

  defp from_rel_base_fields(relationship, agent_id) do
    %{
      id: get_rel_field(relationship, :id),
      agent_id: agent_id,
      name: get_rel_field(relationship, :name),
      preferred_name: get_rel_field(relationship, :preferred_name),
      relationship_dynamic: get_rel_field(relationship, :relationship_dynamic),
      first_encountered: get_rel_field(relationship, :first_encountered),
      last_interaction: get_rel_field(relationship, :last_interaction),
      salience: get_rel_field(relationship, :salience) || 0.5,
      access_count: get_rel_field(relationship, :access_count) || 0
    }
  end

  defp from_rel_list_fields(relationship) do
    %{
      background: get_rel_field(relationship, :background) || [],
      values: get_rel_field(relationship, :values) || [],
      connections: get_rel_field(relationship, :connections) || [],
      key_moments: serialize_moments(get_rel_field(relationship, :key_moments) || []),
      personal_details: get_rel_field(relationship, :personal_details) || [],
      current_focus: get_rel_field(relationship, :current_focus) || [],
      uncertainties: get_rel_field(relationship, :uncertainties) || []
    }
  end

  @doc """
  Convert a schema struct back to an `Arbor.Memory.Relationship` struct.
  """
  @spec to_relationship(%__MODULE__{}) :: map()
  def to_relationship(%__MODULE__{} = schema) do
    base = to_rel_base_fields(schema)
    lists = to_rel_list_fields(schema)

    Map.merge(base, lists)
  end

  defp to_rel_base_fields(schema) do
    %{
      id: schema.id,
      name: schema.name,
      preferred_name: schema.preferred_name,
      relationship_dynamic: schema.relationship_dynamic,
      first_encountered: schema.first_encountered,
      last_interaction: schema.last_interaction,
      salience: schema.salience || 0.5,
      access_count: schema.access_count || 0
    }
  end

  defp to_rel_list_fields(schema) do
    %{
      background: schema.background || [],
      values: schema.values || [],
      connections: schema.connections || [],
      key_moments: deserialize_moments(schema.key_moments || []),
      personal_details: schema.personal_details || [],
      current_focus: schema.current_focus || [],
      uncertainties: schema.uncertainties || []
    }
  end

  # Handle both struct and map input for field access
  defp get_rel_field(data, key) when is_struct(data), do: Map.get(data, key)

  defp get_rel_field(data, key) when is_map(data) do
    Map.get(data, key) || Map.get(data, to_string(key))
  end

  defp get_rel_field(_data, _key), do: nil

  # Get a field from a map that may have atom or string keys
  defp get_moment_field(moment, key) when is_map(moment) do
    Map.get(moment, key) || Map.get(moment, to_string(key))
  end

  defp get_moment_field(_moment, _key), do: nil

  # Convert moments to JSONB-safe format
  defp serialize_moments(moments) when is_list(moments) do
    Enum.map(moments, &serialize_single_moment/1)
  end

  defp serialize_single_moment(moment) do
    timestamp_str = serialize_timestamp(get_moment_field(moment, :timestamp))
    markers = get_moment_field(moment, :emotional_markers) || []

    %{
      "summary" => get_moment_field(moment, :summary),
      "timestamp" => timestamp_str,
      "emotional_markers" => Enum.map(markers, &to_string/1),
      "salience" => get_moment_field(moment, :salience) || 0.5
    }
  end

  defp serialize_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_timestamp(str) when is_binary(str), do: str
  defp serialize_timestamp(_), do: nil

  # Convert moments from JSONB format back to struct format
  defp deserialize_moments(moments) when is_list(moments) do
    Enum.map(moments, &deserialize_single_moment/1)
  end

  defp deserialize_single_moment(moment) do
    timestamp = deserialize_timestamp(get_moment_field(moment, :timestamp))
    markers = get_moment_field(moment, :emotional_markers) || []
    markers_atoms = markers |> Enum.map(&safe_to_atom/1) |> Enum.reject(&is_nil/1)

    %{
      summary: get_moment_field(moment, :summary),
      timestamp: timestamp,
      emotional_markers: markers_atoms,
      salience: get_moment_field(moment, :salience) || 0.5
    }
  end

  defp deserialize_timestamp(nil), do: nil
  defp deserialize_timestamp(%DateTime{} = dt), do: dt
  defp deserialize_timestamp(str) when is_binary(str), do: parse_datetime(str)

  defp parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  # Allowlist of valid emotional markers — must match Arbor.Memory.Relationship
  @allowed_markers ~w(
    connection insight joy trust concern hope accomplishment breakthrough
    challenge support tension clarity gratitude curiosity frustration
    relief pride vulnerability warmth respect
  )a

  defp safe_to_atom(value) when is_atom(value), do: value

  defp safe_to_atom(value) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in @allowed_markers, do: atom, else: nil
  rescue
    ArgumentError -> nil
  end
end
