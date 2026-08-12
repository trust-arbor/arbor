defmodule Arbor.Agent.RuntimeAdmission.OrdinaryStartWorker do
  @moduledoc """
  Fixed ordinary-start effect worker (Phase 4C C3C1a0).

  Starts blocked on an unforgeable gate ref released only after the authenticated
  IntentOwner binds this exact PID in TaskStore. Executes Lifecycle ordinary-start
  effects under Orchestration.TaskSupervisor. No caller-selected modules/MFAs.
  Addresses TaskStore only by stable `store_ref`.
  """

  alias Arbor.Agent.Lifecycle
  alias Arbor.Agent.Orchestration.TaskStore

  @default_gate_timeout_ms 30_000

  @doc false
  def run(
        %{
          intent_id: intent_id,
          target_agent_id: target,
          fingerprint: fingerprint,
          validated_opts: validated_opts,
          store_ref: store_ref,
          gate_ref: gate_ref
        } = args
      )
      when is_binary(intent_id) and is_binary(target) and is_binary(fingerprint) and
             is_list(validated_opts) and is_reference(gate_ref) do
    timeout = Map.get(args, :gate_timeout_ms, @default_gate_timeout_ms)

    # Block until owner binds this PID and releases the unforgeable gate.
    receive do
      {:runtime_admission_release, ^gate_ref} ->
        maybe_test_hold()
        run_effects(intent_id, target, fingerprint, validated_opts, store_ref)
    after
      timeout ->
        # Never ran Lifecycle effects without an authenticated bind+release.
        :ok
    end
  end

  defp run_effects(intent_id, target, fingerprint, validated_opts, store_ref) do
    # Closed scalar witness only — never carries store_ref. Auth store comes from
    # launch-time TaskStore state (production: fixed TaskStore; test: explicit helper).
    witness = %{
      v: 1,
      kind: :ordinary_start,
      intent_id: intent_id,
      fingerprint: fingerprint
    }

    result =
      try do
        invoke_ordinary_start_effects(target, validated_opts, witness, store_ref)
      rescue
        e -> {:error, {:ordinary_start_exception, Exception.message(e)}}
      catch
        :exit, reason -> {:error, {:ordinary_start_exit, reason}}
        kind, reason -> {:error, {:ordinary_start_failure, kind, reason}}
      end

    settle(store_ref, target, intent_id, result)
    :ok
  end

  # Test-only hold so race/conflict regressions can observe a live intent.
  # Unavailable in production configuration (compile-time Mix.env gate).
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

    # Explicit test-only Lifecycle helper — no process-dictionary ambient state.
    defp invoke_ordinary_start_effects(target, validated_opts, witness, store_ref) do
      Lifecycle.ordinary_start_effects_for_test_store(
        target,
        validated_opts,
        witness,
        store_ref
      )
    end
  else
    defp maybe_test_hold, do: :ok

    defp invoke_ordinary_start_effects(target, validated_opts, witness, _store_ref) do
      Lifecycle.ordinary_start_effects(target, validated_opts, witness)
    end
  end

  defp settle(store_ref, target, intent_id, {:ok, pid}) when is_pid(pid) do
    _ = TaskStore.settle_runtime_admission(target, intent_id, {:applied, pid}, name: store_ref)
  catch
    :exit, _ -> :ok
  end

  defp settle(store_ref, target, intent_id, {:error, reason}) do
    _ = TaskStore.settle_runtime_admission(target, intent_id, {:error, reason}, name: store_ref)
  catch
    :exit, _ -> :ok
  end

  defp settle(store_ref, target, intent_id, other) do
    _ =
      TaskStore.settle_runtime_admission(
        target,
        intent_id,
        {:error, {:unexpected_result, other}},
        name: store_ref
      )
  catch
    :exit, _ -> :ok
  end
end
