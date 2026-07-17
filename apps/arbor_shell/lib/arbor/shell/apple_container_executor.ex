defmodule Arbor.Shell.AppleContainerExecutor do
  @moduledoc false

  # Internal imperative Apple Container spawn-capable adapter (Phase 6).
  #
  # Composes pure AppleContainerExecutionCore preflight with Prober admission,
  # ExecutionRegistry ownership, AppleContainerUnitWorker lifecycle, and
  # AppleContainerUnitDrainCoordinator settlement. Production dependencies are
  # hardcoded. Arbor.Shell.execute_spawn_capable/3 is the thin public facade
  # that calls execute/3 — Application env cannot select another backend.
  #
  # Terminal success/error requires BOTH exact worker process DOWN and an
  # authoritative ExecutionRegistry terminal projection with
  # terminal_source: :owner_published written by the worker after its
  # journal/absence gate. Controller notifications are wakeups only.
  # terminal_source :owner_down (and nil/missing/malformed/nonterminal) is
  # uncertain and requires positive settlement. No finite operation deadline
  # abandons cleanup/settlement once a unit start was attempted.

  alias Arbor.Shell.AppleContainerExecutionCore
  alias Arbor.Shell.AppleContainerProber
  alias Arbor.Shell.AppleContainerProbeRuntime
  alias Arbor.Shell.AppleContainerUnitDrainCoordinator
  alias Arbor.Shell.AppleContainerUnitName
  alias Arbor.Shell.AppleContainerUnitWorker
  alias Arbor.Shell.ExecutablePolicy.Executable
  alias Arbor.Shell.ExecutionRegistry

  @runtime_path "/usr/local/bin/container"
  @display_command "container unit"
  @terminal_statuses [:completed, :failed, :timed_out, :killed]
  @ok_terminal_statuses [:completed, :timed_out, :killed]
  @settlement_retry_initial_ms 50
  @settlement_retry_max_ms 2_000
  @max_reason_bytes 512
  @max_result_stdout_bytes 8_388_608
  @max_begin_timeout_ms 60_000
  @poll_ms 25
  @allowed_test_dep_keys MapSet.new([
                           :probe,
                           :resolve_executable,
                           :generate_unit_name,
                           :register,
                           :adopt,
                           :registry_get,
                           :registry_fail,
                           :worker_start,
                           :worker_begin,
                           :await_settled,
                           :monotonic_ms,
                           :sleep
                         ])

  @required_test_dep_keys [
    :probe,
    :resolve_executable,
    :generate_unit_name,
    :register,
    :adopt,
    :registry_get,
    :registry_fail,
    :worker_start,
    :worker_begin,
    :await_settled,
    :monotonic_ms,
    :sleep
  ]

  @type bounded_result :: map()
  @type bounded_reason :: atom() | {atom(), atom() | integer()} | {atom(), list()}

  @doc """
  Execute a validated spawn-capable Mix tool invocation inside an admitted
  Apple Container unit.

  Production dependencies are not caller-configurable. Returns only bounded
  public results or reasons — never PIDs, refs, raw exits, journal records,
  unit names, or admission evidence.
  """
  @spec execute(term(), term(), term()) ::
          {:ok, bounded_result()} | {:error, bounded_reason()}
  def execute(tool_name, args, opts) do
    do_execute(tool_name, args, opts, production_deps())
  end

  @doc false
  @spec execute_for_test(term(), term(), term(), map()) ::
          {:ok, bounded_result()} | {:error, bounded_reason()}
  def execute_for_test(tool_name, args, opts, deps) when is_map(deps) do
    case normalize_test_deps(deps) do
      {:ok, normalized} ->
        do_execute(tool_name, args, opts, normalized)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute_for_test(_tool_name, _args, _opts, _deps), do: {:error, :invalid_test_deps}

  # ---------------------------------------------------------------------------
  # Production / test dependency seams
  # ---------------------------------------------------------------------------

  defp production_deps do
    %{
      probe: &AppleContainerProber.probe/1,
      resolve_executable: &production_resolve_executable/0,
      generate_unit_name: &generate_unit_name/0,
      register: &ExecutionRegistry.register/2,
      adopt: &ExecutionRegistry.adopt/2,
      registry_get: &ExecutionRegistry.get/1,
      registry_fail: &ExecutionRegistry.fail/2,
      worker_start: &AppleContainerUnitWorker.start/4,
      worker_begin: &AppleContainerUnitWorker.begin/3,
      await_settled: &AppleContainerUnitDrainCoordinator.await_execution_settled/1,
      monotonic_ms: &monotonic_ms/0,
      sleep: &Process.sleep/1
    }
  end

  defp normalize_test_deps(deps) when is_map(deps) do
    keys = Map.keys(deps)

    cond do
      Enum.any?(keys, &(not MapSet.member?(@allowed_test_dep_keys, &1))) ->
        {:error, :invalid_test_deps}

      Enum.any?(@required_test_dep_keys, &(not Map.has_key?(deps, &1))) ->
        {:error, :invalid_test_deps}

      true ->
        with :ok <- require_fun(deps.probe, 1),
             :ok <- require_fun(deps.resolve_executable, 0),
             :ok <- require_fun(deps.generate_unit_name, 0),
             :ok <- require_fun(deps.register, 2),
             :ok <- require_fun(deps.adopt, 2),
             :ok <- require_fun(deps.registry_get, 1),
             :ok <- require_fun(deps.registry_fail, 2),
             :ok <- require_fun(deps.worker_start, 4),
             :ok <- require_fun(deps.worker_begin, 3),
             :ok <- require_fun(deps.await_settled, 1),
             :ok <- require_fun(deps.monotonic_ms, 0),
             :ok <- require_fun(deps.sleep, 1) do
          {:ok, Map.take(deps, @required_test_dep_keys)}
        end
    end
  end

  defp require_fun(fun, arity) when is_function(fun, arity), do: :ok
  defp require_fun(_fun, _arity), do: {:error, :invalid_test_deps}

  defp production_resolve_executable do
    with {:ok, %Executable{path: @runtime_path} = executable} <-
           AppleContainerProbeRuntime.resolve_executable(@runtime_path),
         :ok <- AppleContainerProbeRuntime.verify_executable(executable) do
      {:ok, executable}
    else
      {:error, reason} ->
        {:error, bound_reason(reason)}

      _other ->
        {:error, :runtime_executable_unavailable}
    end
  end

  defp generate_unit_name do
    # Caller opts never nominate this value. The canonical mapping is shared
    # with the durable journal and recovery state machine.
    {:ok, name} = AppleContainerUnitName.from_entropy(:crypto.strong_rand_bytes(16))
    name
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  # ---------------------------------------------------------------------------
  # Execution pipeline
  # ---------------------------------------------------------------------------

  defp do_execute(tool_name, args, opts, deps) do
    # (1) Pure preflight before any probe, random, registry, or worker start.
    case AppleContainerExecutionCore.validate_request(tool_name, args, opts) do
      :ok ->
        execute_after_preflight(tool_name, args, opts, deps)

      {:error, reason} ->
        {:error, bound_reason(reason)}
    end
  end

  defp execute_after_preflight(tool_name, args, opts, deps) do
    with {:ok, timeout_ms} <- fetch_timeout(opts),
         {:ok, started_mono} <- read_monotonic_ms(deps),
         deadline = started_mono + timeout_ms,
         {:ok, remaining} <- remaining_before_start(deadline, deps),
         {:ok, admission} <- run_probe(remaining, deps),
         {:ok, _after_probe} <- remaining_before_start(deadline, deps),
         {:ok, executable} <- resolve_runtime(deps),
         {:ok, _after_resolve} <- remaining_before_start(deadline, deps),
         {:ok, unit_name} <- generate_and_validate_unit_name(deps),
         {:ok, remaining_for_spec} <- remaining_before_start(deadline, deps),
         reduced_opts <- Keyword.put(opts, :timeout, min(timeout_ms, remaining_for_spec)),
         {:ok, spec} <- build_spec(tool_name, args, reduced_opts, admission, unit_name),
         {:ok, remaining_pre_register} <- remaining_before_start(deadline, deps),
         reduced_spec <- shrink_spec_timeout(spec, remaining_pre_register),
         {:ok, execution_id} <- register_execution(opts, deps) do
      # Recompute remaining AFTER register and immediately before Worker.start.
      # Setup latency during register must not extend the original deadline.
      after_register_before_start(reduced_spec, executable, execution_id, deadline, deps)
    else
      {:error, reason} ->
        {:error, bound_reason(reason)}
    end
  end

  defp fetch_timeout(opts) when is_list(opts) do
    case Keyword.fetch(opts, :timeout) do
      {:ok, timeout} when is_integer(timeout) and timeout > 0 ->
        {:ok, timeout}

      _ ->
        {:error, :invalid_timeout}
    end
  end

  defp fetch_timeout(_), do: {:error, :invalid_timeout}

  defp after_register_before_start(spec, executable, execution_id, deadline, deps) do
    case remaining_before_start(deadline, deps) do
      {:ok, remaining} ->
        shrunk = shrink_spec_timeout(spec, remaining)
        run_admitted_unit(shrunk, executable, execution_id, deadline, deps)

      {:error, :deadline_exhausted} ->
        # No Worker.start was attempted — fail controller-owned entry and return
        # without settlement (no unit ownership was ever transferred).
        _ = terminalize_controller_owned(execution_id, deps, :deadline_exhausted)
        {:error, :deadline_exhausted}
    end
  end

  defp remaining_before_start(deadline, deps) do
    case read_monotonic_ms(deps) do
      {:ok, now} when is_integer(deadline) ->
        remaining = deadline - now

        if remaining > 0 do
          {:ok, remaining}
        else
          # Expiry before start creates no unit.
          {:error, :deadline_exhausted}
        end

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :clock_unavailable}
    end
  end

  defp read_monotonic_ms(deps) do
    case safe_call(fn -> deps.monotonic_ms.() end) do
      # Monotonic time has an arbitrary origin and is commonly negative on the
      # live BEAM node. Accept any integer; deadline arithmetic is deadline - now.
      n when is_integer(n) ->
        {:ok, n}

      {:error, reason} ->
        {:error, bound_reason(reason)}

      _other ->
        {:error, :clock_unavailable}
    end
  end

  defp run_probe(remaining_ms, deps) do
    case safe_call(fn -> deps.probe.(remaining_ms) end) do
      {:ok, admission} when is_map(admission) ->
        {:ok, admission}

      {:error, reason} ->
        {:error, bound_reason(reason)}

      _other ->
        {:error, :probe_failed}
    end
  end

  defp resolve_runtime(deps) do
    case safe_call(fn -> deps.resolve_executable.() end) do
      {:ok, %Executable{path: @runtime_path} = executable} ->
        {:ok, executable}

      {:ok, %Executable{}} ->
        {:error, :runtime_executable_unavailable}

      {:error, reason} ->
        {:error, bound_reason(reason)}

      _other ->
        {:error, :runtime_executable_unavailable}
    end
  end

  defp generate_and_validate_unit_name(deps) do
    case safe_call(fn -> deps.generate_unit_name.() end) do
      name when is_binary(name) ->
        case validate_generated_unit_name(name) do
          :ok -> {:ok, name}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, bound_reason(reason)}

      _other ->
        {:error, :unit_name_generation_failed}
    end
  end

  defp validate_generated_unit_name(name) when is_binary(name) do
    case AppleContainerUnitName.validate(name) do
      {:ok, ^name} -> :ok
      {:error, :invalid_unit_name} -> {:error, :unit_name_generation_failed}
    end
  end

  defp validate_generated_unit_name(_), do: {:error, :unit_name_generation_failed}

  defp build_spec(tool_name, args, opts, admission, unit_name) do
    case AppleContainerExecutionCore.new(%{
           tool_name: tool_name,
           args: args,
           opts: opts,
           admission: admission,
           unit_name: unit_name
         }) do
      {:ok, spec} -> {:ok, spec}
      {:error, reason} -> {:error, bound_reason(reason)}
    end
  end

  defp shrink_spec_timeout(%{timeout_ms: timeout_ms} = spec, remaining)
       when is_integer(timeout_ms) and is_integer(remaining) and remaining > 0 do
    %{spec | timeout_ms: min(timeout_ms, remaining)}
  end

  defp register_execution(opts, deps) do
    cwd = Keyword.get(opts, :cwd)
    sandbox = Keyword.get(opts, :sandbox, :basic)

    case safe_call(fn ->
           deps.register.(@display_command, sandbox: sandbox, cwd: cwd)
         end) do
      {:ok, execution_id} when is_binary(execution_id) and execution_id != "" ->
        {:ok, execution_id}

      {:error, reason} ->
        {:error, bound_reason(reason)}

      _other ->
        {:error, :execution_registration_failed}
    end
  end

  # ---------------------------------------------------------------------------
  # Admitted unit lifecycle (registry + worker + settlement)
  # ---------------------------------------------------------------------------

  defp run_admitted_unit(spec, executable, execution_id, deadline, deps) do
    start_ref = make_ref()

    case safe_call(fn -> deps.worker_start.(spec, executable, execution_id, start_ref) end) do
      {:ok, worker} when is_pid(worker) ->
        # Monitor immediately so controller identity/death semantics stay exact.
        mon_ref = Process.monitor(worker)
        after_worker_accepted(spec, worker, mon_ref, start_ref, execution_id, deadline, deps)

      {:error, reason} ->
        # Even an explicit child-start error can retain a journal row when
        # Journal.complete failed — treat every start error as uncertain.
        settle_uncertain(execution_id, nil, nil, deps, reason)

      _other ->
        settle_uncertain(execution_id, nil, nil, deps, :unit_start_failed)
    end
  end

  defp after_worker_accepted(spec, worker, mon_ref, start_ref, execution_id, deadline, deps) do
    case safe_call(fn -> deps.adopt.(execution_id, worker) end) do
      :ok ->
        after_adopted(spec, worker, mon_ref, start_ref, execution_id, deadline, deps)

      {:error, reason} ->
        settle_uncertain(execution_id, worker, mon_ref, deps, reason)

      _other ->
        settle_uncertain(execution_id, worker, mon_ref, deps, :execution_adopt_failed)
    end
  end

  defp after_adopted(_spec, worker, mon_ref, start_ref, execution_id, deadline, deps) do
    # Recheck absolute deadline after adopt and immediately before begin.
    # Never substitute begin timeout 1 after expiry.
    case begin_timeout_ms(deadline, deps) do
      {:ok, begin_timeout} ->
        case safe_call(fn -> deps.worker_begin.(worker, start_ref, begin_timeout) end) do
          :ok ->
            await_authoritative_terminal(execution_id, worker, mon_ref, deps)

          {:error, reason} ->
            settle_uncertain(execution_id, worker, mon_ref, deps, reason)

          _other ->
            settle_uncertain(execution_id, worker, mon_ref, deps, :unit_begin_failed)
        end

      {:error, :deadline_exhausted} ->
        # Do not begin candidate work: cancel exact waiting worker and settle.
        settle_uncertain(execution_id, worker, mon_ref, deps, :deadline_exhausted)
    end
  end

  defp begin_timeout_ms(deadline, deps) do
    case read_monotonic_ms(deps) do
      {:ok, now} when is_integer(deadline) ->
        remaining = deadline - now

        cond do
          remaining <= 0 ->
            {:error, :deadline_exhausted}

          remaining > @max_begin_timeout_ms ->
            {:ok, @max_begin_timeout_ms}

          true ->
            {:ok, remaining}
        end

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :clock_unavailable}
    end
  end

  # ---------------------------------------------------------------------------
  # Authoritative wait: exact DOWN + Registry terminal (notification = wakeup)
  # ---------------------------------------------------------------------------

  defp await_authoritative_terminal(execution_id, worker, mon_ref, deps) do
    loop_terminal(%{
      execution_id: execution_id,
      worker: worker,
      mon_ref: mon_ref,
      worker_down: false,
      down_reason: nil,
      deps: deps
    })
  end

  defp loop_terminal(state) do
    if state.worker_down do
      conclude_after_down(state)
    else
      receive do
        # Exact worker monitor only.
        {:DOWN, mon_ref, :process, pid, reason}
        when mon_ref == state.mon_ref and pid == state.worker ->
          _ = Process.demonitor(mon_ref, [:flush])
          loop_terminal(%{state | worker_down: true, down_reason: reason, mon_ref: nil})

        # Wakeup only — never trust the payload as terminal authority.
        {:apple_container_unit_terminal, execution_id, _payload}
        when execution_id == state.execution_id ->
          if state.worker_down do
            conclude_after_down(state)
          else
            loop_terminal(state)
          end
      after
        @poll_ms ->
          # Periodic registry/status poll without trusting notifications.
          # Unrelated/forged messages remain in the mailbox in original order.
          loop_terminal(state)
      end
    end
  end

  defp conclude_after_down(state) do
    case safe_call(fn -> state.deps.registry_get.(state.execution_id) end) do
      {:ok, projection} when is_map(projection) ->
        if owner_published_terminal?(projection) do
          project_owner_published(projection)
        else
          # :owner_down, nil/missing/malformed provenance, nonterminal, or
          # invalid result shape — uncertain, require positive settlement.
          settle_uncertain(state.execution_id, nil, nil, state.deps, :execution_uncertain)
        end

      {:error, :not_found} ->
        settle_uncertain(state.execution_id, nil, nil, state.deps, :execution_uncertain)

      {:error, _reason} ->
        # Missing/restarting Registry after worker DOWN.
        settle_uncertain(state.execution_id, nil, nil, state.deps, :execution_uncertain)

      _other ->
        settle_uncertain(state.execution_id, nil, nil, state.deps, :execution_uncertain)
    end
  end

  # Authoritative only when Registry projects explicit owner-published provenance
  # plus a valid bounded result shape. Never infer from result.error shape.
  defp owner_published_terminal?(projection) when is_map(projection) do
    status = Map.get(projection, :status)
    source = Map.get(projection, :terminal_source)
    result = Map.get(projection, :result)

    status in @terminal_statuses and source == :owner_published and
      valid_owner_published_result?(status, result)
  end

  defp owner_published_terminal?(_), do: false

  # ExecutionRegistry.owner_fail always stores a result map. nil/missing/malformed
  # result is not a valid owner-published terminal shape — settle positively.
  defp valid_owner_published_result?(:failed, result) when is_map(result), do: true

  defp valid_owner_published_result?(status, result)
       when status in @ok_terminal_statuses and is_map(result) do
    true
  end

  defp valid_owner_published_result?(_status, _result), do: false

  defp project_owner_published(projection) do
    status = Map.fetch!(projection, :status)
    result = Map.get(projection, :result)

    cond do
      status in @ok_terminal_statuses and is_map(result) ->
        # Match existing Shell Executor: timeout/cancel/kill/output-limit are
        # {:ok, result} terminals, not {:error, ...}.
        {:ok, bound_result(result)}

      status == :failed ->
        {:error, failed_reason(result)}

      true ->
        {:error, :execution_uncertain}
    end
  end

  defp failed_reason(result) when is_map(result) do
    cond do
      Map.has_key?(result, :error) ->
        bound_reason(Map.get(result, :error))

      true ->
        :failed
    end
  end

  defp failed_reason(_), do: :failed

  defp bound_result(result) when is_map(result) do
    %{
      exit_code: Map.get(result, :exit_code, 1),
      stdout: bound_binary(Map.get(result, :stdout, ""), @max_result_stdout_bytes),
      stderr: bound_binary(Map.get(result, :stderr, ""), @max_reason_bytes),
      duration_ms: bound_non_neg_int(Map.get(result, :duration_ms, 0)),
      timed_out: Map.get(result, :timed_out) == true,
      cancelled: Map.get(result, :cancelled) == true,
      killed: Map.get(result, :killed) == true,
      output_truncated: Map.get(result, :output_truncated) == true,
      output_limit_exceeded: Map.get(result, :output_limit_exceeded) == true
    }
    |> maybe_put_containment(Map.get(result, :containment_failure) == true)
  end

  defp maybe_put_containment(map, true), do: Map.put(map, :containment_failure, true)
  defp maybe_put_containment(map, _), do: map

  defp bound_non_neg_int(n) when is_integer(n) and n >= 0 and n <= 86_400_000, do: n
  defp bound_non_neg_int(_), do: 0

  defp bound_binary(bin, max) when is_binary(bin) and is_integer(max) and max >= 0 do
    if byte_size(bin) <= max, do: bin, else: binary_part(bin, 0, max)
  end

  defp bound_binary(_, _), do: ""

  # ---------------------------------------------------------------------------
  # Uncertain path: cancel known worker, settle, best-effort terminalize
  # ---------------------------------------------------------------------------

  defp settle_uncertain(execution_id, worker, mon_ref, deps, reason)
       when is_binary(execution_id) do
    # Exact known-worker cancellation (request only). Settlement is authority.
    # Do NOT rely on ExecutionRegistry.request_cancel: before adopt it would
    # deliver to the controller itself.
    _ = cancel_known_worker(worker, execution_id)
    # Settlement is the stronger absence proof — do not wait indefinitely for
    # worker DOWN before invoking the coordinator path.
    _ = await_settled_retry(execution_id, deps, @settlement_retry_initial_ms)
    # After settlement, drop the exact monitor without scanning unrelated mail.
    _ = flush_worker_monitor(worker, mon_ref)
    _ = terminalize_controller_owned(execution_id, deps, public_uncertain_reason(reason))
    {:error, bound_reason(public_uncertain_reason(reason))}
  end

  defp public_uncertain_reason(reason) when is_atom(reason), do: reason

  defp public_uncertain_reason(reason) when is_tuple(reason) do
    if public_tuple_reason?(reason), do: reason, else: :execution_uncertain
  end

  defp public_uncertain_reason(_), do: :execution_uncertain

  defp public_tuple_reason?(reason) when is_tuple(reason) and tuple_size(reason) <= 4 do
    Enum.all?(Tuple.to_list(reason), fn
      part when is_atom(part) -> true
      part when is_integer(part) -> true
      part when is_list(part) -> Enum.all?(part, &is_atom/1)
      _ -> false
    end)
  end

  defp public_tuple_reason?(_), do: false

  defp cancel_known_worker(worker, execution_id)
       when is_pid(worker) and is_binary(execution_id) do
    send(worker, {:cancel_shell_execution, execution_id})
    :ok
  end

  defp cancel_known_worker(_worker, _execution_id), do: :ok

  # After positive settlement, demonitor and selectively flush only the exact
  # DOWN. Leave unrelated/forged messages in place and in original order.
  defp flush_worker_monitor(worker, mon_ref)
       when is_pid(worker) and is_reference(mon_ref) do
    Process.demonitor(mon_ref, [:flush])

    receive do
      {:DOWN, ^mon_ref, :process, ^worker, _reason} -> :ok
    after
      0 -> :ok
    end

    :ok
  end

  defp flush_worker_monitor(_worker, mon_ref) when is_reference(mon_ref) do
    Process.demonitor(mon_ref, [:flush])
    :ok
  end

  defp flush_worker_monitor(_worker, _mon_ref), do: :ok

  defp await_settled_retry(execution_id, deps, delay) do
    case safe_call(fn -> deps.await_settled.(execution_id) end) do
      :ok ->
        :ok

      {:error, :too_many_execution_waiters} ->
        _ = safe_sleep(deps, delay)
        await_settled_retry(execution_id, deps, next_settlement_delay(delay))

      {:error, {:coordinator_unavailable, _}} ->
        _ = safe_sleep(deps, delay)
        await_settled_retry(execution_id, deps, next_settlement_delay(delay))

      {:error, :call_exit} ->
        _ = safe_sleep(deps, delay)
        await_settled_retry(execution_id, deps, next_settlement_delay(delay))

      {:error, :call_error} ->
        _ = safe_sleep(deps, delay)
        await_settled_retry(execution_id, deps, next_settlement_delay(delay))

      {:error, _other} ->
        # Never reinterpret coordinator errors as absence — retry forever with
        # bounded delay. Containment must not depend on a single observation.
        _ = safe_sleep(deps, delay)
        await_settled_retry(execution_id, deps, next_settlement_delay(delay))

      _other ->
        _ = safe_sleep(deps, delay)
        await_settled_retry(execution_id, deps, next_settlement_delay(delay))
    end
  end

  defp next_settlement_delay(delay) do
    min(delay * 2, @settlement_retry_max_ms)
  end

  defp safe_sleep(deps, delay) do
    _ = safe_call(fn -> deps.sleep.(delay) end)
    :ok
  end

  defp terminalize_controller_owned(execution_id, deps, reason) do
    case safe_call(fn -> deps.registry_get.(execution_id) end) do
      {:ok, %{status: status}} when status in @terminal_statuses ->
        :ok

      {:ok, _nonterminal} ->
        # Best-effort: only succeeds while still controller-owned.
        _ = safe_call(fn -> deps.registry_fail.(execution_id, reason) end)
        :ok

      _other ->
        # Containment proof must not depend on Registry availability.
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Safe calls + bounded public reasons
  # ---------------------------------------------------------------------------

  defp safe_call(fun) when is_function(fun, 0) do
    fun.()
  catch
    :exit, _reason ->
      {:error, :call_exit}

    :error, _reason ->
      {:error, :call_error}

    :throw, _reason ->
      {:error, :call_error}
  end

  defp bound_reason(reason) when is_atom(reason), do: reason

  defp bound_reason(reason) when is_binary(reason) do
    if byte_size(reason) <= @max_reason_bytes, do: reason, else: :execution_error
  end

  defp bound_reason(reason) when is_tuple(reason) and tuple_size(reason) <= 4 do
    if public_tuple_reason?(reason) do
      reason
    else
      :execution_error
    end
  end

  defp bound_reason(reason) when is_list(reason) do
    if Enum.all?(reason, &is_atom/1) and length(reason) <= 8 do
      reason
    else
      :execution_error
    end
  end

  defp bound_reason(_), do: :execution_error
end
