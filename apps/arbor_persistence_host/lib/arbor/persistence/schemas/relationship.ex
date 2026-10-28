defmodule Arbor.Persistence.Schemas.Relationship do
  @moduledoc """
  Ecto schema for durable relationship rows (`memory_relationships`).

  Relationships are permanent fixtures — no decay. Conversion helpers exchange
  only closed, atom-keyed plain maps. No higher-level domain modules are named
  or called from this schema.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "memory_relationships" do
    field(:agent_id, :string)
    field(:name, :string)
    field(:preferred_name, :string)
    field(:background, {:array, :string}, default: [])
    field(:values, {:array, :string}, default: [])
    field(:connections, {:array, :string}, default: [])
    field(:key_moments, {:array, :map}, default: [])
    field(:relationship_dynamic, :string)
    field(:personal_details, {:array, :string}, default: [])
    field(:current_focus, {:array, :string}, default: [])
    field(:uncertainties, {:array, :string}, default: [])
    field(:first_encountered, :utc_datetime_usec)
    field(:last_interaction, :utc_datetime_usec)
    field(:salience, :float, default: 0.5)
    field(:access_count, :integer, default: 0)

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
  Build schema attrs from a closed plain map plus source-owned `agent_id`.
  """
  @spec attrs_from_map(map(), String.t()) :: map()
  def attrs_from_map(data, agent_id) when is_map(data) and is_binary(agent_id) do
    %{
      id: Map.fetch!(data, :id),
      agent_id: agent_id,
      name: Map.fetch!(data, :name),
      preferred_name: Map.get(data, :preferred_name),
      background: Map.get(data, :background, []),
      values: Map.get(data, :values, []),
      connections: Map.get(data, :connections, []),
      key_moments: serialize_moments(Map.get(data, :key_moments, [])),
      relationship_dynamic: Map.get(data, :relationship_dynamic),
      personal_details: Map.get(data, :personal_details, []),
      current_focus: Map.get(data, :current_focus, []),
      uncertainties: Map.get(data, :uncertainties, []),
      first_encountered: Map.get(data, :first_encountered),
      last_interaction: Map.get(data, :last_interaction),
      salience: Map.get(data, :salience, 0.5),
      access_count: Map.get(data, :access_count, 0)
    }
  end

  @doc """
  Convert a schema row to a closed atom-keyed plain map (no agent_id field).
  Moment markers are strings on the public boundary.
  """
  @spec to_plain_map(%__MODULE__{}) :: map()
  def to_plain_map(%__MODULE__{} = schema) do
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

  defp serialize_moments(moments) when is_list(moments) do
    Enum.map(moments, &serialize_single_moment/1)
  end

  defp serialize_single_moment(moment) when is_map(moment) do
    markers = moment_field(moment, :emotional_markers) || []

    %{
      "summary" => moment_field(moment, :summary),
      "timestamp" => serialize_timestamp(moment_field(moment, :timestamp)),
      "emotional_markers" => Enum.map(markers, &to_string/1),
      "salience" => moment_field(moment, :salience) || 0.5
    }
  end

  defp moment_field(moment, key) when is_map(moment) do
    Map.get(moment, key) || Map.get(moment, Atom.to_string(key))
  end

  defp serialize_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_timestamp(str) when is_binary(str), do: str
  defp serialize_timestamp(_), do: nil

  defp deserialize_moments(moments) when is_list(moments) do
    Enum.map(moments, &deserialize_single_moment/1)
  end

  defp deserialize_single_moment(moment) when is_map(moment) do
    markers = moment_field(moment, :emotional_markers) || []

    %{
      summary: moment_field(moment, :summary),
      timestamp: deserialize_timestamp(moment_field(moment, :timestamp)),
      emotional_markers: Enum.map(markers, &to_string/1),
      salience: moment_field(moment, :salience) || 0.5
    }
  end

  defp deserialize_timestamp(nil), do: nil
  defp deserialize_timestamp(%DateTime{} = dt), do: dt

  defp deserialize_timestamp(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end
end
