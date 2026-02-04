defmodule Arbor.Contracts.Memory.Goal do
  @moduledoc """
  Agent objective with hierarchy, priority, and progress tracking.

  Goals represent what an agent is trying to achieve. They form the persistent
  "want" layer of the Mind (Seed) in the Mind-Body architecture.

  ## Goal Types

  - `:achieve` - One-time accomplishment (e.g., "fix bug #123")
  - `:maintain` - Ongoing state to preserve (e.g., "keep tests passing")
  - `:explore` - Open-ended investigation (e.g., "understand codebase")
  - `:learn` - Knowledge acquisition (e.g., "learn Elixir patterns")
  - `:avoid` - Negative goal (e.g., "don't break production")

  ## Goal Hierarchy

  Goals can have parent goals, forming a tree. Progress on child goals
  contributes to parent goal progress.

  ## Example

      %Goal{
        id: "goal_abc123",
        description: "Implement user authentication",
        type: :achieve,
        status: :active,
        priority: 80,
        parent_id: "goal_project_mvp",
        progress: 0.3,
        created_at: ~U[2026-02-04 00:00:00Z],
        metadata: %{tags: ["security", "mvp"]}
      }
  """

  use TypedStruct

  @typedoc "Type of goal objective"
  @type goal_type :: :achieve | :maintain | :explore | :learn | :avoid

  @typedoc "Current status of the goal"
  @type goal_status :: :active | :achieved | :abandoned | :blocked

  typedstruct do
    @typedoc "An agent goal"

    field :id, String.t(), enforce: true
    field :description, String.t(), enforce: true
    field :type, goal_type(), default: :achieve
    field :status, goal_status(), default: :active
    field :priority, integer(), default: 50
    field :parent_id, String.t() | nil, default: nil
    field :progress, float(), default: 0.0
    field :created_at, DateTime.t()
    field :achieved_at, DateTime.t() | nil, default: nil
    field :metadata, map(), default: %{}
  end

  @doc """
  Creates a new Goal with a generated ID and timestamp.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(description, opts \\ []) do
    %__MODULE__{
      id: opts[:id] || generate_id(),
      description: description,
      type: opts[:type] || :achieve,
      status: opts[:status] || :active,
      priority: opts[:priority] || 50,
      parent_id: opts[:parent_id],
      progress: opts[:progress] || 0.0,
      created_at: opts[:created_at] || DateTime.utc_now(),
      achieved_at: opts[:achieved_at],
      metadata: opts[:metadata] || %{}
    }
  end

  @doc """
  Marks the goal as achieved with a timestamp.
  """
  @spec achieve(t()) :: t()
  def achieve(%__MODULE__{} = goal) do
    %{goal | status: :achieved, progress: 1.0, achieved_at: DateTime.utc_now()}
  end

  @doc """
  Marks the goal as abandoned.
  """
  @spec abandon(t(), String.t() | nil) :: t()
  def abandon(%__MODULE__{} = goal, reason \\ nil) do
    metadata = if reason, do: Map.put(goal.metadata, :abandon_reason, reason), else: goal.metadata
    %{goal | status: :abandoned, metadata: metadata}
  end

  @doc """
  Updates goal progress (0.0 to 1.0).
  """
  @spec update_progress(t(), float()) :: t()
  def update_progress(%__MODULE__{} = goal, progress) when progress >= 0.0 and progress <= 1.0 do
    %{goal | progress: progress}
  end

  defp generate_id do
    "goal_" <> Base.encode32(:crypto.strong_rand_bytes(8), case: :lower, padding: false)
  end
end

defimpl Jason.Encoder, for: Arbor.Contracts.Memory.Goal do
  def encode(goal, opts) do
    goal
    |> Map.from_struct()
    |> Map.update(:created_at, nil, &datetime_to_string/1)
    |> Map.update(:achieved_at, nil, &datetime_to_string/1)
    |> Jason.Encode.map(opts)
  end

  defp datetime_to_string(nil), do: nil
  defp datetime_to_string(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
