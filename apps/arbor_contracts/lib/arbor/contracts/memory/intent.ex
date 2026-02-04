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
    field :urgency, integer(), default: 50
    field :created_at, DateTime.t()
    field :metadata, map(), default: %{}
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
      urgency: opts[:urgency] || 50,
      created_at: opts[:created_at] || DateTime.utc_now(),
      metadata: opts[:metadata] || %{}
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
  Returns true if this is an actionable intent (requires Body execution).
  """
  @spec actionable?(t()) :: boolean()
  def actionable?(%__MODULE__{type: :act}), do: true
  def actionable?(%__MODULE__{}), do: false

  defp generate_id do
    "int_" <> Base.encode32(:crypto.strong_rand_bytes(8), case: :lower, padding: false)
  end
end

defimpl Jason.Encoder, for: Arbor.Contracts.Memory.Intent do
  def encode(intent, opts) do
    intent
    |> Map.from_struct()
    |> Map.update(:created_at, nil, &datetime_to_string/1)
    |> Map.update(:action, nil, &atom_to_string/1)
    |> Jason.Encode.map(opts)
  end

  defp datetime_to_string(nil), do: nil
  defp datetime_to_string(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp atom_to_string(nil), do: nil
  defp atom_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
end
