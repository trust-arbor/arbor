defmodule Arbor.Agent.RuntimeAdmission.GuardedRestoreWorker do
  @moduledoc """
  Fixed guarded-restore effect worker (Phase 4C C3C1a1).

  Starts blocked on an unforgeable gate ref released only after IntentOwner
  durable-binds the claim, acks TaskStore effect handoff, and binds this PID.
  Invokes the narrow Lifecycle guarded path — never Lifecycle.start/2.

  Durable claim settlement is driven only after TaskStore accepts the exact
  source-authenticated worker terminal (not by the public shell).
  """

  alias Arbor.Agent.Lifecycle
  alias Arbor.Agent.Orchestration.TaskStore
  alias Arbor.Agent.RuntimeAdmission.IntentCore
  alias Arbor.Agent.TemplateAuthorityReconciliationStore

  @default_gate_timeout_ms 30_000

  @doc false
  def run(
        %{
          intent_id: intent_id,
          target_agent_id: target,
          fingerprint: fingerprint,
          operation_id: operation_id,
          restore_token: restore_token,
          store_ref: store_ref,
          gate_ref: gate_ref
        } = args
      )
      when is_binary(intent_id) and is_binary(target) and is_binary(fingerprint) and
             is_binary(operation_id) and is_binary(restore_token) and is_reference(gate_ref) do
    timeout = Map.get(args, :gate_timeout_ms, @default_gate_timeout_ms)

    receive do
      {:runtime_admission_release, ^gate_ref} ->
        maybe_test_hold()
        run_effects(intent_id, target, fingerprint, operation_id, restore_token, store_ref)
    after
      timeout ->
        # Never ran Lifecycle effects without authenticated bind+handoff+release.
        # Pre-effect (no handoff release): do not invent durable not_applied here;
        # owner stop / TaskStore paths handle pre-effect terminals.
        :ok
    end
  end

  defp run_effects(intent_id, target, fingerprint, operation_id, restore_token, store_ref) do
    witness = %{
      v: 1,
      kind: :guarded_restore,
      intent_id: intent_id,
      fingerprint: fingerprint,
      operation_id: operation_id,
      token: restore_token
    }

    result =
      try do
        invoke_guarded_restore_effects(target, witness, store_ref)
      rescue
        # Never forward raw exception messages (may embed paths/tokens).
        _e -> {:error, :guarded_restore_exception}
      catch
        :exit, _reason -> {:error, :guarded_restore_exit}
        _kind, _reason -> {:error, :guarded_restore_failure}
      end

    settle(store_ref, target, intent_id, restore_token, result)
    :ok
  end

  if Mix.env() == :test do
    defp maybe_test_hold do
      case Application.get_env(:arbor_agent, :runtime_admission_test_hold) do
        %{timeout_ms: ms} when is_integer(ms) and ms > 0 ->
          receive do
            :runtime_admission_release_hold -> :ok
          after
            ms -> :ok
          end

        _ ->
          :ok
      end
    end

    # W9 deterministic seam: kill worker after TaskStore accepted the terminal
    # but before this process performs durable settle (shell must converge).
    defp maybe_test_crash_after_taskstore_settle do
      case Application.get_env(:arbor_agent, :runtime_admission_test_crash_after_taskstore_settle) do
        true -> Process.exit(self(), :kill)
        _ -> :ok
      end
    end

    defp invoke_guarded_restore_effects(target, witness, store_ref) do
      Lifecycle.guarded_restore_effects_for_test_store(target, witness, store_ref)
    end
  else
    defp maybe_test_hold, do: :ok
    defp maybe_test_crash_after_taskstore_settle, do: :ok

    defp invoke_guarded_restore_effects(target, witness, _store_ref) do
      Lifecycle.guarded_restore_effects(target, witness)
    end
  end

  # Source-authenticated path: only after TaskStore accepts this worker's terminal
  # may durable claim settlement advance (applied / failed / conflict).
  #
  # W9: TaskStore also launches a fixed outside-callback durable settle shell on
  # accept, so a crash between TaskStore :ok and this worker durable settle still
  # converges (exact branch → applied; mismatch → outcome_unknown).
  defp settle(store_ref, target, intent_id, token, result) do
    task_outcome = task_store_outcome(result)

    case TaskStore.settle_runtime_admission(target, intent_id, task_outcome, name: store_ref) do
      :ok ->
        maybe_test_crash_after_taskstore_settle()
        # Best-effort local settle; shell is authoritative for the crash window.
        durable_settle_after_taskstore_accept(target, token, task_outcome)

      {:error, _} ->
        # First terminal already won or auth failed — do not force durable settle.
        :ok
    end
  catch
    :exit, _ -> :ok
  end

  # Close reasons before TaskStore settlement — never forward raw exception/
  # exit/unexpected terms that may embed secrets.
  defp task_store_outcome({:ok, pid}) when is_pid(pid), do: {:applied, pid}

  defp task_store_outcome({:error, reason}),
    do: {:error, IntentCore.redact_error_reason(reason)}

  defp task_store_outcome(_other), do: {:error, :unexpected_result}

  defp durable_settle_after_taskstore_accept(target, token, {:applied, _pid}) do
    settlement = %{
      "outcome" => "applied",
      "reason_code" => "branch_restored",
      "at_unix_ms" => System.system_time(:millisecond)
    }

    _ =
      TemplateAuthorityReconciliationStore.settle_runtime_restore_admission(
        target,
        token,
        settlement
      )

    :ok
  catch
    :exit, _ -> :ok
  end

  defp durable_settle_after_taskstore_accept(target, token, {:error, reason}) do
    {outcome, reason_code} = classify_worker_terminal(IntentCore.redact_error_reason(reason))

    settlement = %{
      "outcome" => outcome,
      "reason_code" => reason_code,
      "at_unix_ms" => System.system_time(:millisecond)
    }

    _ =
      TemplateAuthorityReconciliationStore.settle_runtime_restore_admission(
        target,
        token,
        settlement
      )

    :ok
  catch
    :exit, _ -> :ok
  end

  # Closed classification from redacted worker terminal only.
  defp classify_worker_terminal(:witness_mismatch), do: {"conflict", "witness_mismatch"}
  defp classify_worker_terminal(:conflict), do: {"conflict", "conflict"}
  defp classify_worker_terminal(:pre_effect_abort), do: {"not_applied", "pre_effect_abort"}
  defp classify_worker_terminal(:owner_down), do: {"not_applied", "pre_effect_abort"}

  defp classify_worker_terminal(reason) when is_atom(reason) do
    code = Atom.to_string(reason)

    if Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, code) and byte_size(code) <= 64 do
      {"failed", code}
    else
      {"failed", "worker_failed"}
    end
  end

  defp classify_worker_terminal(_), do: {"failed", "worker_failed"}
end
