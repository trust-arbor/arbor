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
    # Handle both struct and map input
    get_field = fn key ->
      cond do
        is_struct(relationship) -> Map.get(relationship, key)
        is_map(relationship) -> Map.get(relationship, key) || Map.get(relationship, to_string(key))
        true -> nil
      end
    end

    %{
      id: get_field.(:id),
      agent_id: agent_id,
      name: get_field.(:name),
      preferred_name: get_field.(:preferred_name),
      background: get_field.(:background) || [],
      values: get_field.(:values) || [],
      connections: get_field.(:connections) || [],
      key_moments: serialize_moments(get_field.(:key_moments) || []),
      relationship_dynamic: get_field.(:relationship_dynamic),
      personal_details: get_field.(:personal_details) || [],
      current_focus: get_field.(:current_focus) || [],
      uncertainties: get_field.(:uncertainties) || [],
      first_encountered: get_field.(:first_encountered),
      last_interaction: get_field.(:last_interaction),
      salience: get_field.(:salience) || 0.5,
      access_count: get_field.(:access_count) || 0
    }
  end

  @doc """
  Convert a schema struct back to an `Arbor.Memory.Relationship` struct.
  """
  @spec to_relationship(%__MODULE__{}) :: map()
  def to_relationship(%__MODULE__{} = schema) do
    %{
      id: schema.id,
      name: schema.name,
      preferred_name: schema.preferred_name,
      background: schema.background || [],
      values: schema.values || [],
      connections: schema.connections || [],
      key_moments: deserialize_moments(schema.key_moments || []),
      relationship_dynamic: schema.relationship_dynamic,
      personal_details: schema.personal_details || [],
      current_focus: schema.current_focus || [],
      uncertainties: schema.uncertainties || [],
      first_encountered: schema.first_encountered,
      last_interaction: schema.last_interaction,
      salience: schema.salience || 0.5,
      access_count: schema.access_count || 0
    }
  end

  # Convert moments to JSONB-safe format
  defp serialize_moments(moments) when is_list(moments) do
    Enum.map(moments, fn moment ->
      get_field = fn key ->
        cond do
          is_map(moment) ->
            Map.get(moment, key) || Map.get(moment, to_string(key))

          true ->
            nil
        end
      end

      timestamp = get_field.(:timestamp)

      timestamp_str =
        case timestamp do
          %DateTime{} -> DateTime.to_iso8601(timestamp)
          str when is_binary(str) -> str
          nil -> nil
        end

      markers = get_field.(:emotional_markers) || []
      markers_strs = Enum.map(markers, &to_string/1)

      %{
        "summary" => get_field.(:summary),
        "timestamp" => timestamp_str,
        "emotional_markers" => markers_strs,
        "salience" => get_field.(:salience) || 0.5
      }
    end)
  end

  # Convert moments from JSONB format back to struct format
  defp deserialize_moments(moments) when is_list(moments) do
    Enum.map(moments, fn moment ->
      get_field = fn key ->
        Map.get(moment, key) || Map.get(moment, to_string(key))
      end

      timestamp =
        case get_field.(:timestamp) do
          nil -> nil
          %DateTime{} = dt -> dt
          str when is_binary(str) -> parse_datetime(str)
        end

      markers = get_field.(:emotional_markers) || []
      markers_atoms = Enum.map(markers, &safe_to_atom/1)

      %{
        summary: get_field.(:summary),
        timestamp: timestamp,
        emotional_markers: markers_atoms,
        salience: get_field.(:salience) || 0.5
      }
    end)
  end

  defp parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  defp safe_to_atom(value) when is_atom(value), do: value

  defp safe_to_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> String.to_atom(value)
  end
end
