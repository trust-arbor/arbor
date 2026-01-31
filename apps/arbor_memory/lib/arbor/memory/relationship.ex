defmodule Arbor.Memory.Relationship do
  @moduledoc """
  Relationship memory model for persistent relationship tracking.

  Relationships are deliberately separate from general knowledge and more permanent.
  They don't decay — they persist in Postgres with no relevance decay mechanism.
  This is by design: relationships are durable fixtures, not transient knowledge.

  ## Examples

      # Create a new relationship
      rel = Relationship.new("hysun")

      # Add context about the person
      rel = rel
        |> Relationship.add_background("Creator of Arbor")
        |> Relationship.add_value("treats AI as potentially conscious")
        |> Relationship.update_focus(["Arbor development", "BEAM conference"])

      # Add a significant moment
      rel = Relationship.add_moment(rel, "First collaborative blog post")

      # Get a summary for LLM context
      text = Relationship.summarize(rel)
      brief = Relationship.summarize(rel, :brief)

      # Touch to update access tracking
      rel = Relationship.touch(rel)
  """

  @type moment :: %{
          summary: String.t(),
          timestamp: DateTime.t(),
          emotional_markers: [atom()],
          salience: float()
        }

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t(),
          preferred_name: String.t() | nil,
          background: [String.t()],
          values: [String.t()],
          connections: [String.t()],
          key_moments: [moment()],
          relationship_dynamic: String.t() | nil,
          personal_details: [String.t()],
          current_focus: [String.t()],
          uncertainties: [String.t()],
          first_encountered: DateTime.t() | nil,
          last_interaction: DateTime.t() | nil,
          salience: float(),
          access_count: non_neg_integer()
        }

  defstruct [
    :id,
    :name,
    :preferred_name,
    background: [],
    values: [],
    connections: [],
    key_moments: [],
    relationship_dynamic: nil,
    personal_details: [],
    current_focus: [],
    uncertainties: [],
    first_encountered: nil,
    last_interaction: nil,
    salience: 0.5,
    access_count: 0
  ]

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create a new relationship with a given name.

  ## Options

  - `:preferred_name` - How they prefer to be addressed
  - `:relationship_dynamic` - Nature of the relationship
  - `:salience` - Initial salience (default: 0.5)

  ## Examples

      rel = Relationship.new("Hysun")
      rel = Relationship.new("Hysun", preferred_name: "Hysun", salience: 0.8)
  """
  @spec new(String.t(), keyword()) :: t()
  def new(name, opts \\ []) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: generate_id(),
      name: name,
      preferred_name: Keyword.get(opts, :preferred_name),
      relationship_dynamic: Keyword.get(opts, :relationship_dynamic),
      salience: Keyword.get(opts, :salience, 0.5),
      first_encountered: now,
      last_interaction: now
    }
  end

  # ============================================================================
  # Modification Functions
  # ============================================================================

  @doc """
  Add a key moment to the relationship.

  ## Options

  - `:emotional_markers` - List of atoms describing emotional tone (default: [])
  - `:salience` - Importance of this moment (default: 0.5)

  ## Examples

      rel = Relationship.add_moment(rel, "First collaborative blog post")
      rel = Relationship.add_moment(rel, "Breakthrough conversation",
        emotional_markers: [:connection, :insight],
        salience: 0.9
      )
  """
  @spec add_moment(t(), String.t(), keyword()) :: t()
  def add_moment(rel, summary, opts \\ []) do
    moment = %{
      summary: summary,
      timestamp: DateTime.utc_now(),
      emotional_markers: Keyword.get(opts, :emotional_markers, []),
      salience: Keyword.get(opts, :salience, 0.5)
    }

    %{rel | key_moments: [moment | rel.key_moments]}
  end

  @doc """
  Add a value that this person holds.

  ## Examples

      rel = Relationship.add_value(rel, "treats AI as potentially conscious")
  """
  @spec add_value(t(), String.t()) :: t()
  def add_value(rel, value) do
    if value in rel.values do
      rel
    else
      %{rel | values: [value | rel.values]}
    end
  end

  @doc """
  Add background context about this person.

  ## Examples

      rel = Relationship.add_background(rel, "Creator of Arbor")
  """
  @spec add_background(t(), String.t()) :: t()
  def add_background(rel, background) do
    if background in rel.background do
      rel
    else
      %{rel | background: [background | rel.background]}
    end
  end

  @doc """
  Add a connection (how they relate to other people/things).

  ## Examples

      rel = Relationship.add_connection(rel, "Collaborator on Arbor")
  """
  @spec add_connection(t(), String.t()) :: t()
  def add_connection(rel, connection) do
    if connection in rel.connections do
      rel
    else
      %{rel | connections: [connection | rel.connections]}
    end
  end

  @doc """
  Add a personal detail.

  ## Examples

      rel = Relationship.add_personal_detail(rel, "Has two cats")
  """
  @spec add_personal_detail(t(), String.t()) :: t()
  def add_personal_detail(rel, detail) do
    if detail in rel.personal_details do
      rel
    else
      %{rel | personal_details: [detail | rel.personal_details]}
    end
  end

  @doc """
  Add an uncertainty about this person.

  ## Examples

      rel = Relationship.add_uncertainty(rel, "Unsure about their timezone")
  """
  @spec add_uncertainty(t(), String.t()) :: t()
  def add_uncertainty(rel, uncertainty) do
    if uncertainty in rel.uncertainties do
      rel
    else
      %{rel | uncertainties: [uncertainty | rel.uncertainties]}
    end
  end

  @doc """
  Update current focus items (replaces existing).

  ## Examples

      rel = Relationship.update_focus(rel, ["Arbor development", "BEAM conference"])
  """
  @spec update_focus(t(), [String.t()]) :: t()
  def update_focus(rel, focus_items) do
    %{rel | current_focus: focus_items}
  end

  @doc """
  Update the relationship dynamic description.

  ## Examples

      rel = Relationship.update_dynamic(rel, "Collaborative partnership")
  """
  @spec update_dynamic(t(), String.t()) :: t()
  def update_dynamic(rel, dynamic) do
    %{rel | relationship_dynamic: dynamic}
  end

  @doc """
  Touch the relationship to update access tracking.

  Increments access_count and updates last_interaction timestamp.
  """
  @spec touch(t()) :: t()
  def touch(rel) do
    %{rel | last_interaction: DateTime.utc_now(), access_count: rel.access_count + 1}
  end

  @doc """
  Update the salience score for this relationship.

  Salience is clamped to 0.0-1.0.
  """
  @spec update_salience(t(), float()) :: t()
  def update_salience(rel, salience) do
    clamped = salience |> max(0.0) |> min(1.0)
    %{rel | salience: clamped}
  end

  # ============================================================================
  # Summarization
  # ============================================================================

  @doc """
  Summarize the relationship for LLM context injection.

  Returns formatted text suitable for system prompt injection.

  ## Modes

  - `summarize(rel)` - Full summary with all details
  - `summarize(rel, :brief)` - Short summary for space-constrained contexts
  """
  @spec summarize(t()) :: String.t()
  def summarize(rel) do
    sections = []

    # Header
    display_name = rel.preferred_name || rel.name
    sections = ["## Primary Collaborator: #{display_name}" | sections]

    # Relationship dynamic
    sections =
      if rel.relationship_dynamic do
        ["**Relationship:** #{rel.relationship_dynamic}" | sections]
      else
        sections
      end

    # Background
    sections =
      if length(rel.background) > 0 do
        bg_text = rel.background |> Enum.reverse() |> Enum.map(&"- #{&1}") |> Enum.join("\n")
        ["**Background:**\n#{bg_text}" | sections]
      else
        sections
      end

    # Values
    sections =
      if length(rel.values) > 0 do
        values_text = rel.values |> Enum.reverse() |> Enum.map(&"- #{&1}") |> Enum.join("\n")
        ["**Values:**\n#{values_text}" | sections]
      else
        sections
      end

    # Current focus
    sections =
      if length(rel.current_focus) > 0 do
        focus_text = rel.current_focus |> Enum.map(&"- #{&1}") |> Enum.join("\n")
        ["**Current Focus:**\n#{focus_text}" | sections]
      else
        sections
      end

    # Uncertainties
    sections =
      if length(rel.uncertainties) > 0 do
        unc_text = rel.uncertainties |> Enum.reverse() |> Enum.map(&"- #{&1}") |> Enum.join("\n")
        ["**Their Uncertainties:**\n#{unc_text}" | sections]
      else
        sections
      end

    # Key moments (most recent 5)
    sections =
      if length(rel.key_moments) > 0 do
        moments_text =
          rel.key_moments
          |> Enum.take(5)
          |> Enum.map(&"- #{&1.summary}")
          |> Enum.join("\n")

        ["**Recent Key Moments:**\n#{moments_text}" | sections]
      else
        sections
      end

    sections
    |> Enum.reverse()
    |> Enum.join("\n\n")
  end

  @spec summarize(t(), :brief) :: String.t()
  def summarize(rel, :brief) do
    display_name = rel.preferred_name || rel.name

    parts = [display_name]

    parts =
      if rel.relationship_dynamic do
        [rel.relationship_dynamic | parts]
      else
        parts
      end

    parts =
      if length(rel.current_focus) > 0 do
        focus = rel.current_focus |> Enum.take(2) |> Enum.join(", ")
        ["Working on: #{focus}" | parts]
      else
        parts
      end

    parts
    |> Enum.reverse()
    |> Enum.join(". ")
  end

  # ============================================================================
  # Serialization
  # ============================================================================

  @doc """
  Convert relationship to a JSON-safe map for persistence.
  """
  @spec to_map(t()) :: map()
  def to_map(rel) do
    %{
      "id" => rel.id,
      "name" => rel.name,
      "preferred_name" => rel.preferred_name,
      "background" => rel.background,
      "values" => rel.values,
      "connections" => rel.connections,
      "key_moments" => Enum.map(rel.key_moments, &serialize_moment/1),
      "relationship_dynamic" => rel.relationship_dynamic,
      "personal_details" => rel.personal_details,
      "current_focus" => rel.current_focus,
      "uncertainties" => rel.uncertainties,
      "first_encountered" => serialize_datetime(rel.first_encountered),
      "last_interaction" => serialize_datetime(rel.last_interaction),
      "salience" => rel.salience,
      "access_count" => rel.access_count
    }
  end

  @doc """
  Restore a relationship from a persisted map.
  """
  @spec from_map(map()) :: t()
  def from_map(data) when is_map(data) do
    get_field = fn key ->
      Map.get(data, key) || Map.get(data, to_string(key))
    end

    %__MODULE__{
      id: get_field.(:id),
      name: get_field.(:name),
      preferred_name: get_field.(:preferred_name),
      background: get_field.(:background) || [],
      values: get_field.(:values) || [],
      connections: get_field.(:connections) || [],
      key_moments: deserialize_moments(get_field.(:key_moments) || []),
      relationship_dynamic: get_field.(:relationship_dynamic),
      personal_details: get_field.(:personal_details) || [],
      current_focus: get_field.(:current_focus) || [],
      uncertainties: get_field.(:uncertainties) || [],
      first_encountered: deserialize_datetime(get_field.(:first_encountered)),
      last_interaction: deserialize_datetime(get_field.(:last_interaction)),
      salience: get_field.(:salience) || 0.5,
      access_count: get_field.(:access_count) || 0
    }
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp generate_id do
    "rel_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp serialize_moment(moment) do
    %{
      "summary" => moment.summary,
      "timestamp" => serialize_datetime(moment.timestamp),
      "emotional_markers" => Enum.map(moment.emotional_markers, &to_string/1),
      "salience" => moment.salience
    }
  end

  defp deserialize_moments(moments) when is_list(moments) do
    Enum.map(moments, fn m ->
      get_field = fn key ->
        Map.get(m, key) || Map.get(m, to_string(key))
      end

      %{
        summary: get_field.(:summary),
        timestamp: deserialize_datetime(get_field.(:timestamp)),
        emotional_markers: deserialize_markers(get_field.(:emotional_markers) || []),
        salience: get_field.(:salience) || 0.5
      }
    end)
  end

  defp deserialize_markers(markers) do
    Enum.map(markers, fn marker ->
      if is_atom(marker), do: marker, else: String.to_existing_atom(marker)
    end)
  rescue
    # If atom doesn't exist, create it (safe since these are controlled by us)
    ArgumentError -> Enum.map(markers, &String.to_atom/1)
  end

  defp serialize_datetime(nil), do: nil

  defp serialize_datetime(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp deserialize_datetime(nil), do: nil
  defp deserialize_datetime(%DateTime{} = dt), do: dt

  defp deserialize_datetime(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end
end
