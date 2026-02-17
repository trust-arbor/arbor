defmodule Arbor.Orchestrator.Eval.PersistenceBridge do
  @moduledoc """
  Runtime bridge from arbor_orchestrator (Standalone) to arbor_persistence (Level 1).

  Uses `Code.ensure_loaded?/1` + `apply/3` to avoid compile-time dependency.
  Falls back to RunStore JSON files when persistence is unavailable.
  """

  require Logger

  @persistence Arbor.Persistence
  @fallback Arbor.Orchestrator.Eval.RunStore

  @doc "Returns true if Postgres persistence is available and the Repo is running."
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(@persistence) and
      function_exported?(@persistence, :insert_eval_run, 1) and
      repo_running?()
  rescue
    _ -> false
  end

  @doc "Create a new eval run record."
  def create_run(attrs) do
    if available?() do
      case apply(@persistence, :insert_eval_run, [attrs]) do
        {:ok, _} = ok ->
          Logger.debug("EvalPersistence: created run #{attrs[:id]} in Postgres")
          ok

        {:error, reason} ->
          Logger.warning(
            "EvalPersistence: DB insert failed: #{inspect(reason)}, falling back to JSON"
          )

          slug = run_slug(attrs)
          @fallback.save_run(slug, attrs)
          {:ok, attrs}
      end
    else
      Logger.debug("EvalPersistence: Postgres unavailable, using JSON fallback")
      slug = run_slug(attrs)
      @fallback.save_run(slug, attrs)
      {:ok, attrs}
    end
  rescue
    e ->
      Logger.warning("EvalPersistence: create_run rescue: #{Exception.message(e)}")
      slug = run_slug(attrs)
      @fallback.save_run(slug, attrs)
      {:ok, attrs}
  catch
    :exit, reason ->
      Logger.warning("EvalPersistence: create_run exit: #{inspect(reason)}")
      slug = run_slug(attrs)
      @fallback.save_run(slug, attrs)
      {:ok, attrs}
  end

  @doc "Update an existing eval run."
  def update_run(run_id, attrs) do
    if available?() do
      apply(@persistence, :update_eval_run, [run_id, attrs])
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("EvalPersistence: update_run rescue: #{Exception.message(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("EvalPersistence: update_run exit: #{inspect(reason)}")
      :ok
  end

  @doc "Insert a single eval result."
  def save_result(attrs) do
    if available?() do
      apply(@persistence, :insert_eval_result, [attrs])
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("EvalPersistence: save_result rescue: #{Exception.message(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("EvalPersistence: save_result exit: #{inspect(reason)}")
      :ok
  end

  @doc "Batch insert eval results."
  def save_results_batch(results) do
    if available?() do
      apply(@persistence, :insert_eval_results_batch, [results])
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Mark a run as completed with final metrics."
  def complete_run(run_id, metrics, sample_count, duration_ms) do
    update_run(run_id, %{
      status: "completed",
      metrics: metrics,
      sample_count: sample_count,
      duration_ms: duration_ms
    })
  end

  @doc "Mark a run as failed with error message."
  def fail_run(run_id, error) do
    update_run(run_id, %{
      status: "failed",
      error: to_string(error)
    })
  end

  @doc "List eval runs with optional filters."
  def list_runs(filters \\ []) do
    if available?() do
      apply(@persistence, :list_eval_runs, [filters])
    else
      fallback_list(filters)
    end
  rescue
    _ -> fallback_list(filters)
  catch
    :exit, _ -> fallback_list(filters)
  end

  @doc "Get a single eval run with results."
  def get_run(run_id) do
    if available?() do
      apply(@persistence, :get_eval_run, [run_id])
    else
      @fallback.load_run(run_id)
    end
  rescue
    _ -> @fallback.load_run(run_id)
  catch
    :exit, _ -> @fallback.load_run(run_id)
  end

  @doc "Compare models within a domain."
  def compare_models(domain, models) do
    if available?() do
      apply(@persistence, :eval_model_comparison, [domain, models])
    else
      {:ok, []}
    end
  rescue
    _ -> {:ok, []}
  catch
    :exit, _ -> {:ok, []}
  end

  @doc "Generate a unique run ID."
  @spec generate_run_id(String.t(), String.t()) :: String.t()
  def generate_run_id(model, domain) do
    slug = model |> String.replace(~r/[:\/.]+/, "-") |> String.downcase()
    date = Date.utc_today() |> Date.to_iso8601()
    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    "#{slug}-#{domain}-#{date}-#{suffix}"
  end

  # --- Private ---

  defp repo_running? do
    repo = Arbor.Persistence.Repo

    if Code.ensure_loaded?(repo) do
      # Check if the Repo process is actually registered
      case Process.whereis(repo) do
        pid when is_pid(pid) -> Process.alive?(pid)
        nil -> false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp fallback_list(filters) do
    case @fallback.list_runs(filters) do
      runs when is_list(runs) -> {:ok, runs}
      other -> other
    end
  end

  defp run_slug(%{id: id}) when is_binary(id), do: id
  defp run_slug(%{"id" => id}) when is_binary(id), do: id

  defp run_slug(%{model: model, domain: domain}) do
    generate_run_id(model, domain)
  end

  defp run_slug(%{"model" => model, "domain" => domain}) do
    generate_run_id(model, domain)
  end

  defp run_slug(_), do: "eval-#{System.os_time(:millisecond)}"
end
