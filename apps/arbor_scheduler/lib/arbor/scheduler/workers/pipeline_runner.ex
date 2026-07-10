defmodule Arbor.Scheduler.Workers.PipelineRunner do
  @moduledoc """
  Oban worker that executes an exactly attested DOT pipeline.

  The job payload identifies a pipeline and repeats its reviewed initial
  arguments. It never supplies execution authority. The sibling version 2
  manifest is authoritative for the canonical DOT identity, SHA-256, workdir,
  initial values, issuer, and capability envelope.

  `Arbor.Orchestrator.run_file_as/4` is dispatched through `apply/3` to avoid a
  compile-time dependency on the higher-level orchestrator app. Until that
  facade is available, jobs fail with a retryable, explicit error.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Arbor.Scheduler.{CapsFile, PipelinePaths, RunIdentity}

  @workdir_not_supplied :__scheduler_workdir_not_supplied__

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pipeline_path" => path} = job_args}) when is_binary(path) do
    initial_args = Map.get(job_args, "args", %{})
    requested_workdir = Map.get(job_args, "workdir", @workdir_not_supplied)

    Logger.info("[Scheduler] Running pipeline: #{path}")

    case run_pipeline(path, initial_args, requested_workdir) do
      {:ok, _result} ->
        Logger.info("[Scheduler] Pipeline completed: #{path}")
        :ok

      {:error, :pipeline_not_found} ->
        Logger.error("[Scheduler] Pipeline file not found: #{path}")
        {:discard, "pipeline file not found: #{path}"}

      {:error, {:caps_file_missing, caps_path}} ->
        Logger.error("[Scheduler] Pipeline refused: missing #{caps_path}")
        {:discard, "missing caps file: #{caps_path}"}

      {:error, {:caps_file_invalid, reason}} ->
        Logger.error("[Scheduler] Pipeline refused: caps file invalid: #{inspect(reason)}")
        {:discard, "caps file invalid: #{inspect(reason)}"}

      {:error, {:attestation_rejected, reason}} ->
        Logger.error("[Scheduler] Pipeline attestation rejected: #{inspect(reason)}")
        {:discard, "pipeline attestation rejected: #{inspect(reason)}"}

      {:error, :orchestrator_unavailable} ->
        Logger.error("[Scheduler] Arbor.Orchestrator unavailable; retrying")
        {:error, :orchestrator_unavailable}

      {:error, :orchestrator_run_file_as_unavailable} ->
        Logger.error("[Scheduler] Arbor.Orchestrator.run_file_as/4 unavailable; retrying")
        {:error, :orchestrator_run_file_as_unavailable}

      {:error, reason} ->
        Logger.error("[Scheduler] Pipeline failed: #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("[Scheduler] Job args missing or invalid pipeline_path: #{inspect(args)}")
    {:discard, "missing or invalid pipeline_path"}
  end

  defp run_pipeline(path, initial_args, requested_workdir) do
    with {:ok, paths} <- PipelinePaths.resolve_pipeline(path),
         {:ok, attestation} <- load_attestation(paths.caps_path),
         :ok <- verify_pipeline_identity(paths, attestation),
         :ok <- verify_initial_args(initial_args, attestation),
         :ok <- verify_requested_workdir(requested_workdir, attestation),
         :ok <- verify_attested_workdir(attestation),
         {:ok, orchestrator} <- orchestrator_module() do
      execute_with_attestation(orchestrator, paths, attestation)
    else
      {:error, :pipeline_not_found} = error -> error
      {:error, {:caps_file_missing, _}} = error -> error
      {:error, {:caps_file_invalid, _}} = error -> error
      {:error, :orchestrator_unavailable} = error -> error
      {:error, :orchestrator_run_file_as_unavailable} = error -> error
      {:error, reason} -> {:error, {:attestation_rejected, reason}}
    end
  rescue
    exception ->
      Logger.error("[Scheduler] PipelineRunner exception: #{inspect(exception)}")
      {:error, {:exception, Exception.message(exception)}}
  catch
    :exit, reason ->
      Logger.error("[Scheduler] PipelineRunner exit: #{inspect(reason)}")
      {:error, {:exit, reason}}

    :throw, value ->
      Logger.error("[Scheduler] PipelineRunner throw: #{inspect(value)}")
      {:error, {:throw, value}}
  end

  defp load_attestation(caps_path) do
    case CapsFile.load(caps_path) do
      {:ok, attestation} -> {:ok, attestation}
      {:error, reason} -> {:error, {:caps_file_invalid, reason}}
    end
  end

  defp verify_pipeline_identity(paths, attestation) do
    actual = %{root: paths.root_id, path: paths.relative_path}
    expected = %{root: attestation.pipeline_root, path: attestation.pipeline_path}

    if actual == expected,
      do: :ok,
      else: {:error, {:pipeline_identity_mismatch, expected, actual}}
  end

  defp verify_initial_args(initial_args, attestation) do
    if CapsFile.initial_args_match?(initial_args, attestation.initial_args),
      do: :ok,
      else: {:error, :initial_args_mismatch}
  end

  defp verify_requested_workdir(@workdir_not_supplied, _attestation), do: :ok

  defp verify_requested_workdir(workdir, attestation) do
    if workdir == attestation.workdir,
      do: :ok,
      else: {:error, :workdir_mismatch}
  end

  defp verify_attested_workdir(attestation) do
    case revalidate_workdir(attestation.workdir) do
      {:ok, _canonical_workdir} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp orchestrator_module do
    orchestrator =
      Application.get_env(:arbor_scheduler, :orchestrator_module, Arbor.Orchestrator)

    cond do
      not Code.ensure_loaded?(orchestrator) ->
        {:error, :orchestrator_unavailable}

      not function_exported?(orchestrator, :run_file_as, 4) ->
        {:error, :orchestrator_run_file_as_unavailable}

      true ->
        {:ok, orchestrator}
    end
  end

  defp execute_with_attestation(orchestrator, paths, attestation) do
    case RunIdentity.mint(attestation) do
      {:ok, handle} ->
        try do
          with :ok <- revalidate_paths(paths),
               {:ok, actual_hash} <- PipelinePaths.hash_file(paths.path),
               :ok <- verify_graph_hash(attestation.graph_hash, actual_hash),
               {:ok, canonical_workdir} <- revalidate_workdir(attestation.workdir) do
            # The hash check is intentionally the final scheduler operation
            # on the DOT. Workdir resolution then runs immediately before
            # dispatch so a replacement or symlink race cannot redirect the
            # reviewed run. run_file_as/4 independently rechecks the expected
            # graph hash while reading the DOT for Engine execution.
            # credo:disable-for-next-line Credo.Check.Refactor.Apply
            apply(orchestrator, :run_file_as, [
              paths.path,
              handle.agent_id,
              handle.signer,
              [
                graph_hash: attestation.graph_hash,
                workdir: canonical_workdir,
                initial_values: attestation.initial_args,
                author_id: attestation.issuer_id
              ]
            ])
          else
            {:error, reason} -> {:error, {:attestation_rejected, reason}}
          end
        after
          RunIdentity.revoke(handle)
        end

      {:error, reason} ->
        {:error, {:attestation_rejected, {:run_identity_failed, reason}}}
    end
  end

  defp revalidate_paths(expected) do
    case PipelinePaths.resolve_pipeline(expected.path) do
      {:ok, ^expected} -> :ok
      {:ok, _changed} -> {:error, :pipeline_path_changed}
      {:error, reason} -> {:error, {:pipeline_path_changed, reason}}
    end
  end

  defp revalidate_workdir(expected) do
    case PipelinePaths.resolve_workdir(expected) do
      {:ok, ^expected} -> {:ok, expected}
      {:ok, _changed} -> {:error, :attested_workdir_changed}
      {:error, reason} -> {:error, {:attested_workdir_invalid, reason}}
    end
  end

  defp verify_graph_hash(expected, expected), do: :ok

  defp verify_graph_hash(expected, actual),
    do: {:error, {:graph_hash_mismatch, expected, actual}}
end
