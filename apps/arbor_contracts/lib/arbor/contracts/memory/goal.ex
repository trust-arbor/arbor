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
  @type goal_status :: :active | :achieved | :failed | :abandoned | :blocked

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
    field :deadline, DateTime.t() | nil, default: nil
    field :success_criteria, String.t() | nil, default: nil
    field :notes, [String.t()], default: []
    field :assigned_by, atom() | nil, default: nil
    field :metadata, map(), default: %{}
    field :referenced_date, DateTime.t() | nil, default: nil
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
      deadline: opts[:deadline],
      success_criteria: opts[:success_criteria],
      notes: opts[:notes] || [],
      assigned_by: opts[:assigned_by],
      metadata: opts[:metadata] || %{},
      referenced_date: opts[:referenced_date]
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

  @doc """
  Marks the goal as failed with an optional reason.

  Adds a "Failed: reason" note to the notes list.
  """
  @spec fail(t(), String.t() | nil) :: t()
  def fail(%__MODULE__{} = goal, reason \\ nil) do
    notes = if reason, do: ["Failed: #{reason}" | goal.notes], else: goal.notes
    %{goal | status: :failed, notes: notes}
  end

  @doc """
  Adds a note to the goal's notes list (prepended).
  """
  @spec add_note(t(), String.t()) :: t()
  def add_note(%__MODULE__{} = goal, note) when is_binary(note) do
    %{goal | notes: [note | goal.notes]}
  end

  @doc """
  Returns true if the goal is past its deadline.

  Returns false if no deadline is set.
  """
  @spec overdue?(t()) :: boolean()
  def overdue?(%__MODULE__{deadline: nil}), do: false

  def overdue?(%__MODULE__{deadline: deadline}) do
    DateTime.compare(DateTime.utc_now(), deadline) == :gt
  end

  @doc """
  Computes a dynamic urgency score based on priority and deadline proximity.

  Returns a float where higher values indicate more urgent goals.
  Base score is `priority / 100.0`, multiplied by a deadline factor:
  - No deadline: 1.0
  - Overdue: 2.0
  - < 1 hour: 1.8
  - < 24 hours: 1.5
  - < 7 days: 1.2
  - Otherwise: 1.0
  """
  @spec urgency(t()) :: float()
  def urgency(%__MODULE__{} = goal) do
    base_score = goal.priority / 100.0

    deadline_factor =
      case goal.deadline do
        nil ->
          1.0

        deadline ->
          seconds_remaining = DateTime.diff(deadline, DateTime.utc_now(), :second)

          cond do
            seconds_remaining <= 0 -> 2.0
            seconds_remaining <= 3600 -> 1.8
            seconds_remaining <= 86_400 -> 1.5
            seconds_remaining <= 604_800 -> 1.2
            true -> 1.0
          end
      end

    Float.round(base_score * deadline_factor, 3)
  end

  @doc """
  Formats the goal for inclusion in LLM prompts.

  Includes priority, description, deadline, progress percentage,
  and success criteria when available.

  ## Example

      Goal.to_prompt_format(goal)
      #=> "[P80] Fix authentication (deadline: 2026-02-10T15:30:00Z) [65%]\\n     Success when: OAuth flow works"
  """
  @spec to_prompt_format(t()) :: String.t()
  def to_prompt_format(%__MODULE__{} = goal) do
    deadline_str =
      if goal.deadline, do: " (deadline: #{DateTime.to_iso8601(goal.deadline)})", else: ""

    progress_str = " [#{round(goal.progress * 100)}%]"

    criteria_str =
      if goal.success_criteria,
        do: "\n     Success when: #{goal.success_criteria}",
        else: ""

    "[P#{goal.priority}] #{goal.description}#{deadline_str}#{progress_str}#{criteria_str}"
  end

  @doc """
  Returns true if the goal is in a terminal state (achieved, failed, or abandoned).
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in [:achieved, :failed, :abandoned]

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
    |> Map.update(:deadline, nil, &datetime_to_string/1)
    |> Map.update(:referenced_date, nil, &datetime_to_string/1)
    |> Jason.Encode.map(opts)
  end

  defp datetime_to_string(nil), do: nil
  defp datetime_to_string(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
