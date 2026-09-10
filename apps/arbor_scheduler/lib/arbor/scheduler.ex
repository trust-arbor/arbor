defmodule Arbor.Scheduler do
  @moduledoc """
  Public facade for scheduling Arbor work.

  Arbor.Scheduler runs DOT pipelines and Jido actions on a schedule
  (cron-style or one-shot). The scheduling substrate is Oban, but
  callers should not depend on Oban directly — use this facade.

  ## Surfaces (MVP)

  - `schedule_pipeline_at/2` — fire a pipeline once at a future time
  - `schedule_pipeline_in/2` — fire a pipeline after a delay
  - `enqueue_pipeline/2` — enqueue a pipeline to run immediately on
    the next available worker

  Cron-style recurring schedules are configured under `:arbor_scheduler,
  Oban` (the `:cron` plugin's `:crontab` list) and managed declaratively
  rather than imperatively in this first cut — operators add or remove
  entries by editing config and restarting (or hot-reloading). A
  runtime-mutable cron API can land later if the static-config model
  proves limiting.

  ## Example

      Arbor.Scheduler.enqueue_pipeline(
        "scheduled/upstream_deps_check.dot",
        %{repos: ["~/code/hermes-agent", "~/code/openclaw"]}
      )

  ## Related

  - `Arbor.Scheduler.Workers.PipelineRunner` — the Oban worker that
    actually loads and runs the pipeline.
  - `.arbor/roadmap/1-brainstorming/oban-background-jobs.md` — broader
    context for the Oban choice.
  - `.arbor/roadmap/1-brainstorming/arbor-jobs-agent-marketplace.md` —
    the *different* future concept; do not conflate.
  - `.arbor/roadmap/1-brainstorming/priorities-2026-06-02.md` — H1.
  """

  alias Arbor.Scheduler.Workers.PipelineRunner

  @doc "Canonical bytes for a closed owner-bound enqueue/list/cancel request. No authorization is conferred."
  defdelegate routine_request_payload(operation, value),
    to: Arbor.Scheduler.Cores.RoutineCore,
    as: :payload

  @doc "Prepare an exact routine intent from the current catalog and held caps; the result still requires the owner's signature."
  defdelegate prepare_routine_intent(principal, routine, scheduled_at, request_id),
    to: Arbor.Scheduler.OwnedRoutines,
    as: :prepare

  @doc "Enqueue one exact owner-signed routine. Caller-supplied ownership fields are not accepted."
  defdelegate enqueue_routine(intent, proof), to: Arbor.Scheduler.OwnedRoutines, as: :enqueue

  @doc "List bounded, signature-verified projections belonging to the freshly authenticated caller."
  defdelegate list_owned_routines(filters, proof), to: Arbor.Scheduler.OwnedRoutines, as: :list

  @doc "Cancel the authenticated owner's exact stored job. Previously admitted effects are not rolled back."
  defdelegate cancel_owned_routine(id, proof), to: Arbor.Scheduler.OwnedRoutines, as: :cancel

  @doc false
  defdelegate authorize_routine_effect(token, effect), to: Arbor.Scheduler.RunLease

  @doc false
  defdelegate routine_effect_requirement(principal),
    to: Arbor.Scheduler.RunLease,
    as: :routine_requirement

  @doc """
  Build the Oban changeset for a pipeline job WITHOUT inserting it.

  Useful in tests (no Repo needed to verify shape) and for callers that
  want to inspect or batch-insert. Most application code should call
  `enqueue_pipeline/3` instead.
  """
  @spec build_pipeline_job(String.t(), map(), keyword()) :: Ecto.Changeset.t()
  def build_pipeline_job(pipeline_path, args \\ %{}, opts \\ []) do
    PipelineRunner.new(
      %{"pipeline_path" => pipeline_path, "args" => args},
      opts
    )
  end

  @doc """
  Enqueue a pipeline to run on the next available worker (no delay).

  ## Parameters

    * `pipeline_path` — path to a DOT file under the configured
      pipelines root (or absolute). Resolution happens in the worker.
    * `args` — JSON-clean map that must exactly match the signed version 2
      attestation. The worker executes the attested copy, never this job copy.
    * `opts` — passed to `Oban.insert/1`:
      * `:queue` — default `:default`
      * `:max_attempts` — default `3` per the worker definition
      * `:unique` — Oban uniqueness keys (see Oban docs)
      * `:schedule_in` / `:scheduled_at` — defer execution
  """
  @spec enqueue_pipeline(String.t(), map(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_pipeline(pipeline_path, args \\ %{}, opts \\ []) do
    pipeline_path
    |> build_pipeline_job(args, opts)
    |> Oban.insert()
  end

  @doc """
  Schedule a pipeline to run after a delay (in seconds).
  """
  @spec schedule_pipeline_in(String.t(), pos_integer(), map(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def schedule_pipeline_in(pipeline_path, delay_seconds, args \\ %{}, opts \\ [])
      when is_integer(delay_seconds) and delay_seconds > 0 do
    enqueue_pipeline(pipeline_path, args, Keyword.put(opts, :schedule_in, delay_seconds))
  end

  @doc """
  Schedule a pipeline to run at an absolute UTC time.
  """
  @spec schedule_pipeline_at(String.t(), DateTime.t(), map(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def schedule_pipeline_at(pipeline_path, %DateTime{} = at, args \\ %{}, opts \\ []) do
    enqueue_pipeline(pipeline_path, args, Keyword.put(opts, :scheduled_at, at))
  end
end
