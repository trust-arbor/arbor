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

  alias Arbor.Scheduler.Identity

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
        # (seeds the pipeline's shared context) and :signer (a function
        # the CapabilityCheck middleware uses to mint a signed_request
        # per node). The scheduler is a system actor with its own
        # cryptographic identity (Arbor.Scheduler.Identity) — see that
        # module's moduledoc for the provenance + audit story.
        #
        # Two values must agree for CapabilityCheck to pass:
        #   1. assigns.agent_id — sourced from context["session.agent_id"]
        #   2. assigns.signer   — sourced from opts[:signer]
        # The signed_request the signer mints carries its own principal;
        # if it doesn't match assigns.agent_id the middleware rejects
        # with :identity_mismatch. So we seed both from the same Identity.
        seeded_context = seed_session_identity(context, Identity.agent_id())
        signer = Identity.signer()

        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(orchestrator, :run_file, [
          path,
          [
            initial_values: seeded_context,
            signer: signer
          ]
        ])
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

  @doc """
  Build the initial pipeline context with the scheduler's authoritative
  `session.agent_id`.

  Public so a security-regression test can hit it directly. Any value
  the caller (Oban args, operator, attacker) places under
  `"session.agent_id"` is overwritten by the scheduler's identity —
  the assigns layer downstream uses that key to derive the principal
  CapabilityCheck compares against the signer's signed_request.
  Without this override an attacker who controls the Oban payload
  could spoof the agent_id.

  When `identity_agent_id` is `nil` (Identity GenServer not running),
  any pre-seeded `"session.agent_id"` is stripped rather than
  preserved — fail-closed, no implicit trust of attacker-supplied
  values when the identity layer is absent.
  """
  @spec seed_session_identity(map(), String.t() | nil) :: map()
  def seed_session_identity(context, identity_agent_id) when is_map(context) do
    case identity_agent_id do
      nil -> Map.delete(context, "session.agent_id")
      id when is_binary(id) -> Map.put(context, "session.agent_id", id)
    end
  end
end
