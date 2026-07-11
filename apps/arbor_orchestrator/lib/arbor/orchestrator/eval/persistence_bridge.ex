defmodule Arbor.Orchestrator.Eval.PersistenceBridge do
  @moduledoc """
  DEPRECATED: use `Arbor.Persistence` high-level eval APIs instead.

  Thin compatibility delegate kept for one deprecation interval. All logic
  lives in `arbor_persistence` (`Arbor.Persistence` facade).
  """

  @doc "Returns true if Postgres persistence is available and the Repo is running."
  @spec available?() :: boolean()
  def available?, do: Arbor.Persistence.eval_database_available?()

  @doc "Create a new eval run record (identity capture + backend selection)."
  def create_run(attrs), do: Arbor.Persistence.create_eval_run(attrs)

  @doc "Update an existing eval run."
  def update_run(run_id, attrs), do: Arbor.Persistence.update_eval_run(run_id, attrs, [])

  @doc "Insert a single eval result."
  def save_result(attrs), do: Arbor.Persistence.save_eval_result(attrs)

  @doc "Batch insert eval results."
  def save_results_batch(results), do: Arbor.Persistence.save_eval_results_batch(results)

  @doc "Mark a run as completed with final metrics."
  def complete_run(run_id, metrics, sample_count, duration_ms) do
    Arbor.Persistence.complete_eval_run(run_id, metrics, sample_count, duration_ms)
  end

  @doc "Mark a run as failed with error message."
  def fail_run(run_id, error), do: Arbor.Persistence.fail_eval_run(run_id, error)

  @doc "List eval runs with optional filters."
  def list_runs(filters \\ []), do: Arbor.Persistence.list_eval_runs(filters, [])

  @doc "Get a single eval run with results."
  def get_run(run_id), do: Arbor.Persistence.get_eval_run(run_id, [])

  @doc "Compare models within a domain."
  def compare_models(domain, models),
    do: Arbor.Persistence.eval_model_comparison(domain, models, [])

  @doc "Generate a unique run ID."
  @spec generate_run_id(String.t(), String.t()) :: String.t()
  def generate_run_id(model, domain), do: Arbor.Persistence.generate_eval_run_id(model, domain)
end
