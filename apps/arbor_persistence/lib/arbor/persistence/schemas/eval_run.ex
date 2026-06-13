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
    field(:domain, :string)
    field(:model, :string)
    field(:provider, :string)
    field(:dataset, :string)
    field(:graders, {:array, :string}, default: [])
    field(:sample_count, :integer, default: 0)
    field(:duration_ms, :integer, default: 0)
    field(:metrics, :map, default: %{})
    field(:config, :map, default: %{})
    field(:status, :string, default: "running")
    field(:error, :string)
    field(:metadata, :map, default: %{})

    # Run identity — binds results to the code, model serving identity,
    # dataset contents, and config under test, so longitudinal comparison
    # ("did this change improve the system?") is a query instead of guesswork.
    # See .arbor/roadmap/1-brainstorming/eval-system-architecture.md.
    field(:git_sha, :string)
    field(:git_dirty, :boolean)
    field(:quant, :string)
    field(:endpoint, :string)
    field(:dataset_hash, :string)
    field(:config_fingerprint, :string)
    field(:layer, :string)
    field(:task_id, :string)

    has_many(:results, EvalResult, foreign_key: :run_id)

    timestamps()
  end

  @valid_domains ~w(coding arbor_coding chat heartbeat embedding advisory_consultation llm_judge security_verify council_decision memory_ablation effective_window summarization preprocessor_tool_retrieval preprocessor_tool_retrieval_llm preprocessor_tool_retrieval_hybrid dot_compilation)
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
    :metadata,
    :git_sha,
    :git_dirty,
    :quant,
    :endpoint,
    :dataset_hash,
    :config_fingerprint,
    :layer,
    :task_id
  ]

  @valid_layers ~w(task system)

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:domain, @valid_domains)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:layer, @valid_layers)
  end
end
