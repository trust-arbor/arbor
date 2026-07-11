defmodule Arbor.Orchestrator.Eval.RunStore do
  @moduledoc """
  DEPRECATED: use `Arbor.Persistence` file-store eval APIs instead.

  Thin compatibility delegate kept for one deprecation interval. All logic
  lives in `arbor_persistence` (`Arbor.Persistence` facade).
  """

  @doc "Saves a run to disk."
  @spec save_run(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def save_run(run_id, run_data, opts \\ []) do
    Arbor.Persistence.save_eval_run_file(run_id, run_data, opts)
  end

  @doc "Loads a run from disk."
  @spec load_run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def load_run(run_id, opts \\ []) do
    Arbor.Persistence.load_eval_run_file(run_id, opts)
  end

  @doc "Lists all runs, sorted by timestamp (newest first). Filterable by model/provider."
  @spec list_runs(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_runs(opts \\ []) do
    Arbor.Persistence.list_eval_run_files(opts)
  end

  @doc "Returns the most recent run matching optional filters."
  @spec latest_run(keyword()) :: {:ok, map()} | {:error, :no_runs}
  def latest_run(opts \\ []) do
    Arbor.Persistence.latest_eval_run_file(opts)
  end

  @doc "Compares metrics between two runs."
  @spec compare_runs(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def compare_runs(run_id_a, run_id_b, opts \\ []) do
    Arbor.Persistence.compare_eval_run_files(run_id_a, run_id_b, opts)
  end
end
