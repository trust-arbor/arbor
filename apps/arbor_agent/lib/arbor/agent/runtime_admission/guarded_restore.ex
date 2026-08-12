defmodule Arbor.Agent.RuntimeAdmission.GuardedRestore do
  @moduledoc """
  Imperative shell for guarded runtime-restore admission (Phase 4C C3C1a1).

  Mints/resumes a durable restore-admission claim under the **exact** caller
  `operation_id`, admits through TaskStore under the operation-owned fence, and
  awaits settlement. C3C1b will call this primitive later — this module does not
  execute reconciliation journals.

  Durable applied settlement is **not** invented here. The authenticated worker
  settles durable state only after TaskStore accepts its terminal. This shell
  returns success only after reobserving the exact durable applied successor;
  unconfirmed applied returns a bounded `:outcome_unknown` while preserving
  the claim.

  **not_applied authority:** only TaskStore's source-authenticated owner/worker/
  monitor pre-effect path may settle not_applied. This public shell never settles
  not_applied from local timeouts, readiness/fence errors, or join failures.
  """

  alias Arbor.Agent.Orchestration.TaskStore
  alias Arbor.Agent.TemplateAuthorityReconciliationStore

  @default_store TaskStore
  @default_deadline_ms 120_000
  @max_deadline_ms 180_000
  @ready_poll_ms 50
  @call_timeout_ms 30_000
  @durable_confirm_poll_ms 50

  # Production public opts: documented timeout controls only.
  # :task_store is compile-time test-only (absent from dev/prod resolve path).
  @production_opt_keys MapSet.new([:timeout_ms, :timeout])
  @test_opt_keys MapSet.new([:timeout_ms, :timeout, :task_store])

  # Closed public error atoms only — never raw exit reasons, call args, or nested terms.
  @public_error_atoms MapSet.new([
                        :timeout,
                        :invalid_start_opts,
                        :invalid_claim,
                        :invalid_request,
                        :not_owner,
                        :not_found,
                        :conflict,
                        :busy,
                        :settling,
                        :restore_pre_effect_aborted,
                        :restore_fence_required,
                        :restore_phase_illegal,
                        :runtime_admission_not_ready,
                        :runtime_admission_wait_timeout,
                        :runtime_admission_waiters_full,
                        :fence_not_ready,
                        :outcome_unknown,
                        :store_unavailable,
                        :store_timeout,
                        :unexpected_admit_result,
                        :admit_failed,
                        :request_failed,
                        :claim_settled,
                        :stale_claim,
                        :missing_api
                      ])

  @doc """
  Admit or join a guarded runtime restore for `target_agent_id` under `operation_id`.

  Returns `{:ok, pid}` only when TaskStore reports applied **and** durable claim
  settlement is reobserved as exact applied. Otherwise returns a **closed**
  `{:error, atom()}` (including `:outcome_unknown` when the branch may have
  applied but durable applied settlement is unconfirmed — claim is preserved).

  This public API is **total**: GenServer.call exits (timeout, nodedown, noproc,
  etc.) are mapped to bounded error atoms. Raw exit reasons and call args
  (which may include `restore_token`) are never re-raised or returned.

  Opts (production): `:timeout_ms` or `:timeout` (waiter/deadline budget).
  Unknown or collaborator keys are rejected. `:name` is always rejected.
  """
  @spec request(String.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, atom()}
  def request(target_agent_id, operation_id, opts \\ [])

  def request(target_agent_id, operation_id, opts)
      when is_binary(target_agent_id) and is_binary(operation_id) and is_list(opts) do
    try do
      with :ok <- validate_public_opts(opts),
           {:ok, store_ref} <- resolve_store_ref(opts),
           deadline = absolute_deadline(opts),
           {:ok, token, canonical_op_id} <- begin_claim(target_agent_id, operation_id) do
        public_result(await_loop(target_agent_id, canonical_op_id, token, store_ref, deadline))
      else
        {:error, reason} -> public_error(reason)
        other -> public_error(other)
      end
    rescue
      _ -> {:error, :request_failed}
    catch
      # Totality: never leak exit reasons/args that may carry restore_token.
      :exit, reason ->
        {:error, map_call_exit_to_public(reason)}
    end
  end

  def request(_, _, _), do: {:error, :invalid_request}

  defp validate_public_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      keys = opts |> Keyword.keys() |> MapSet.new()
      allowed = if Mix.env() == :test, do: @test_opt_keys, else: @production_opt_keys

      cond do
        MapSet.member?(keys, :name) ->
          {:error, :invalid_start_opts}

        not MapSet.subset?(keys, allowed) ->
          {:error, :invalid_start_opts}

        true ->
          :ok
      end
    else
      {:error, :invalid_start_opts}
    end
  end

  if Mix.env() == :test do
    defp resolve_store_ref(opts) do
      case Keyword.fetch(opts, :task_store) do
        :error ->
          {:ok, @default_store}

        {:ok, ref} when is_atom(ref) or is_pid(ref) or is_tuple(ref) ->
          {:ok, ref}

        {:ok, _} ->
          {:error, :invalid_start_opts}
      end
    end
  else
    defp resolve_store_ref(_opts), do: {:ok, @default_store}
  end

  # Bind caller's operation_id before mint/resume — no durable mutation on mismatch.
  defp begin_claim(target, operation_id) do
    case TemplateAuthorityReconciliationStore.begin_runtime_restore_admission(
           target,
           operation_id
         ) do
      {:ok, op} ->
        claim = op["runtime_restore_admission"]
        canonical = op["operation_id"]

        if is_map(claim) and is_binary(claim["token"]) and is_binary(canonical) and
             canonical == operation_id and claim["operation_id"] == operation_id do
          {:ok, claim["token"], canonical}
        else
          {:error, :invalid_claim}
        end

      {:error, _} = err ->
        err
    end
  end

  defp await_loop(target, operation_id, token, store_ref, deadline) do
    if now_ms() >= deadline do
      # Local shell timeout — preserve minted/outstanding claim; do not settle.
      {:error, :timeout}
    else
      case ensure_ready(store_ref, deadline) do
        :ok ->
          admit_and_await(target, operation_id, token, store_ref, deadline)

        {:error, :timeout} ->
          {:error, :timeout}

        {:error, :store_restart} ->
          await_loop(target, operation_id, token, store_ref, deadline)

        {:error, _} = err ->
          # Readiness/store errors never settle not_applied.
          err
      end
    end
  end

  defp admit_and_await(target, operation_id, token, store_ref, deadline) do
    remaining = max(deadline - now_ms(), 1)
    call_timeout = min(@call_timeout_ms, remaining)

    try do
      case TaskStore.admit_guarded_runtime_restore(
             target,
             operation_id,
             token,
             name: store_ref,
             timeout: call_timeout
           ) do
        {:ok, pid} when is_pid(pid) ->
          # Do not invent durable applied here — reobserve exact successor.
          confirm_durable_applied(target, token, pid, deadline)

        {:error, :runtime_admission_wait_timeout} ->
          if now_ms() >= deadline do
            # Joiner/local timeout — rejoin later; never settle shared claim.
            {:error, :timeout}
          else
            await_loop(target, operation_id, token, store_ref, deadline)
          end

        {:error, :restore_pre_effect_aborted} ->
          # Typed TaskStore authoritative rejection: exact op/token, no fence,
          # no live intent — admit never started effects. Settle+clear only this
          # determinate result (never arbitrary caller errors/timeouts).
          case settle_and_clear_pre_effect_aborted(target, token) do
            :ok -> {:error, :restore_pre_effect_aborted}
            {:error, _} -> {:error, :outcome_unknown}
          end

        {:error, reason} ->
          # Preserve/rejoin minted claims. Map to closed public atom only —
          # never return nested/raw reasons that could carry secrets.
          public_error(reason)

        _other ->
          # Collapse unexpected shapes to a closed atom (not a nested tuple).
          {:error, :unexpected_admit_result}
      end
    catch
      :exit, reason ->
        if store_restart_exit?(reason, store_ref) do
          _ = wait_ready_after_restart(store_ref, deadline)
          await_loop(target, operation_id, token, store_ref, deadline)
        else
          # Timeout/nodedown/unavailable: never re-exit (would leak call args
          # including restore_token). Map to closed bounded error atom only.
          {:error, map_call_exit_to_public(reason)}
        end
    end
  end

  # Outside-callback settle+clear for TaskStore-typed pre-effect abort only.
  defp settle_and_clear_pre_effect_aborted(target, token)
       when is_binary(target) and is_binary(token) do
    settlement = %{
      "outcome" => "not_applied",
      "reason_code" => "pre_effect_abort",
      "at_unix_ms" => System.system_time(:millisecond)
    }

    case TemplateAuthorityReconciliationStore.settle_runtime_restore_admission(
           target,
           token,
           settlement
         ) do
      {:ok, _} ->
        _ = TemplateAuthorityReconciliationStore.clear_runtime_restore_admission(target, token)
        :ok

      {:error, :already_settled} ->
        # Clear only the exact pre-effect terminal — never a different settled
        # outcome (applied/failed/conflict) that already won.
        case TemplateAuthorityReconciliationStore.fetch(target) do
          {:ok, op} ->
            claim = op["runtime_restore_admission"]

            if is_map(claim) and claim["token"] == token and
                 claim["claim_phase"] == "settled" and
                 match?(
                   %{"outcome" => "not_applied", "reason_code" => "pre_effect_abort"},
                   claim["settlement"]
                 ) do
              _ =
                TemplateAuthorityReconciliationStore.clear_runtime_restore_admission(
                  target,
                  token
                )

              :ok
            else
              {:error, :outcome_unknown}
            end

          _ ->
            {:error, :outcome_unknown}
        end

      {:error, _} ->
        {:error, :outcome_unknown}
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    :exit, _ -> {:error, :outcome_unknown}
  end

  # Reobserve exact durable applied settlement before reporting success.
  # Unconfirmed → {:error, :outcome_unknown}; claim is preserved.
  defp confirm_durable_applied(target, token, pid, deadline) do
    if now_ms() >= deadline do
      {:error, :outcome_unknown}
    else
      case reobserve_durable_settlement(target, token) do
        {:ok, :applied} ->
          {:ok, pid}

        {:ok, :pending} ->
          Process.sleep(@durable_confirm_poll_ms)
          confirm_durable_applied(target, token, pid, deadline)

        {:ok, :other_terminal} ->
          # Durable settled non-applied while TaskStore said applied — unknown.
          {:error, :outcome_unknown}

        {:error, :outcome_unknown} ->
          {:error, :outcome_unknown}
      end
    end
  end

  defp reobserve_durable_settlement(target, token) do
    case TemplateAuthorityReconciliationStore.fetch(target) do
      {:ok, op} ->
        case Map.get(op, "runtime_restore_admission") do
          %{
            "token" => ^token,
            "claim_phase" => "settled",
            "settlement" => %{"outcome" => "applied"}
          } ->
            {:ok, :applied}

          %{"token" => ^token, "claim_phase" => "settled", "settlement" => %{"outcome" => _other}} ->
            {:ok, :other_terminal}

          %{"token" => ^token, "claim_phase" => phase}
          when phase in ["minted", "bound", "outcome_unknown"] ->
            {:ok, :pending}

          _ ->
            {:error, :outcome_unknown}
        end

      {:error, _} ->
        {:error, :outcome_unknown}
    end
  catch
    :exit, _ -> {:error, :outcome_unknown}
  end

  defp ensure_ready(store_ref, deadline) do
    if now_ms() >= deadline do
      {:error, :timeout}
    else
      try do
        if TaskStore.runtime_admission_ready?(name: store_ref) do
          :ok
        else
          Process.sleep(@ready_poll_ms)
          ensure_ready(store_ref, deadline)
        end
      catch
        :exit, reason ->
          if store_restart_exit?(reason, store_ref) do
            Process.sleep(@ready_poll_ms)
            {:error, :store_restart}
          else
            # Never re-exit — map to closed atom (no raw reason/args).
            {:error, map_call_exit_to_public(reason)}
          end
      end
    end
  end

  defp wait_ready_after_restart(store_ref, deadline), do: ensure_ready(store_ref, deadline)

  defp absolute_deadline(opts) do
    requested =
      cond do
        Keyword.has_key?(opts, :timeout_ms) -> Keyword.get(opts, :timeout_ms)
        Keyword.has_key?(opts, :timeout) -> Keyword.get(opts, :timeout)
        true -> @default_deadline_ms
      end

    ms =
      cond do
        not is_integer(requested) -> @default_deadline_ms
        requested < 1_000 -> 1_000
        requested > @max_deadline_ms -> @max_deadline_ms
        true -> requested
      end

    now_ms() + ms
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp public_result({:ok, pid}) when is_pid(pid), do: {:ok, pid}
  defp public_result({:error, reason}), do: public_error(reason)
  defp public_result(_), do: {:error, :unexpected_admit_result}

  defp public_error(reason) when is_atom(reason) do
    if MapSet.member?(@public_error_atoms, reason) do
      {:error, reason}
    else
      {:error, :admit_failed}
    end
  end

  defp public_error(_), do: {:error, :admit_failed}

  # Map GenServer.call exit shapes to closed atoms. Never inspect/return args
  # (may contain restore_token, operation_id, fingerprint).
  defp map_call_exit_to_public({:timeout, {GenServer, :call, _args}}), do: :store_timeout
  defp map_call_exit_to_public({:timeout, _}), do: :store_timeout
  defp map_call_exit_to_public({{:timeout, _}, {GenServer, :call, _args}}), do: :store_timeout
  defp map_call_exit_to_public({:noproc, {GenServer, :call, _args}}), do: :store_unavailable

  defp map_call_exit_to_public({{:nodedown, _}, {GenServer, :call, _args}}),
    do: :store_unavailable

  defp map_call_exit_to_public({reason, {GenServer, :call, _args}})
       when reason in [:normal, :shutdown, :killed, :noproc],
       do: :store_unavailable

  defp map_call_exit_to_public({{:shutdown, _}, {GenServer, :call, _args}}),
    do: :store_unavailable

  defp map_call_exit_to_public(_), do: :store_unavailable

  defp store_restart_exit?({:noproc, {GenServer, :call, args}}, store_ref),
    do: call_targets_store?(args, store_ref)

  defp store_restart_exit?({{:nodedown, _}, {GenServer, :call, args}}, store_ref),
    do: call_targets_store?(args, store_ref)

  defp store_restart_exit?({reason, {GenServer, :call, args}}, store_ref)
       when reason in [:normal, :shutdown, :killed, :noproc] do
    call_targets_store?(args, store_ref)
  end

  defp store_restart_exit?({{:shutdown, _}, {GenServer, :call, args}}, store_ref),
    do: call_targets_store?(args, store_ref)

  defp store_restart_exit?(_, _), do: false

  defp call_targets_store?([store_ref | _], store_ref), do: true
  defp call_targets_store?(_, _), do: false
end
