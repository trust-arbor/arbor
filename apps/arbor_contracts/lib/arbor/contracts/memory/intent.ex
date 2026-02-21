defmodule Arbor.Contracts.Memory.Intent do
  @moduledoc """
  Mind's intention to act, bridging reasoning to execution.

  An Intent represents what the Mind (Seed) has decided to do. It bridges
  the gap between reasoning ("I should do X") and execution ("do X").
  The Body (Host) receives Intents via the Bridge and executes them.

  ## Intent Types

  - `:think` - Internal reasoning, no external action
  - `:act` - Execute an action via the Body
  - `:wait` - Pause for external input or time
  - `:reflect` - Review past actions/outcomes
  - `:internal` - Internal state update (memory, goals)

  ## Intent Flow

  1. Mind forms an Intent based on goals and context
  2. Intent is emitted to Bridge
  3. Body receives Intent, authorizes, executes
  4. Body returns Percept with outcome
  5. Mind integrates Percept

  ## Example

      %Intent{
        id: "int_xyz789",
        type: :act,
        action: :shell_execute,
        params: %{command: "mix test", timeout: 60_000},
        reasoning: "Need to verify tests pass before committing",
        goal_id: "goal_abc123",
        urgency: 70,
        created_at: ~U[2026-02-04 00:00:00Z]
      }
  """

  use TypedStruct

  @typedoc "Type of intent"
  @type intent_type :: :think | :act | :wait | :reflect | :internal

  typedstruct do
    @typedoc "An agent intent"

    field :id, String.t(), enforce: true
    field :type, intent_type(), enforce: true
    field :action, atom() | nil, default: nil
    field :params, map(), default: %{}
    field :reasoning, String.t() | nil, default: nil
    field :goal_id, String.t() | nil, default: nil
    field :confidence, float(), default: 0.5
    field :urgency, integer(), default: 50
    field :created_at, DateTime.t()
    field :metadata, map(), default: %{}

    # Capability-intent fields (Phase 0 cognitive loop redesign)
    field :capability, String.t() | nil, default: nil
    field :op, atom() | nil, default: nil
    field :target, String.t() | nil, default: nil
  end

  @doc """
  Creates a new Intent with a generated ID and timestamp.
  """
  @spec new(intent_type(), keyword()) :: t()
  def new(type, opts \\ []) do
    %__MODULE__{
      id: opts[:id] || generate_id(),
      type: type,
      action: opts[:action],
      params: opts[:params] || %{},
      reasoning: opts[:reasoning],
      goal_id: opts[:goal_id],
      confidence: opts[:confidence] || 0.5,
      urgency: opts[:urgency] || 50,
      created_at: opts[:created_at] || DateTime.utc_now(),
      metadata: opts[:metadata] || %{},
      capability: opts[:capability],
      op: opts[:op],
      target: opts[:target]
    }
  end

  @doc """
  Creates an action intent.
  """
  @spec action(atom(), map(), keyword()) :: t()
  def action(action_name, params \\ %{}, opts \\ []) do
    new(:act, [{:action, action_name}, {:params, params} | opts])
  end

  @doc """
  Creates a thinking intent.
  """
  @spec think(String.t() | nil, keyword()) :: t()
  def think(reasoning \\ nil, opts \\ []) do
    new(:think, [{:reasoning, reasoning} | opts])
  end

  @doc """
  Creates a wait intent.
  """
  @spec wait(keyword()) :: t()
  def wait(opts \\ []) do
    new(:wait, opts)
  end

  @doc """
  Creates a reflection intent.
  """
  @spec reflect(String.t() | nil, keyword()) :: t()
  def reflect(reasoning \\ nil, opts \\ []) do
    new(:reflect, [{:reasoning, reasoning} | opts])
  end

  @doc """
  Creates a capability-described intent for the cognitive loop.

  This is the primary constructor for the Mind/Host architecture.
  The Mind specifies *what* it wants (`capability`, `op`, `target`),
  and the Host dispatches to the correct action module.

  ## Examples

      Intent.capability_intent("fs", :read, "/etc/hosts",
        reasoning: "Need to check host configuration",
        goal_id: "goal_123"
      )
  """
  @spec capability_intent(String.t(), atom(), String.t(), keyword()) :: t()
  def capability_intent(capability, op, target, opts \\ []) do
    new(:act, [
      {:capability, capability},
      {:op, op},
      {:target, target},
      {:action, op},
      {:params, Map.put(opts[:params] || %{}, :target, target)},
      {:reasoning, opts[:reasoning]}
      | Keyword.drop(opts, [:params, :reasoning])
    ])
  end

  @doc """
  Returns true if this is an actionable intent (requires Body execution).
  """
  @spec actionable?(t()) :: boolean()
  def actionable?(%__MODULE__{type: :act}), do: true
  def actionable?(%__MODULE__{}), do: false

  @doc """
  Returns true if this is a mental intent (no external action required).

  Mental intents include `:think`, `:wait`, `:internal`, and `:reflect`.
  """
  @spec mental?(t()) :: boolean()
  def mental?(%__MODULE__{type: type}) when type in [:think, :wait, :internal, :reflect], do: true
  def mental?(%__MODULE__{}), do: false

  @doc """
  Reconstruct an Intent from a plain map (e.g. deserialized signal data).

  Handles both atom and string keys. Safely atomizes `:type` and `:action`.
  Parses ISO8601 datetime strings for `:created_at`.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: map_get(map, :id) || generate_id(),
      type: atomize(map_get(map, :type)) || :act,
      action: atomize(map_get(map, :action)),
      params: map_get(map, :params) || %{},
      reasoning: map_get(map, :reasoning),
      goal_id: map_get(map, :goal_id),
      confidence: parse_float(map_get(map, :confidence)) || 0.5,
      urgency: map_get(map, :urgency) || 50,
      created_at: parse_datetime(map_get(map, :created_at)) || DateTime.utc_now(),
      metadata: map_get(map, :metadata) || %{},
      capability: map_get(map, :capability),
      op: atomize(map_get(map, :op)),
      target: map_get(map, :target)
    }
  end

  defp generate_id do
    "int_" <> Base.encode32(:crypto.strong_rand_bytes(8), case: :lower, padding: false)
  end

  defp map_get(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  @known_types [:think, :act, :wait, :reflect, :internal]

  defp atomize(nil), do: nil
  defp atomize(a) when is_atom(a), do: a
  defp atomize(s) when is_binary(s) do
    atom_match = Enum.find(@known_types, fn a -> Atom.to_string(a) == s end)
    atom_match || String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  defp parse_float(nil), do: nil
  defp parse_float(f) when is_float(f), do: f
  defp parse_float(i) when is_integer(i), do: i * 1.0
  defp parse_float(_), do: nil

  defp parse_datetime(%DateTime{} = dt), do: dt
  defp parse_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
  defp parse_datetime(_), do: nil
end

defimpl Jason.Encoder, for: Arbor.Contracts.Memory.Intent do
  def encode(intent, opts) do
    intent
    |> Map.from_struct()
    |> Map.update(:created_at, nil, &datetime_to_string/1)
    |> Map.update(:action, nil, &atom_to_string/1)
    |> Map.update(:op, nil, &atom_to_string/1)
    |> Jason.Encode.map(opts)
  end

  defp datetime_to_string(nil), do: nil
  defp datetime_to_string(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp atom_to_string(nil), do: nil
  defp atom_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
end
