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

  alias Arbor.Scheduler.RunIdentity

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

      {:error, {:caps_file_missing, caps_path}} ->
        # Default #3 from the privesc design discussion: a pipeline that
        # silently runs with zero caps is the exact bug shape this work is
        # trying to prevent. Refuse to start and tell the operator which
        # sibling file is expected — they can write one, sign it, and
        # re-run.
        Logger.error("[Scheduler] Pipeline refused: missing #{caps_path}")
        {:discard, "missing caps file: #{caps_path}"}

      {:error, {:caps_file_invalid, reason}} ->
        # CapsFile.load returned a specific failure mode (invalid_signature,
        # cap_exceeds_envelope, issuer_revoked, etc.). Surface the exact
        # reason so the operator can fix root cause rather than guess.
        Logger.error("[Scheduler] Pipeline refused: caps file invalid: #{inspect(reason)}")
        {:discard, "caps file invalid: #{inspect(reason)}"}

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
    caps_path = caps_path_for(path)

    cond do
      # Check inputs (cheap, deterministic) before dispatching. A missing
      # pipeline file is unrecoverable regardless of orchestrator state,
      # so it wins over orchestrator-unavailable (which could be a
      # transient startup race the operator hits during deploy).
      not File.exists?(path) ->
        {:error, :pipeline_not_found}

      not File.exists?(caps_path) ->
        # Phase 5: pipelines MUST ship a signed .caps.json sibling. The
        # scheduler-privesc redesign trades "pipelines auto-run with broad
        # system caps" for "every pipeline declares its caps explicitly,
        # signed by an enrolled issuer." Fail-closed on missing.
        {:error, {:caps_file_missing, caps_path}}

      not Code.ensure_loaded?(orchestrator) ->
        {:error, :orchestrator_unavailable}

      true ->
        execute_with_caps(orchestrator, path, caps_path, context)
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

  defp execute_with_caps(orchestrator, pipeline_path, caps_path, context) do
    case RunIdentity.mint(caps_path) do
      {:ok, handle} ->
        # Try/after guarantees caps are revoked even on pipeline crash
        # (default #2 from the design discussion). Logging the revoke
        # outcome happens inside RunIdentity.revoke — it is best-effort
        # by contract and never raises.
        try do
          seeded_context = seed_session_identity(context, handle.agent_id)

          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          apply(orchestrator, :run_file, [
            pipeline_path,
            [
              initial_values: seeded_context,
              signer: handle.signer
            ]
          ])
        after
          RunIdentity.revoke(handle)
        end

      {:error, reason} ->
        {:error, {:caps_file_invalid, reason}}
    end
  end

  defp caps_path_for(pipeline_path) do
    pipeline_path
    |> String.replace_suffix(".dot", ".caps.json")
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
