defmodule Arbor.Contracts.Consensus.ChangeProposal do
  @moduledoc """
  Structured schema for code change proposals submitted by the self-healing pipeline.

  Unlike free-text proposals, ChangeProposal enforces a structured format that
  evaluators can reliably parse and assess. This is required by the council for
  automated code changes.

  ## Fields

  - `:module` — The module to be modified
  - `:change_type` — Type of change (`:hot_load`, `:config_change`, `:restart`)
  - `:source_code` — New source code (for hot_load changes)
  - `:rationale` — AI-generated explanation of why this change is needed
  - `:evidence` — List of anomaly IDs and metrics supporting the change
  - `:rollback_plan` — How to undo the change if it fails
  - `:estimated_impact` — Severity/risk level (`:low`, `:medium`, `:high`)

  ## Example

      {:ok, change} = ChangeProposal.new(%{
        module: MyApp.Worker,
        change_type: :hot_load,
        source_code: "defmodule MyApp.Worker do ... end",
        rationale: "Process leak detected; adding proper cleanup",
        evidence: ["anomaly_123", "metric_high_process_count"],
        rollback_plan: "Reload previous version from disk",
        estimated_impact: :medium
      })
  """

  use TypedStruct

  @type change_type :: :hot_load | :config_change | :restart
  @type impact :: :low | :medium | :high

  typedstruct enforce: true do
    @typedoc "A structured code change proposal"

    field(:id, String.t())
    field(:module, module())
    field(:change_type, change_type())
    field(:source_code, String.t() | nil, enforce: false)
    field(:rationale, String.t())
    field(:evidence, [String.t()], default: [])
    field(:rollback_plan, String.t())
    field(:estimated_impact, impact())
    field(:config_changes, map(), default: %{}, enforce: false)
    field(:created_at, DateTime.t())
  end

  @doc """
  Create a new ChangeProposal.

  ## Required fields

  - `:module` — Module to modify
  - `:change_type` — Type of change
  - `:rationale` — Explanation for the change
  - `:rollback_plan` — How to revert if needed
  - `:estimated_impact` — Risk level

  ## Optional fields

  - `:source_code` — New source (required for `:hot_load`)
  - `:config_changes` — Config map (for `:config_change`)
  - `:evidence` — Supporting anomaly IDs/metrics
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    id = attrs[:id] || generate_id()
    now = DateTime.utc_now()

    change_type = Map.fetch!(attrs, :change_type)
    validate_change_type!(change_type, attrs)

    change_proposal = %__MODULE__{
      id: id,
      module: Map.fetch!(attrs, :module),
      change_type: change_type,
      source_code: Map.get(attrs, :source_code),
      rationale: Map.fetch!(attrs, :rationale),
      evidence: Map.get(attrs, :evidence, []),
      rollback_plan: Map.fetch!(attrs, :rollback_plan),
      estimated_impact: Map.fetch!(attrs, :estimated_impact),
      config_changes: Map.get(attrs, :config_changes, %{}),
      created_at: now
    }

    {:ok, change_proposal}
  rescue
    e in KeyError ->
      {:error, {:missing_required_field, e.key}}

    e in ArgumentError ->
      {:error, {:validation_error, e.message}}
  end

  @doc """
  Check if a change proposal is valid for submission.

  Validates:
  - Hot-load changes have source code
  - Config changes have config_changes map
  - Rollback plan is non-empty
  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = cp) do
    has_rollback_plan?(cp) and
      has_required_payload?(cp)
  end

  @doc """
  Convert a ChangeProposal to a context map suitable for Proposal.new/1.
  """
  @spec to_context(t()) :: map()
  def to_context(%__MODULE__{} = cp) do
    %{
      change_proposal: cp,
      target_module: cp.module,
      new_code: cp.source_code,
      change_type: cp.change_type,
      rationale: cp.rationale,
      evidence: cp.evidence,
      rollback_plan: cp.rollback_plan,
      estimated_impact: cp.estimated_impact
    }
  end

  # Private

  defp generate_id do
    "chg_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp validate_change_type!(:hot_load, attrs) do
    unless Map.has_key?(attrs, :source_code) do
      raise ArgumentError, "hot_load changes require :source_code"
    end
  end

  defp validate_change_type!(:config_change, attrs) do
    unless Map.has_key?(attrs, :config_changes) do
      raise ArgumentError, "config_change requires :config_changes map"
    end
  end

  defp validate_change_type!(:restart, _attrs), do: :ok

  defp validate_change_type!(type, _attrs) do
    raise ArgumentError, "invalid change_type: #{inspect(type)}"
  end

  defp has_rollback_plan?(%__MODULE__{rollback_plan: plan}) do
    is_binary(plan) and String.trim(plan) != ""
  end

  defp has_required_payload?(%__MODULE__{change_type: :hot_load, source_code: code}) do
    is_binary(code) and String.trim(code) != ""
  end

  defp has_required_payload?(%__MODULE__{change_type: :config_change, config_changes: changes}) do
    is_map(changes) and map_size(changes) > 0
  end

  defp has_required_payload?(%__MODULE__{change_type: :restart}), do: true
  defp has_required_payload?(_), do: false
end
