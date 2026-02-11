defmodule Arbor.Contracts.Session.Behavior do
  @moduledoc """
  Generic state machine contract for Sessions.

  Agents define their own phases and transitions by building a `Behavior`
  struct. The struct captures the valid phase atoms, allowed transitions
  (keyed by `{from_phase, event}`), the initial phase, and which phases
  are terminal (no outbound transitions expected).

  ## Why "Behavior" and not "Behaviour"?

  This is a data contract (a struct describing a state machine), not an
  Elixir `@behaviour` (a callback interface). The American spelling
  distinguishes the two — `Session.Behavior` is a value you build and
  pass around, not a module you `use` or `@impl`.

  ## Graph Compatibility

  When `graph_compatible: true`, the session's phase transitions can be
  expressed as a DOT graph. The `graph_constraints` field (Phase 5) will
  hold DOT-specific metadata such as node attributes and edge labels.

  ## Serialization

  `MapSet` doesn't implement `Jason.Encoder`, so this module provides
  `to_map/1` and `from_map/1` for JSON-safe round-tripping instead of
  deriving `Jason.Encoder`.

  ## Usage

      # Use the built-in default
      {:ok, behavior} = Behavior.default()

      # Custom behavior
      {:ok, behavior} = Behavior.new(
        name: "code_review_session",
        phases: MapSet.new([:draft, :reviewing, :approved, :rejected]),
        transitions: %{
          {:draft, :submit} => :reviewing,
          {:reviewing, :approve} => :approved,
          {:reviewing, :reject} => :rejected
        },
        initial: :draft,
        terminal: MapSet.new([:approved, :rejected])
      )

      Behavior.valid_transition?(behavior, :draft, :submit)     # => true
      Behavior.next_phase(behavior, :draft, :submit)             # => {:ok, :approved} ... wait
      Behavior.next_phase(behavior, :reviewing, :approve)        # => {:ok, :approved}
      Behavior.terminal?(behavior, :approved)                    # => true
  """

  use TypedStruct

  # ============================================================================
  # Struct
  # ============================================================================

  typedstruct do
    @typedoc "A session state machine definition"

    field(:name, String.t(), enforce: true)
    field(:phases, MapSet.t(), enforce: true)
    field(:transitions, map(), enforce: true)
    field(:initial, atom(), enforce: true)
    field(:terminal, MapSet.t(), default: MapSet.new())
    field(:graph_compatible, boolean(), default: false)
    field(:graph_constraints, map() | nil, default: nil)
    field(:metadata, map(), default: %{})
  end

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create a new session behavior with validation.

  Accepts a keyword list or map. Required fields: `name`, `phases`,
  `transitions`, `initial`.

  ## Validation

  - `initial` must be a member of `phases`
  - Every transition target must be a member of `phases`
  - Every transition source must be a member of `phases`
  - All terminal phases must be members of `phases`
  - `phases` must be non-empty
  - `name` must be a non-empty string

  ## Options

  - `:name` — Human-readable name for this behavior (required)
  - `:phases` — `MapSet` of valid phase atoms (required)
  - `:transitions` — Map of `{from_phase, event} => to_phase` (required)
  - `:initial` — Starting phase atom (required, must be in phases)
  - `:terminal` — `MapSet` of terminal phase atoms (default: empty)
  - `:graph_compatible` — Whether this behavior can be expressed as DOT (default: false)
  - `:graph_constraints` — DOT-specific metadata (default: nil, Phase 5)
  - `:metadata` — Arbitrary metadata (default: `%{}`)

  ## Examples

      {:ok, behavior} = Behavior.new(
        name: "simple",
        phases: MapSet.new([:idle, :working, :done]),
        transitions: %{{:idle, :start} => :working, {:working, :finish} => :done},
        initial: :idle,
        terminal: MapSet.new([:done])
      )

      {:error, {:initial_not_in_phases, :bogus}} = Behavior.new(
        name: "bad",
        phases: MapSet.new([:idle]),
        transitions: %{},
        initial: :bogus
      )
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    attrs |> Map.new() |> new()
  end

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_name(get_attr(attrs, :name)),
         :ok <- validate_phases(get_attr(attrs, :phases)),
         :ok <- validate_transitions_map(get_attr(attrs, :transitions)),
         :ok <- validate_initial(get_attr(attrs, :initial), get_attr(attrs, :phases)),
         :ok <- validate_terminal(get_attr(attrs, :terminal), get_attr(attrs, :phases)),
         :ok <- validate_transition_members(get_attr(attrs, :transitions), get_attr(attrs, :phases)),
         :ok <- validate_graph_compatible(get_attr(attrs, :graph_compatible)),
         :ok <- validate_metadata(get_attr(attrs, :metadata)) do
      behavior = %__MODULE__{
        name: get_attr(attrs, :name),
        phases: get_attr(attrs, :phases),
        transitions: get_attr(attrs, :transitions),
        initial: get_attr(attrs, :initial),
        terminal: get_attr(attrs, :terminal) || MapSet.new(),
        graph_compatible: get_attr(attrs, :graph_compatible) || false,
        graph_constraints: get_attr(attrs, :graph_constraints),
        metadata: get_attr(attrs, :metadata) || %{}
      }

      {:ok, behavior}
    end
  end

  # ============================================================================
  # Queries
  # ============================================================================

  @doc """
  Check if a transition from `phase` via `event` is defined.

  Returns `true` if the transition exists in the behavior's transition map.

  ## Examples

      {:ok, b} = Behavior.default()
      Behavior.valid_transition?(b, :idle, :input_received)        # => true
      Behavior.valid_transition?(b, :idle, :nonexistent_event)     # => false
  """
  @spec valid_transition?(t(), atom(), atom()) :: boolean()
  def valid_transition?(%__MODULE__{transitions: transitions}, phase, event) do
    Map.has_key?(transitions, {phase, event})
  end

  @doc """
  Get the next phase for a transition from `phase` via `event`.

  Returns `{:ok, next_phase}` if the transition is defined, or
  `{:error, {:invalid_transition, phase, event}}` otherwise.

  ## Examples

      {:ok, b} = Behavior.default()
      {:ok, :processing} = Behavior.next_phase(b, :idle, :input_received)
      {:error, {:invalid_transition, :idle, :bogus}} = Behavior.next_phase(b, :idle, :bogus)
  """
  @spec next_phase(t(), atom(), atom()) :: {:ok, atom()} | {:error, term()}
  def next_phase(%__MODULE__{transitions: transitions}, phase, event) do
    case Map.fetch(transitions, {phase, event}) do
      {:ok, next} -> {:ok, next}
      :error -> {:error, {:invalid_transition, phase, event}}
    end
  end

  @doc """
  Check if a phase is terminal (session should end when reaching it).

  ## Examples

      {:ok, b} = Behavior.default()
      Behavior.terminal?(b, :idle)    # => false
  """
  @spec terminal?(t(), atom()) :: boolean()
  def terminal?(%__MODULE__{terminal: terminal}, phase) do
    MapSet.member?(terminal, phase)
  end

  # ============================================================================
  # Defaults
  # ============================================================================

  @doc """
  Returns the default session behavior.

  Phases: `:idle`, `:processing`, `:awaiting_tools`, `:awaiting_llm`

  Transitions:
  - `{:idle, :input_received}` => `:processing`
  - `{:processing, :needs_tools}` => `:awaiting_tools`
  - `{:processing, :needs_llm}` => `:awaiting_llm`
  - `{:processing, :complete}` => `:idle`
  - `{:awaiting_tools, :tools_complete}` => `:processing`
  - `{:awaiting_tools, :tools_error}` => `:processing`
  - `{:awaiting_llm, :llm_complete}` => `:processing`
  - `{:awaiting_llm, :llm_error}` => `:processing`

  No terminal phases — the default session loops until explicitly stopped.

  ## Examples

      {:ok, behavior} = Behavior.default()
      behavior.name       # => "default_session"
      behavior.initial    # => :idle
  """
  @spec default() :: {:ok, t()}
  def default do
    phases = MapSet.new([:idle, :processing, :awaiting_tools, :awaiting_llm])

    transitions = %{
      {:idle, :input_received} => :processing,
      {:processing, :needs_tools} => :awaiting_tools,
      {:processing, :needs_llm} => :awaiting_llm,
      {:processing, :complete} => :idle,
      {:awaiting_tools, :tools_complete} => :processing,
      {:awaiting_tools, :tools_error} => :processing,
      {:awaiting_llm, :llm_complete} => :processing,
      {:awaiting_llm, :llm_error} => :processing
    }

    new(
      name: "default_session",
      phases: phases,
      transitions: transitions,
      initial: :idle
    )
  end

  # ============================================================================
  # Serialization
  # ============================================================================

  @doc """
  Convert to a JSON-safe map.

  Converts `MapSet` fields to sorted lists and tuple keys to string
  representations for JSON compatibility.

  ## Examples

      {:ok, b} = Behavior.default()
      map = Behavior.to_map(b)
      map["name"]    # => "default_session"
      map["phases"]  # => [:awaiting_llm, :awaiting_tools, :idle, :processing]
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = behavior) do
    %{
      "name" => behavior.name,
      "phases" => behavior.phases |> MapSet.to_list() |> Enum.sort(),
      "transitions" => serialize_transitions(behavior.transitions),
      "initial" => behavior.initial,
      "terminal" => behavior.terminal |> MapSet.to_list() |> Enum.sort(),
      "graph_compatible" => behavior.graph_compatible,
      "graph_constraints" => behavior.graph_constraints,
      "metadata" => behavior.metadata
    }
  end

  @doc """
  Restore from a JSON-safe map (as produced by `to_map/1`).

  Returns `{:ok, behavior}` or `{:error, reason}`. Phase and event atoms
  are created using `String.to_existing_atom/1` to avoid atom table
  pollution — callers must ensure phase atoms exist before calling this
  (see `phase_atoms/1` for registration).

  ## Examples

      {:ok, b} = Behavior.default()
      map = Behavior.to_map(b)
      {:ok, ^b} = Behavior.from_map(map)
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) do
    with {:ok, phases} <- deserialize_atom_set(map["phases"]),
         {:ok, terminal} <- deserialize_atom_set(map["terminal"] || []),
         {:ok, transitions} <- deserialize_transitions(map["transitions"]),
         {:ok, initial} <- safe_to_existing_atom(map["initial"]) do
      new(
        name: map["name"],
        phases: phases,
        transitions: transitions,
        initial: initial,
        terminal: terminal,
        graph_compatible: map["graph_compatible"] || false,
        graph_constraints: map["graph_constraints"],
        metadata: map["metadata"] || %{}
      )
    end
  end

  # ============================================================================
  # Utilities
  # ============================================================================

  @doc """
  Returns a sorted list of all phase atoms in the behavior.

  Useful for pre-registering atoms with `SafeAtom` before calling
  `from_map/1`, which uses `String.to_existing_atom/1`.

  ## Examples

      {:ok, b} = Behavior.default()
      Behavior.phase_atoms(b)
      # => [:awaiting_llm, :awaiting_tools, :idle, :processing]
  """
  @spec phase_atoms(t()) :: [atom()]
  def phase_atoms(%__MODULE__{phases: phases}) do
    phases |> MapSet.to_list() |> Enum.sort()
  end

  # ============================================================================
  # Private — Validation
  # ============================================================================

  defp validate_name(nil), do: {:error, {:missing_required, :name}}
  defp validate_name(name) when is_binary(name) and byte_size(name) > 0, do: :ok
  defp validate_name(""), do: {:error, {:missing_required, :name}}
  defp validate_name(invalid), do: {:error, {:invalid_name, invalid}}

  defp validate_phases(nil), do: {:error, {:missing_required, :phases}}

  defp validate_phases(%MapSet{} = phases) do
    if MapSet.size(phases) > 0 do
      if Enum.all?(phases, &is_atom/1) do
        :ok
      else
        {:error, {:phases_must_be_atoms, phases}}
      end
    else
      {:error, :phases_must_be_non_empty}
    end
  end

  defp validate_phases(invalid), do: {:error, {:invalid_phases, invalid}}

  defp validate_transitions_map(nil), do: {:error, {:missing_required, :transitions}}
  defp validate_transitions_map(t) when is_map(t), do: :ok
  defp validate_transitions_map(invalid), do: {:error, {:invalid_transitions, invalid}}

  defp validate_initial(nil, _phases), do: {:error, {:missing_required, :initial}}

  defp validate_initial(initial, %MapSet{} = phases) when is_atom(initial) do
    if MapSet.member?(phases, initial) do
      :ok
    else
      {:error, {:initial_not_in_phases, initial}}
    end
  end

  defp validate_initial(initial, _phases), do: {:error, {:invalid_initial, initial}}

  defp validate_terminal(nil, _phases), do: :ok

  defp validate_terminal(%MapSet{} = terminal, %MapSet{} = phases) do
    non_members = MapSet.difference(terminal, phases)

    if MapSet.size(non_members) == 0 do
      :ok
    else
      {:error, {:terminal_not_in_phases, MapSet.to_list(non_members)}}
    end
  end

  defp validate_terminal(invalid, _phases), do: {:error, {:invalid_terminal, invalid}}

  defp validate_transition_members(transitions, %MapSet{} = phases) when is_map(transitions) do
    Enum.reduce_while(transitions, :ok, fn
      {{from, event}, to}, :ok when is_atom(from) and is_atom(event) and is_atom(to) ->
        cond do
          not MapSet.member?(phases, from) ->
            {:halt, {:error, {:transition_source_not_in_phases, from}}}

          not MapSet.member?(phases, to) ->
            {:halt, {:error, {:transition_target_not_in_phases, to}}}

          true ->
            {:cont, :ok}
        end

      {key, _value}, :ok ->
        {:halt, {:error, {:invalid_transition_key, key}}}
    end)
  end

  defp validate_graph_compatible(nil), do: :ok
  defp validate_graph_compatible(val) when is_boolean(val), do: :ok
  defp validate_graph_compatible(invalid), do: {:error, {:invalid_graph_compatible, invalid}}

  defp validate_metadata(nil), do: :ok
  defp validate_metadata(meta) when is_map(meta), do: :ok
  defp validate_metadata(invalid), do: {:error, {:invalid_metadata, invalid}}

  # ============================================================================
  # Private — Serialization Helpers
  # ============================================================================

  defp serialize_transitions(transitions) do
    Map.new(transitions, fn {{from, event}, to} ->
      {"#{from}:#{event}", Atom.to_string(to)}
    end)
  end

  defp deserialize_transitions(nil), do: {:ok, %{}}

  defp deserialize_transitions(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, {from, event}} <- parse_transition_key(key),
           {:ok, to} <- safe_to_existing_atom(value) do
        {:cont, {:ok, Map.put(acc, {from, event}, to)}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp deserialize_transitions(invalid), do: {:error, {:invalid_transitions, invalid}}

  defp parse_transition_key(key) when is_binary(key) do
    case String.split(key, ":", parts: 2) do
      [from_str, event_str] ->
        with {:ok, from} <- safe_to_existing_atom(from_str),
             {:ok, event} <- safe_to_existing_atom(event_str) do
          {:ok, {from, event}}
        end

      _ ->
        {:error, {:invalid_transition_key, key}}
    end
  end

  defp deserialize_atom_set(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, MapSet.new()}, fn item, {:ok, set} ->
      case safe_to_existing_atom(item) do
        {:ok, atom} -> {:cont, {:ok, MapSet.put(set, atom)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp deserialize_atom_set(invalid), do: {:error, {:invalid_atom_set, invalid}}

  defp safe_to_existing_atom(value) when is_atom(value), do: {:ok, value}

  defp safe_to_existing_atom(value) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> {:error, {:unknown_atom, value}}
  end

  # ============================================================================
  # Private — Helpers
  # ============================================================================

  # Supports both atom and string keys in attrs map
  defp get_attr(attrs, key) when is_atom(key) do
    case Map.get(attrs, key) do
      nil -> Map.get(attrs, Atom.to_string(key))
      value -> value
    end
  end
end
