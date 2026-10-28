defmodule Arbor.Persistence.Schemas.EvalResult do
  @moduledoc """
  Ecto schema for individual evaluation results within a run.

  Each result records a single sample evaluation: the LLM's response,
  grader scores, timing data (total duration, time to first token),
  and token count.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Arbor.Persistence.Schemas.EvalRun

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "eval_results" do
    field :sample_id, :string
    field :input, :string
    field :expected, :string
    field :actual, :string
    field :passed, :boolean, default: false
    field :scores, :map, default: %{}
    field :duration_ms, :integer, default: 0
    field :ttft_ms, :integer
    field :tokens_generated, :integer
    # Layer-2 (agent-in-the-loop) metrics — first-class for SQL trending.
    field :cost, :float
    field :prompt_tokens, :integer
    field :total_tokens, :integer
    field :tool_call_count, :integer
    field :precondition_met, :boolean
    field :metadata, :map, default: %{}

    belongs_to :run, EvalRun, type: :string, foreign_key: :run_id

    timestamps(updated_at: false)
  end

  @required_fields [:id, :run_id, :sample_id]
  @optional_fields [
    :input,
    :expected,
    :actual,
    :passed,
    :scores,
    :duration_ms,
    :ttft_ms,
    :tokens_generated,
    :cost,
    :prompt_tokens,
    :total_tokens,
    :tool_call_count,
    :precondition_met,
    :metadata
  ]

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:run_id)
  end
end
