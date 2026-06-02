defmodule Arbor.Scheduler.Workers.PipelineRunner do
  @moduledoc """
  Oban worker that loads and runs a DOT pipeline.

  Invoked by `Arbor.Scheduler.enqueue_pipeline/3` (and the
  `schedule_*` variants). The actual pipeline execution is delegated to
  `Arbor.Orchestrator.Engine` at runtime via `apply/3` so we don't take
  a compile-time dep on arbor_orchestrator from this app.

  ## Args contract

  Oban jobs serialize their `args` to JSON in the database, so all keys
  are strings on the receive side.

      %{
        "pipeline_path" => "scheduled/upstream_deps_check.dot",
        "args"          => %{"repos" => [...]}      # initial context
      }

  ## Return values

  - `:ok` — pipeline ran to completion successfully
  - `{:error, reason}` — Oban will retry per `max_attempts`

  Unrecoverable errors (pipeline file not found, etc.) should return
  `{:discard, reason}` to skip retries.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pipeline_path" => path} = args}) do
    initial_context = Map.get(args, "args", %{})

    Logger.info("[Scheduler] Running pipeline: #{path}")

    case run_pipeline(path, initial_context) do
      {:ok, _result} ->
        Logger.info("[Scheduler] Pipeline completed: #{path}")
        :ok

      {:error, :pipeline_not_found} ->
        Logger.error("[Scheduler] Pipeline file not found: #{path}")
        {:discard, "pipeline file not found: #{path}"}

      {:error, :orchestrator_unavailable} ->
        Logger.error("[Scheduler] Arbor.Orchestrator unavailable — retry")
        {:error, :orchestrator_unavailable}

      {:error, reason} ->
        Logger.error("[Scheduler] Pipeline failed: #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("[Scheduler] Job args missing :pipeline_path: #{inspect(args)}")
    {:discard, "missing pipeline_path"}
  end

  # Runtime dispatch to the orchestrator so arbor_scheduler doesn't take
  # a compile-time dep on arbor_orchestrator. The orchestrator module
  # surface this worker targets is subject to refinement as the
  # scheduler matures — start with the simplest viable shape.
  defp run_pipeline(path, context) do
    orchestrator = Arbor.Orchestrator

    cond do
      # Check inputs (cheap, deterministic) before dispatching. A missing
      # pipeline file is unrecoverable regardless of orchestrator state,
      # so it wins over orchestrator-unavailable (which could be a
      # transient startup race the operator hits during deploy).
      not File.exists?(path) ->
        {:error, :pipeline_not_found}

      not Code.ensure_loaded?(orchestrator) ->
        {:error, :orchestrator_unavailable}

      true ->
        # Orchestrator.run_file/2 accepts opts including :initial_values
        # which seeds the pipeline's shared context.
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(orchestrator, :run_file, [path, [initial_values: context]])
    end
  rescue
    e ->
      Logger.error("[Scheduler] PipelineRunner exception: #{inspect(e)}")
      {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason ->
      Logger.error("[Scheduler] PipelineRunner exit: #{inspect(reason)}")
      {:error, {:exit, reason}}

    :throw, value ->
      Logger.error("[Scheduler] PipelineRunner throw: #{inspect(value)}")
      {:error, {:throw, value}}
  end
end
