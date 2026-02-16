defmodule Arbor.Persistence.Schemas.EvalRun do
  @moduledoc """
  Ecto schema for LLM evaluation runs.

  Each run evaluates a specific model against a dataset using one or more
  graders, tracking quality metrics and timing data for historical comparison.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Arbor.Persistence.Schemas.EvalResult

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "eval_runs" do
    field :domain, :string
    field :model, :string
    field :provider, :string
    field :dataset, :string
    field :graders, {:array, :string}, default: []
    field :sample_count, :integer, default: 0
    field :duration_ms, :integer, default: 0
    field :metrics, :map, default: %{}
    field :config, :map, default: %{}
    field :status, :string, default: "running"
    field :error, :string
    field :metadata, :map, default: %{}

    has_many :results, EvalResult, foreign_key: :run_id

    timestamps()
  end

  @valid_domains ~w(coding chat heartbeat embedding advisory_consultation llm_judge)
  @valid_statuses ~w(running completed failed)

  @required_fields [:id, :domain, :model, :provider, :dataset]
  @optional_fields [
    :graders,
    :sample_count,
    :duration_ms,
    :metrics,
    :config,
    :status,
    :error,
    :metadata
  ]

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:domain, @valid_domains)
    |> validate_inclusion(:status, @valid_statuses)
  end
end
