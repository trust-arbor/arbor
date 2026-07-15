defmodule Arbor.Shell.LinuxDependencyBaselineMaterializer do
  @moduledoc """
  Shell-owned temporary materialization lease for a verified Linux dependency baseline.

  Acquires a private candidate/base copy pair under the system temp root from an
  evidence-only plan checked out of `LinuxDependencyBaselineAuthority`. The
  returned lease is process-bound: only the acquiring caller may release it, and
  a copied opaque term alone is not authority.

  Destinations are private writable copies (0600/0700). The receipt is evidence
  only — never executable authority, never source/manifest paths or inventory
  names. Used by the spawn-capable admission path behind
  `Arbor.Shell.execute_spawn_capable/3`.
  """

  use GenServer

  import Bitwise

  alias Arbor.Common.SafePath
  alias Arbor.Shell.LinuxDependencyBaselineAuthority
  alias Arbor.Shell.LinuxDependencyBaselineCore, as: Core

  @supervisor Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor
  @chunk_size 65_536
  @max_deadline_ms 3_600_000
  @max_path_bytes 4_096
  @token_bytes 32
  @max_root_name_attempts 8
  @max_identity_capture_attempts 5
  @max_reason_tuple_arity 4
  @cleanup_retry_initial_ms 50
  @cleanup_retry_max_ms 2_000
  @supervisor_cleanup_attempts 20
  @supervisor_cleanup_sleep_ms 25

  @plan_keys MapSet.new([
               "kind",
               "source_root",
               "manifest_path",
               "receipt",
               "materialization_entries",
               "evidence_only"
             ])

  @forbidden_plan_keys MapSet.new([
                         "ready",
                         "readiness",
                         "provisioned",
                         "provisioning",
                         "status",
                         "destination",
                         "destinations",
                         "candidate_path",
                         "base_path",
                         "writable"
                       ])

  @type root_identity :: %{
          path: String.t(),
          type: :directory,
          device: non_neg_integer(),
          inode: non_neg_integer()
        }

  defmodule Lease do
    @moduledoc false
    # Private root locator/identity are process-local opaque fields for
    # idempotent post-teardown absence proof. Never serialized into the public
    # JSON view; Inspect remains fully redacted.
    @enforce_keys [:token, :worker, :owner, :root_path]
    defstruct [:token, :worker, :owner, :root_path, :root_device, :root_inode]
  end

  defimpl Inspect, for: Lease do
    def inspect(_lease, _opts), do: "#Arbor.Shell.LinuxDependencyBaselineLease<redacted>"
  end

  # ---------------------------------------------------------------------------
  # Supervision
  # ---------------------------------------------------------------------------

  @doc false
  @spec supervisor_child_spec() :: Supervisor.child_spec()
  def supervisor_child_spec do
    %{
      id: @supervisor,
      start:
        {DynamicSupervisor, :start_link,
         [[name: @supervisor, strategy: :one_for_one, max_restarts: 100, max_seconds: 1]]},
      type: :supervisor,
      restart: :permanent,
      shutdown: :infinity
    }
  end

  @doc false
  @spec supervisor_name() :: atom()
  def supervisor_name, do: @supervisor

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: make_ref(),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker,
      shutdown: 10_000
    }
  end

  # ---------------------------------------------------------------------------
  # Trusted acquire / release (opts authority injection is test-only)
  # ---------------------------------------------------------------------------

  @doc """
  Acquire a candidate/base materialization lease.

  Production callers must use `Arbor.Shell.acquire_linux_dependency_baseline_lease/1`,
  which accepts only a positive deadline scalar. Direct same-library tests may
  inject `:authority` without exposing that option through the Shell facade.
  """
  @spec acquire(pos_integer(), keyword()) :: {:ok, Lease.t(), map()} | {:error, term()}
  def acquire(deadline_ms, opts \\ [])

  def acquire(deadline_ms, opts)
      when is_integer(deadline_ms) and deadline_ms > 0 and deadline_ms <= @max_deadline_ms and
             is_list(opts) do
    if Keyword.keyword?(opts) do
      case normalize_acquire_opts(opts) do
        {:ok, normalized} ->
          absolute_deadline = System.monotonic_time(:millisecond) + deadline_ms
          start_and_materialize(self(), absolute_deadline, normalized)

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :invalid_materializer_options}
    end
  end

  def acquire(_deadline_ms, _opts), do: {:error, :invalid_deadline}

  @doc """
  Release a lease previously returned to the live caller process.

  Requires the same live caller as acquire. Explicit cleanup failure is
  enforcing and retryable — success is returned only after the private root is
  proven absent.
  """
  @spec release(term()) :: :ok | {:error, term()}
  def release(
        %Lease{
          token: token,
          worker: worker,
          owner: owner,
          root_path: root_path
        } = lease
      )
      when is_binary(token) and is_pid(worker) and is_pid(owner) and is_binary(root_path) do
    if self() != owner do
      {:error, :foreign_release}
    else
      case try_worker_release(worker, token) do
        :ok ->
          :ok

        {:error, :lease_worker_unavailable} ->
          # Successful prior teardown leaves the worker gone. Same-caller release
          # is idempotent only when Shell proves the private root is already
          # absent — never delete from the caller process.
          prove_released_root_absent(lease)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def release(_lease), do: {:error, :invalid_lease}

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) when is_list(opts) do
    owner = Keyword.fetch!(opts, :owner)
    deadline = Keyword.fetch!(opts, :deadline)
    authority = Keyword.get(opts, :authority, LinuxDependencyBaselineAuthority)
    test_cleanup_failures = Keyword.get(opts, :__test_cleanup_failures, 0)
    test_cleanup_fail_after_identity = Keyword.get(opts, :__test_cleanup_fail_after_identity, 0)
    test_identity_capture_failures = Keyword.get(opts, :__test_identity_capture_failures, 0)
    test_verify = Keyword.get(opts, :__test_verify_hook, nil)

    if is_pid(owner) and is_integer(deadline) and is_atom(authority) and
         is_integer(test_cleanup_failures) and test_cleanup_failures >= 0 and
         is_integer(test_cleanup_fail_after_identity) and test_cleanup_fail_after_identity >= 0 and
         is_integer(test_identity_capture_failures) and test_identity_capture_failures >= 0 do
      # DynamicSupervisor child teardown may deliver {:EXIT, parent, :shutdown}
      # rather than GenServer.stop/1. Trap exits so cleanup always runs before stop.
      Process.flag(:trap_exit, true)
      owner_ref = Process.monitor(owner)
      token = :crypto.strong_rand_bytes(@token_bytes)

      if test_cleanup_failures > 0 do
        Process.put({__MODULE__, :test_cleanup_failures}, test_cleanup_failures)
      end

      if test_cleanup_fail_after_identity > 0 do
        Process.put(
          {__MODULE__, :test_cleanup_fail_after_identity},
          test_cleanup_fail_after_identity
        )
      end

      if test_identity_capture_failures > 0 do
        Process.put(
          {__MODULE__, :test_identity_capture_failures},
          test_identity_capture_failures
        )
      end

      {:ok,
       %{
         status: :starting,
         owner_pid: owner,
         owner_ref: owner_ref,
         token: token,
         deadline: deadline,
         authority: authority,
         root_path: nil,
         root_identity: nil,
         candidate_path: nil,
         base_path: nil,
         receipt: nil,
         plan_fingerprint: nil,
         owned: false,
         cleanup_retry_ms: @cleanup_retry_initial_ms,
         cleanup_timer: nil,
         test_verify_hook: test_verify
       }}
    else
      {:stop, :invalid_materializer_start}
    end
  end

  @impl true
  def handle_call(:materialize, {caller, _}, %{status: :starting, owner_pid: owner} = state) do
    if caller != owner do
      {:reply, {:error, :foreign_caller}, state}
    else
      case materialize(state) do
        {:ok, ready_state, view} ->
          {:reply, {:ok, make_lease(ready_state), view}, ready_state}

        {:error, reason, failed_state} ->
          finalize_materialize_failure(reason, failed_state)
      end
    end
  end

  def handle_call(:materialize, _from, state) do
    {:reply, {:error, :already_materialized}, state}
  end

  def handle_call({:release, token}, {caller, _}, state) do
    cond do
      caller != state.owner_pid ->
        {:reply, {:error, :foreign_release}, state}

      token != state.token ->
        {:reply, {:error, :invalid_lease}, state}

      state.status not in [:ready, :cleanup_required] ->
        {:reply, {:error, :lease_not_ready}, state}

      true ->
        case attempt_cleanup(state) do
          :ok ->
            {:stop, :normal, :ok, clear_ownership(cancel_cleanup_timer(state))}

          {:error, reason} ->
            # Explicit release cleanup failure remains enforcing and retryable.
            {:reply, {:error, {:cleanup_failed, bound_public_reason(reason)}}, state}
        end
    end
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :unsupported_materializer_request}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{owner_ref: ref, owner_pid: pid} = state) do
    state = %{state | owner_ref: nil}

    case attempt_cleanup(state) do
      :ok ->
        {:stop, :normal, clear_ownership(cancel_cleanup_timer(state))}

      {:error, _} ->
        # Owner died with unproven cleanup: retain worker and retry until absence.
        {:noreply, schedule_cleanup_retry(%{state | status: :cleanup_pending})}
    end
  end

  def handle_info(:cleanup_retry, %{status: :cleanup_pending} = state) do
    state = %{state | cleanup_timer: nil}

    case attempt_cleanup(state) do
      :ok ->
        {:stop, :normal, clear_ownership(state)}

      {:error, _} ->
        {:noreply, schedule_cleanup_retry(state)}
    end
  end

  def handle_info(:cleanup_retry, state) do
    {:noreply, %{state | cleanup_timer: nil}}
  end

  def handle_info({:EXIT, _from, reason}, state) do
    # Parent DynamicSupervisor/application shutdown path: prove cleanup before stop.
    case attempt_cleanup_with_bounded_retries(state, @supervisor_cleanup_attempts) do
      {:ok, cleaned} ->
        {:stop, reason, clear_ownership(cancel_cleanup_timer(cleaned))}

      {:error, failed} ->
        # Do not clear ownership identity — terminate gets a final pass with state.
        {:stop, reason, cancel_cleanup_timer(failed)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Final pass. Never claim success without absence proof; process exit may leave
    # an on-disk root only if every retry failed (supervisor-forced death).
    _ = attempt_cleanup(state)
    :ok
  end

  @impl true
  def format_status(status) when is_map(status) do
    state = Map.get(status, :state, %{})

    status
    |> Map.put(:message, :redacted)
    |> Map.put(:state, redact_state(state))
    |> redact_status_field(:reason)
    |> redact_status_field(:log)
  end

  def format_status(status), do: status

  # ---------------------------------------------------------------------------
  # Acquire plumbing
  # ---------------------------------------------------------------------------

  defp normalize_acquire_opts(opts) do
    # :authority and test-only hooks stay internal to same-library direct tests.
    # The public Arbor.Shell facade never accepts these options.
    allowed =
      MapSet.new([
        :authority,
        :__test_cleanup_failures,
        :__test_cleanup_fail_after_identity,
        :__test_identity_capture_failures,
        :__test_verify_hook
      ])

    Enum.reduce_while(
      opts,
      {:ok,
       %{
         authority: LinuxDependencyBaselineAuthority,
         test_cleanup_failures: 0,
         test_cleanup_fail_after_identity: 0,
         test_identity_capture_failures: 0,
         test_verify_hook: nil
       }, MapSet.new()},
      fn
        {:authority, value}, {:ok, acc, seen} ->
          cond do
            MapSet.member?(seen, :authority) ->
              {:halt, {:error, :duplicate_materializer_option}}

            is_atom(value) and not is_nil(value) ->
              {:cont, {:ok, %{acc | authority: value}, MapSet.put(seen, :authority)}}

            true ->
              {:halt, {:error, :invalid_materializer_authority}}
          end

        {:__test_cleanup_failures, value}, {:ok, acc, seen} ->
          cond do
            MapSet.member?(seen, :__test_cleanup_failures) ->
              {:halt, {:error, :duplicate_materializer_option}}

            is_integer(value) and value >= 0 and value <= 100 ->
              {:cont,
               {:ok, %{acc | test_cleanup_failures: value},
                MapSet.put(seen, :__test_cleanup_failures)}}

            true ->
              {:halt, {:error, :invalid_materializer_options}}
          end

        {:__test_cleanup_fail_after_identity, value}, {:ok, acc, seen} ->
          cond do
            MapSet.member?(seen, :__test_cleanup_fail_after_identity) ->
              {:halt, {:error, :duplicate_materializer_option}}

            is_integer(value) and value >= 0 and value <= 100 ->
              {:cont,
               {:ok, %{acc | test_cleanup_fail_after_identity: value},
                MapSet.put(seen, :__test_cleanup_fail_after_identity)}}

            true ->
              {:halt, {:error, :invalid_materializer_options}}
          end

        {:__test_identity_capture_failures, value}, {:ok, acc, seen} ->
          cond do
            MapSet.member?(seen, :__test_identity_capture_failures) ->
              {:halt, {:error, :duplicate_materializer_option}}

            is_integer(value) and value >= 0 and value <= 100 ->
              {:cont,
               {:ok, %{acc | test_identity_capture_failures: value},
                MapSet.put(seen, :__test_identity_capture_failures)}}

            true ->
              {:halt, {:error, :invalid_materializer_options}}
          end

        {:__test_verify_hook, value}, {:ok, acc, seen} ->
          cond do
            MapSet.member?(seen, :__test_verify_hook) ->
              {:halt, {:error, :duplicate_materializer_option}}

            is_function(value, 1) or is_nil(value) ->
              {:cont,
               {:ok, %{acc | test_verify_hook: value}, MapSet.put(seen, :__test_verify_hook)}}

            true ->
              {:halt, {:error, :invalid_materializer_options}}
          end

        {key, _value}, {:ok, _acc, _seen} ->
          if MapSet.member?(allowed, key) do
            {:halt, {:error, :invalid_materializer_options}}
          else
            {:halt, {:error, :unknown_materializer_option}}
          end

        _other, _acc ->
          {:halt, {:error, :invalid_materializer_options}}
      end
    )
    |> case do
      {:ok, normalized, _seen} -> {:ok, normalized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_and_materialize(owner, absolute_deadline, normalized) do
    remaining = remaining_ms(absolute_deadline)

    if remaining <= 0 do
      {:error, :deadline_exceeded}
    else
      case ensure_supervisor() do
        :ok ->
          child =
            child_spec(
              owner: owner,
              deadline: absolute_deadline,
              authority: normalized.authority,
              __test_cleanup_failures: normalized.test_cleanup_failures,
              __test_cleanup_fail_after_identity: normalized.test_cleanup_fail_after_identity,
              __test_identity_capture_failures: normalized.test_identity_capture_failures,
              __test_verify_hook: normalized.test_verify_hook
            )

          case DynamicSupervisor.start_child(@supervisor, child) do
            {:ok, pid} ->
              # Worker's absolute deadline is authoritative. An independent call
              # timeout must not abandon a live worker/root.
              case GenServer.call(pid, :materialize, :infinity) do
                {:ok, %Lease{} = lease, view} when is_map(view) ->
                  {:ok, lease, view}

                {:error, {:cleanup_required, reason, %Lease{} = lease}} ->
                  {:error, {:cleanup_required, bound_public_reason(reason), lease}}

                {:error, reason} ->
                  case await_worker_absence(pid) do
                    :ok ->
                      {:error, bound_public_reason(reason)}

                    {:error, wait_reason} ->
                      # Worker still holds cleanup authority — never flatten to a
                      # bare ordinary materialization failure that implies absence.
                      {:error, {bound_public_reason(wait_reason), bound_public_reason(reason)}}
                  end

                _other ->
                  case force_stop_and_await(pid) do
                    :ok ->
                      {:error, :materialization_failed}

                    {:error, wait_reason} ->
                      {:error, {bound_public_reason(wait_reason), :materialization_failed}}
                  end
              end

            {:error, reason} ->
              {:error, bound_public_reason(reason)}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  catch
    :exit, {:noproc, _} ->
      {:error, :materializer_unavailable}

    :exit, _ ->
      {:error, :materializer_unavailable}
  end

  defp ensure_supervisor do
    case Process.whereis(@supervisor) do
      pid when is_pid(pid) -> :ok
      nil -> {:error, :materializer_supervisor_unavailable}
    end
  end

  defp try_worker_release(worker, token)
       when is_pid(worker) and is_binary(token) do
    if Process.alive?(worker) do
      call_worker(worker, {:release, token})
    else
      {:error, :lease_worker_unavailable}
    end
  end

  defp call_worker(worker, request) do
    if Process.alive?(worker) do
      # Cleanup is bounded by absence proof; do not abandon a live cleanup worker.
      GenServer.call(worker, request, :infinity)
    else
      {:error, :lease_worker_unavailable}
    end
  catch
    :exit, _ ->
      {:error, :lease_worker_unavailable}
  end

  defp prove_released_root_absent(%Lease{root_path: path}) when is_binary(path) do
    # Caller-side absence proof only — never recursive delete from the lease holder.
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, _} ->
        {:error, {:lease_worker_unavailable, :cleanup_path_remains}}

      {:error, _} ->
        {:error, {:lease_worker_unavailable, :cleanup_status_unknown}}
    end
  end

  defp prove_released_root_absent(_lease), do: {:error, :lease_worker_unavailable}

  defp force_stop_and_await(pid) when is_pid(pid) do
    ref = Process.monitor(pid)

    if Process.alive?(pid) do
      _ =
        try do
          DynamicSupervisor.terminate_child(@supervisor, pid)
        catch
          _, _ -> :ok
        end
    end

    await_down(ref, pid)
  end

  defp await_worker_absence(pid) when is_pid(pid) do
    # Success only on an exact DOWN. Process.alive?/1 alone is not proof, and a
    # timed-out wait must never be reported as ordinary absence.
    ref = Process.monitor(pid)
    await_down(ref, pid)
  end

  defp await_down(ref, pid) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      # Bounded wait for supervisor/worker shutdown; unconfirmed remains enforcing.
      120_000 ->
        Process.demonitor(ref, [:flush])
        {:error, :worker_stop_unconfirmed}
    end
  end

  defp make_lease(%{
         token: token,
         owner_pid: owner,
         root_path: root_path,
         root_identity: identity
       })
       when is_binary(token) and is_pid(owner) and is_binary(root_path) do
    {device, inode} =
      case identity do
        %{device: d, inode: i} when is_integer(d) and is_integer(i) -> {d, i}
        _ -> {nil, nil}
      end

    %Lease{
      token: token,
      worker: self(),
      owner: owner,
      root_path: root_path,
      root_device: device,
      root_inode: inode
    }
  end

  defp finalize_materialize_failure(reason, failed_state) do
    if owned_root?(failed_state) do
      case attempt_cleanup(failed_state) do
        :ok ->
          {:stop, :normal, {:error, bound_public_reason(reason)},
           clear_ownership(cancel_cleanup_timer(failed_state))}

        {:error, _} ->
          if Process.alive?(failed_state.owner_pid) do
            cleanup_state = %{failed_state | status: :cleanup_required}
            lease = make_lease(cleanup_state)

            {:reply, {:error, {:cleanup_required, bound_public_reason(reason), lease}},
             cleanup_state}
          else
            # Owner already gone: enter cleanup-pending retry rather than stop/forget.
            pending = schedule_cleanup_retry(%{failed_state | status: :cleanup_pending})
            {:reply, {:error, bound_public_reason(reason)}, pending}
          end
      end
    else
      {:stop, :normal, {:error, bound_public_reason(reason)}, failed_state}
    end
  end

  defp owned_root?(%{owned: true, root_path: path}) when is_binary(path), do: true
  defp owned_root?(_), do: false

  defp schedule_cleanup_retry(state) do
    state = cancel_cleanup_timer(state)
    delay = Map.get(state, :cleanup_retry_ms, @cleanup_retry_initial_ms)
    timer = Process.send_after(self(), :cleanup_retry, delay)
    next_delay = min(delay * 2, @cleanup_retry_max_ms)

    %{state | cleanup_timer: timer, cleanup_retry_ms: next_delay, status: :cleanup_pending}
  end

  defp cancel_cleanup_timer(%{cleanup_timer: timer} = state) when is_reference(timer) do
    _ = Process.cancel_timer(timer)
    # Flush an already-delivered retry message without blocking.
    receive do
      :cleanup_retry -> :ok
    after
      0 -> :ok
    end

    %{state | cleanup_timer: nil}
  end

  defp cancel_cleanup_timer(state), do: state

  defp attempt_cleanup_with_bounded_retries(state, attempts_left) when attempts_left <= 0 do
    {:error, state}
  end

  defp attempt_cleanup_with_bounded_retries(state, attempts_left) do
    case attempt_cleanup(state) do
      :ok ->
        {:ok, state}

      {:error, _} ->
        Process.sleep(@supervisor_cleanup_sleep_ms)
        attempt_cleanup_with_bounded_retries(state, attempts_left - 1)
    end
  end

  # ---------------------------------------------------------------------------
  # Materialization pipeline
  # ---------------------------------------------------------------------------

  defp materialize(state) do
    with :ok <- check_deadline_and_owner(state),
         {:ok, plan} <- checkout_plan(state.authority),
         :ok <- check_deadline_and_owner(state),
         {:ok, core_state, source_root, receipt, fingerprint} <- admit_plan(plan),
         :ok <- check_deadline_and_owner(state),
         {:ok, root_state} <- allocate_private_root(state) do
      case finish_materialization(
             root_state,
             core_state,
             source_root,
             receipt,
             fingerprint
           ) do
        {:ok, ready, view} ->
          {:ok, ready, view}

        {:error, reason} ->
          {:error, reason, root_state}
      end
    else
      {:error, reason} ->
        {:error, reason, state}

      {:error, reason, failed_state} ->
        {:error, reason, failed_state}
    end
  end

  defp finish_materialization(root_state, core_state, source_root, receipt, fingerprint) do
    with :ok <- check_deadline_and_owner(root_state),
         :ok <-
           materialize_tree(
             source_root,
             root_state.candidate_path,
             core_state,
             root_state
           ),
         :ok <-
           materialize_tree(
             source_root,
             root_state.base_path,
             core_state,
             root_state
           ),
         :ok <- check_deadline_and_owner(root_state),
         {:ok, plan2} <- checkout_plan(root_state.authority),
         {:ok, core_state2, _source2, receipt2, fingerprint2} <- admit_plan(plan2),
         :ok <-
           require_same_plan(
             fingerprint,
             fingerprint2,
             core_state,
             core_state2,
             receipt,
             receipt2
           ),
         :ok <- verify_destination_tree(root_state.candidate_path, core_state, root_state),
         :ok <- verify_destination_tree(root_state.base_path, core_state, root_state),
         :ok <- check_deadline_and_owner(root_state) do
      # Receipt stays exact Core evidence. Narrow verified-copy fact is outer-only.
      view = %{
        "candidate_path" => root_state.candidate_path,
        "base_path" => root_state.base_path,
        "receipt" => receipt,
        "verified_copy" => true
      }

      ready = %{
        root_state
        | status: :ready,
          receipt: receipt,
          plan_fingerprint: fingerprint,
          owned: true
      }

      {:ok, ready, view}
    end
  end

  defp checkout_plan(authority) when is_atom(authority) do
    try do
      case authority.checkout_plan() do
        {:ok, plan} when is_map(plan) ->
          {:ok, plan}

        {:error, reason} ->
          {:error, map_authority_error(reason)}

        _other ->
          {:error, :invalid_plan}
      end
    rescue
      _ -> {:error, :authority_checkout_failed}
    catch
      :throw, _ -> {:error, :authority_checkout_failed}
      :exit, _ -> {:error, :authority_checkout_failed}
    end
  end

  defp checkout_plan(_authority), do: {:error, :invalid_materializer_authority}

  defp map_authority_error(:linux_dependency_baseline_unavailable),
    do: :linux_dependency_baseline_unavailable

  defp map_authority_error(:linux_dependency_baseline_authority_unavailable),
    do: :linux_dependency_baseline_unavailable

  defp map_authority_error({:linux_dependency_baseline_drift, _}),
    do: :linux_dependency_baseline_drift

  defp map_authority_error(reason) when is_atom(reason), do: reason
  defp map_authority_error(_reason), do: :authority_checkout_failed

  defp admit_plan(plan) when is_map(plan) do
    with :ok <- validate_plan_shape(plan),
         {:ok, source_root} <- validate_source_root(plan["source_root"]),
         {:ok, manifest_path} <- validate_manifest_path_field(plan["manifest_path"]),
         {:ok, receipt} <- fetch_receipt(plan["receipt"]),
         {:ok, entries} <- fetch_entries(plan["materialization_entries"]),
         :ok <- enforce_entry_bounds(entries),
         core_input = %{"manifest" => receipt, "entries" => entries},
         {:ok, core_state} <- Core.new(core_input),
         normalized_receipt = Core.show(core_state),
         :ok <- require_exact_receipt(receipt, normalized_receipt),
         :ok <- require_platform(core_state),
         fingerprint =
           plan_fingerprint(source_root, manifest_path, normalized_receipt, core_state) do
      {:ok, core_state, source_root, normalized_receipt, fingerprint}
    end
  end

  defp admit_plan(_plan), do: {:error, :invalid_plan}

  defp validate_plan_shape(plan) when is_map(plan) do
    keys = plan |> Map.keys() |> Enum.filter(&is_binary/1) |> MapSet.new()

    cond do
      map_size(plan) > 16 ->
        {:error, :plan_too_large}

      not Enum.all?(Map.keys(plan), &is_binary/1) ->
        {:error, :invalid_plan}

      MapSet.difference(keys, @plan_keys) != MapSet.new() ->
        {:error, :unsupported_plan_keys}

      MapSet.difference(@plan_keys, keys) != MapSet.new() ->
        {:error, :incomplete_plan}

      MapSet.intersection(keys, @forbidden_plan_keys) != MapSet.new() ->
        {:error, :provisioning_claim_rejected}

      plan["kind"] != "linux_dependency_baseline_source" ->
        {:error, :invalid_plan_kind}

      plan["evidence_only"] != true ->
        {:error, :plan_not_evidence_only}

      true ->
        :ok
    end
  end

  defp validate_source_root(path) when is_binary(path) do
    limits = Core.limits()

    cond do
      path == "" ->
        {:error, :invalid_source_root}

      byte_size(path) > min(@max_path_bytes, limits.max_path_bytes) ->
        {:error, :source_root_too_long}

      not String.valid?(path) ->
        {:error, :invalid_source_root}

      String.contains?(path, <<0>>) ->
        {:error, :invalid_source_root}

      has_control_char?(path) ->
        {:error, :invalid_source_root}

      Path.type(path) != :absolute ->
        {:error, :source_root_not_absolute}

      String.contains?(path, "//") ->
        {:error, :non_canonical_source_root}

      path != "/" and String.ends_with?(path, "/") ->
        {:error, :non_canonical_source_root}

      Enum.any?(Path.split(path), &(&1 in [".", ".."])) ->
        {:error, :source_root_traversal}

      true ->
        {:ok, path}
    end
  end

  defp validate_source_root(_path), do: {:error, :invalid_source_root}

  defp validate_manifest_path_field(path) when is_binary(path) do
    case validate_source_root(path) do
      {:ok, validated} -> {:ok, validated}
      {:error, :invalid_source_root} -> {:error, :invalid_manifest_path}
      {:error, :source_root_not_absolute} -> {:error, :invalid_manifest_path}
      {:error, :source_root_traversal} -> {:error, :manifest_path_traversal}
      {:error, :source_root_too_long} -> {:error, :manifest_path_too_long}
      {:error, :non_canonical_source_root} -> {:error, :non_canonical_manifest_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_manifest_path_field(_path), do: {:error, :invalid_manifest_path}

  defp fetch_receipt(receipt) when is_map(receipt) do
    if map_size(receipt) > 32 or Enum.any?(Map.keys(receipt), &(not is_binary(&1))) do
      {:error, :invalid_receipt}
    else
      forbidden =
        MapSet.intersection(
          MapSet.new(Map.keys(receipt)),
          MapSet.new(["path", "paths", "inventory", "entries", "source_root", "manifest_path"])
        )

      if MapSet.size(forbidden) > 0 do
        {:error, :receipt_contains_paths}
      else
        {:ok, receipt}
      end
    end
  end

  defp fetch_receipt(_), do: {:error, :invalid_receipt}

  defp fetch_entries(entries) when is_list(entries) do
    limits = Core.limits()

    # Bound before any full-list length/duplicate traversal of hostile inputs.
    case count_entries_at_most(entries, limits.max_entries) do
      {:ok, _count} -> {:ok, entries}
      {:error, :too_many_entries} -> {:error, :too_many_entries}
    end
  end

  defp fetch_entries(_), do: {:error, :invalid_entries}

  defp count_entries_at_most(entries, max)
       when is_list(entries) and is_integer(max) and max >= 0 do
    count_entries_at_most(entries, max, 0)
  end

  defp count_entries_at_most([], _max, count), do: {:ok, count}

  defp count_entries_at_most([_ | _], max, count) when count >= max,
    do: {:error, :too_many_entries}

  defp count_entries_at_most([_ | rest], max, count),
    do: count_entries_at_most(rest, max, count + 1)

  defp enforce_entry_bounds(entries) when is_list(entries) do
    limits = Core.limits()

    total =
      Enum.reduce_while(entries, 0, fn
        %{"type" => "regular", "size" => size}, acc
        when is_integer(size) and size >= 0 ->
          next = acc + size

          if next > limits.max_total_bytes do
            {:halt, :overflow}
          else
            {:cont, next}
          end

        %{type: "regular", size: size}, acc when is_integer(size) and size >= 0 ->
          next = acc + size

          if next > limits.max_total_bytes do
            {:halt, :overflow}
          else
            {:cont, next}
          end

        _entry, acc ->
          {:cont, acc}
      end)

    if total == :overflow, do: {:error, :total_bytes_exceeded}, else: :ok
  end

  defp require_exact_receipt(plan_receipt, normalized_receipt)
       when is_map(plan_receipt) and is_map(normalized_receipt) do
    # After Core.new succeeds, the normalized show() is authoritative. The plan
    # receipt must equal that closed surface on every required field (no extra
    # path/inventory claims; extras already rejected in fetch_receipt/1).
    required = Map.keys(normalized_receipt)

    if Enum.all?(required, fn key ->
         Map.get(plan_receipt, key) == Map.get(normalized_receipt, key)
       end) do
      :ok
    else
      {:error, :receipt_mismatch}
    end
  end

  defp require_exact_receipt(_plan_receipt, _normalized_receipt), do: {:error, :receipt_mismatch}

  defp require_platform(%{platform: "linux/arm64"}), do: :ok
  defp require_platform(_), do: {:error, :unsupported_platform}

  defp plan_fingerprint(source_root, manifest_path, receipt, core_state) do
    entries = Core.materialization_entries(core_state)

    # Full admitted plan surface, including manifest locator, so a second checkout
    # that only relocates the manifest is still detected as drift.
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary(
        {source_root, manifest_path, receipt, entries},
        [:deterministic]
      )
    )
  end

  defp require_same_plan(fp1, fp2, state1, state2, receipt1, receipt2) do
    cond do
      fp1 != fp2 ->
        {:error, :baseline_drift_after_copy}

      Core.materialization_entries(state1) != Core.materialization_entries(state2) ->
        {:error, :baseline_drift_after_copy}

      receipt1 != receipt2 ->
        {:error, :baseline_drift_after_copy}

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private root allocation / cleanup
  # ---------------------------------------------------------------------------

  defp allocate_private_root(state) do
    case canonical_tmp_root() do
      {:ok, tmp} ->
        allocate_private_root_attempt(state, tmp, @max_root_name_attempts)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp allocate_private_root_attempt(state, _tmp, 0) do
    {:error, :root_exists, state}
  end

  defp allocate_private_root_attempt(state, tmp, attempts_left) when attempts_left > 0 do
    root = Path.join(tmp, random_root_name())

    case exclusive_mkdir(root) do
      :ok ->
        after_exclusive_root_create(state, root)

      {:error, :root_exists} ->
        allocate_private_root_attempt(state, tmp, attempts_left - 1)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp after_exclusive_root_create(state, root) do
    # Once mkdir succeeds we own cleanup responsibility for this path even if
    # identity capture is briefly unavailable.
    case capture_root_identity_with_retry(root, @max_identity_capture_attempts) do
      {:ok, identity} ->
        populate_owned_root(state, root, identity)

      {:error, reason} ->
        failed = %{
          state
          | root_path: root,
            root_identity: nil,
            candidate_path: nil,
            base_path: nil,
            owned: true
        }

        {:error, reason, failed}
    end
  end

  defp populate_owned_root(state, root, identity) do
    case File.chmod(root, 0o700) do
      :ok ->
        candidate = Path.join(root, "candidate")
        base = Path.join(root, "base")

        case create_child_dir(candidate) do
          :ok ->
            case create_child_dir(base) do
              :ok ->
                {:ok,
                 %{
                   state
                   | root_path: root,
                     root_identity: identity,
                     candidate_path: candidate,
                     base_path: base,
                     owned: true
                 }}

              {:error, reason} ->
                failed = %{
                  state
                  | root_path: root,
                    root_identity: identity,
                    candidate_path: candidate,
                    base_path: nil,
                    owned: true
                }

                {:error, reason, failed}
            end

          {:error, reason} ->
            failed = %{
              state
              | root_path: root,
                root_identity: identity,
                candidate_path: nil,
                base_path: nil,
                owned: true
            }

            {:error, reason, failed}
        end

      {:error, _} ->
        failed = %{
          state
          | root_path: root,
            root_identity: identity,
            owned: true
        }

        {:error, :chmod_failed, failed}
    end
  end

  defp canonical_tmp_root do
    case System.tmp_dir() do
      tmp when is_binary(tmp) and tmp != "" ->
        case SafePath.resolve_real(tmp) do
          {:ok, real} when is_binary(real) and real != "" ->
            case File.lstat(real, time: :posix) do
              {:ok, %File.Stat{type: :directory}} ->
                {:ok, real}

              _ ->
                {:error, :tmp_unavailable}
            end

          _other ->
            # No lexical fallback: fail closed when the temp root is not a real dir.
            {:error, :tmp_unavailable}
        end

      _ ->
        {:error, :tmp_unavailable}
    end
  end

  defp random_root_name do
    "arbor-linux-baseline-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  defp exclusive_mkdir(path) when is_binary(path) do
    case :file.make_dir(String.to_charlist(path)) do
      :ok ->
        :ok

      {:error, :eexist} ->
        {:error, :root_exists}

      {:error, _reason} ->
        {:error, :mkdir_failed}
    end
  end

  defp create_child_dir(path) do
    with :ok <- exclusive_mkdir(path),
         :ok <- chmod_path(path, 0o700) do
      :ok
    end
  end

  defp chmod_path(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, _} -> {:error, :chmod_failed}
    end
  end

  defp capture_root_identity_with_retry(path, attempts_left) do
    case Process.get({__MODULE__, :test_identity_capture_failures}) do
      n when is_integer(n) and n > 0 ->
        # Test-only: force the entire bounded capture sequence to fail so
        # root_identity remains nil. Production cleanup must not late-adopt.
        Process.put({__MODULE__, :test_identity_capture_failures}, 0)
        {:error, :root_identity_capture_failed}

      _ ->
        do_capture_root_identity_with_retry(path, attempts_left)
    end
  end

  defp do_capture_root_identity_with_retry(_path, attempts_left) when attempts_left <= 0 do
    # Exhausted bounded retries: never later capture whatever occupies the path.
    {:error, :root_identity_capture_failed}
  end

  defp do_capture_root_identity_with_retry(path, attempts_left) do
    case capture_root_identity(path) do
      {:ok, identity} ->
        {:ok, identity}

      {:error, :stat_failed} when attempts_left > 1 ->
        Process.sleep(1)
        do_capture_root_identity_with_retry(path, attempts_left - 1)

      {:error, :stat_failed} ->
        {:error, :root_identity_capture_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp capture_root_identity(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory, major_device: device, inode: inode}}
      when is_integer(device) and device >= 0 and is_integer(inode) and inode >= 0 ->
        {:ok, %{path: path, type: :directory, device: device, inode: inode}}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink_rejected}

      {:ok, %File.Stat{}} ->
        {:error, :not_a_directory}

      {:error, _} ->
        {:error, :stat_failed}
    end
  end

  defp attempt_cleanup(state) do
    case Process.get({__MODULE__, :test_cleanup_failures}) do
      n when is_integer(n) and n > 0 ->
        # Test-only seam: force a bounded number of cleanup failures, then real cleanup.
        Process.put({__MODULE__, :test_cleanup_failures}, n - 1)
        {:error, :cleanup_forced_failure}

      _ ->
        do_attempt_cleanup(state)
    end
  end

  defp do_attempt_cleanup(%{owned: true, root_path: path, root_identity: identity})
       when is_binary(path) and is_map(identity) do
    cleanup_owned_root(path, identity)
  rescue
    _ -> {:error, :cleanup_failed}
  catch
    _, _ -> {:error, :cleanup_failed}
  end

  defp do_attempt_cleanup(%{owned: true, root_path: path, root_identity: nil})
       when is_binary(path) do
    # Fail-closed: never late-adopt whatever currently occupies the path.
    # With root_identity=nil, cleanup may only prove absence; an existing path
    # is cleanup_identity_unknown and remains retained.
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _} -> {:error, :cleanup_identity_unknown}
      {:error, _} -> {:error, :cleanup_status_unknown}
    end
  rescue
    _ -> {:error, :cleanup_failed}
  catch
    _, _ -> {:error, :cleanup_failed}
  end

  defp do_attempt_cleanup(_state), do: :ok

  defp cleanup_owned_root(path, %{path: path, type: :directory, device: device, inode: inode}) do
    case File.lstat(path, time: :posix) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :directory, major_device: ^device, inode: ^inode}} ->
        # Identity matched. Never fall back to path-recursive rm_rf: a same-uid
        # replacement race between identity check and recursive delete could
        # remove a different tree. Unlink entries without following; on any
        # failure return a retryable error and retain authority.
        case Process.get({__MODULE__, :test_cleanup_fail_after_identity}) do
          n when is_integer(n) and n > 0 ->
            Process.put({__MODULE__, :test_cleanup_fail_after_identity}, n - 1)
            {:error, :cleanup_forced_after_identity}

          _ ->
            with :ok <- delete_dir_contents(path),
                 :ok <- prove_absence(path) do
              :ok
            else
              {:error, reason} -> {:error, reason}
            end
        end

      {:ok, %File.Stat{}} ->
        {:error, :cleanup_identity_mismatch}

      {:error, _} ->
        {:error, :cleanup_stat_failed}
    end
  end

  defp cleanup_owned_root(_path, _identity), do: {:error, :cleanup_identity_mismatch}

  defp delete_dir_contents(path) do
    case File.ls(path) do
      {:ok, names} ->
        Enum.reduce_while(names, :ok, fn name, :ok ->
          child = Path.join(path, name)

          case delete_entry(child) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          :ok ->
            case File.rmdir(path) do
              :ok -> :ok
              {:error, :enoent} -> :ok
              {:error, _} -> {:error, :cleanup_rmdir_failed}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :enoent} ->
        :ok

      {:error, _} ->
        {:error, :cleanup_list_failed}
    end
  end

  defp delete_entry(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory}} ->
        delete_dir_contents(path)

      {:ok, %File.Stat{type: :regular}} ->
        unlink_path(path)

      {:ok, %File.Stat{type: :symlink}} ->
        # Unlink the symlink inode itself; never follow outside targets.
        unlink_path(path)

      {:ok, %File.Stat{}} ->
        # FIFO/socket/device: remove the directory entry without opening it.
        unlink_path(path)

      {:error, :enoent} ->
        :ok

      {:error, _} ->
        {:error, :cleanup_stat_failed}
    end
  end

  defp unlink_path(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} -> {:error, :cleanup_rm_failed}
    end
  end

  defp prove_absence(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _} -> {:error, :cleanup_path_remains}
      {:error, _} -> {:error, :cleanup_status_unknown}
    end
  end

  defp clear_ownership(state) do
    %{
      state
      | status: :released,
        root_path: nil,
        root_identity: nil,
        candidate_path: nil,
        base_path: nil,
        receipt: nil,
        plan_fingerprint: nil,
        owned: false,
        token: nil,
        cleanup_retry_ms: @cleanup_retry_initial_ms
    }
  end

  # ---------------------------------------------------------------------------
  # Exact inventory copy
  # ---------------------------------------------------------------------------

  defp materialize_tree(source_root, dest_root, core_state, worker_state) do
    entries = Core.materialization_entries(core_state)

    with :ok <- require_empty_dir(dest_root),
         :ok <- check_deadline_and_owner(worker_state) do
      Enum.reduce_while(entries, :ok, fn entry, :ok ->
        case materialize_entry(source_root, dest_root, entry, worker_state) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp require_empty_dir(path) do
    case File.ls(path) do
      {:ok, []} -> :ok
      {:ok, _} -> {:error, :destination_not_empty}
      {:error, _} -> {:error, :destination_unavailable}
    end
  end

  defp materialize_entry(source_root, dest_root, %{type: "directory", path: rel}, worker_state) do
    with :ok <- check_deadline_and_owner(worker_state),
         :ok <- validate_rel_join(source_root, rel),
         :ok <- validate_rel_join(dest_root, rel),
         dest = Path.join(dest_root, rel),
         :ok <- ensure_parent_exists(dest_root, rel),
         :ok <- exclusive_mkdir(dest),
         :ok <- chmod_path(dest, 0o700) do
      :ok
    end
  end

  defp materialize_entry(
         source_root,
         dest_root,
         %{
           type: "regular",
           path: rel,
           size: size,
           sha256: sha256,
           executable: executable
         },
         worker_state
       ) do
    with :ok <- check_deadline_and_owner(worker_state),
         :ok <- validate_rel_join(source_root, rel),
         :ok <- validate_rel_join(dest_root, rel),
         src = Path.join(source_root, rel),
         dest = Path.join(dest_root, rel),
         :ok <- ensure_parent_exists(dest_root, rel),
         :ok <- copy_regular_file(src, dest, size, sha256, executable, worker_state) do
      :ok
    end
  end

  defp materialize_entry(_source_root, _dest_root, _entry, _worker_state),
    do: {:error, :invalid_entry}

  defp validate_rel_join(root, rel) when is_binary(root) and is_binary(rel) do
    joined = Path.join(root, rel)

    cond do
      String.contains?(rel, "\0") ->
        {:error, :unsafe_path}

      Path.type(rel) == :absolute ->
        {:error, :absolute_path}

      String.contains?(rel, "..") and Enum.any?(Path.split(rel), &(&1 == "..")) ->
        {:error, :path_traversal}

      not String.starts_with?(joined, root <> "/") and joined != root ->
        {:error, :path_traversal}

      true ->
        :ok
    end
  end

  defp ensure_parent_exists(dest_root, rel) do
    parent_rel = Path.dirname(rel)

    if parent_rel in [".", ""] do
      :ok
    else
      parent = Path.join(dest_root, parent_rel)

      case File.lstat(parent, time: :posix) do
        {:ok, %File.Stat{type: :directory}} -> :ok
        {:ok, _} -> {:error, :missing_parent}
        {:error, _} -> {:error, :missing_parent}
      end
    end
  end

  defp copy_regular_file(src, dest, size, sha256_hex, executable, worker_state)
       when is_binary(src) and is_binary(dest) and is_integer(size) and size >= 0 and
              is_binary(sha256_hex) and is_boolean(executable) do
    with :ok <- check_deadline_and_owner(worker_state),
         {:ok, pre} <- lstat_regular(src),
         :ok <- require_link_count_one(pre),
         :ok <- require_size(pre, size),
         :ok <- require_executable_bit(pre, executable),
         {:ok, src_io} <- open_read(src) do
      try do
        with :ok <- check_deadline_and_owner(worker_state),
             {:ok, opened} <- fstat_io(src_io),
             :ok <- match_identity(pre, opened),
             {:ok, dest_io} <- open_exclusive_write(dest) do
          try do
            with :ok <-
                   stream_copy(src_io, dest_io, size, sha256_hex, worker_state),
                 {:ok, after_stat} <- fstat_io(src_io),
                 :ok <- match_identity(pre, after_stat) do
              :ok
            end
          after
            _ = :file.close(dest_io)
          end
        end
      after
        _ = :file.close(src_io)
      end
      |> case do
        :ok ->
          mode = if executable, do: 0o700, else: 0o600

          case chmod_path(dest, mode) do
            :ok -> :ok
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          _ = File.rm(dest)
          {:error, reason}
      end
    end
  end

  defp lstat_regular(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        {:ok, stat}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink_rejected}

      {:ok, %File.Stat{type: :directory}} ->
        {:error, :not_a_regular_file}

      {:ok, %File.Stat{}} ->
        {:error, :special_file_rejected}

      {:error, :enoent} ->
        {:error, :source_missing}

      {:error, _} ->
        {:error, :stat_failed}
    end
  end

  defp require_link_count_one(%File.Stat{links: 1}), do: :ok
  defp require_link_count_one(%File.Stat{}), do: {:error, :hardlink_rejected}

  defp require_size(%File.Stat{size: size}, size) when is_integer(size), do: :ok
  defp require_size(_, _), do: {:error, :size_mismatch}

  defp require_executable_bit(%File.Stat{mode: mode}, true) do
    if (mode &&& 0o111) != 0, do: :ok, else: {:error, :executable_bit_mismatch}
  end

  defp require_executable_bit(%File.Stat{mode: mode}, false) do
    if (mode &&& 0o111) == 0, do: :ok, else: {:error, :executable_bit_mismatch}
  end

  defp open_read(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      {:ok, io} -> {:ok, io}
      {:error, :enoent} -> {:error, :source_missing}
      {:error, _} -> {:error, :source_open_failed}
    end
  end

  defp open_exclusive_write(path) do
    case :file.open(String.to_charlist(path), [:write, :raw, :binary, :exclusive]) do
      {:ok, io} -> {:ok, io}
      {:error, :eexist} -> {:error, :destination_exists}
      {:error, _} -> {:error, :destination_open_failed}
    end
  end

  defp fstat_io(io) do
    case :file.read_file_info(io, [{:time, :posix}]) do
      {:ok,
       {:file_info, size, type, _access, _atime, _mtime, _ctime, mode, links, major, _minor,
        inode, _uid, _gid}}
      when is_integer(size) and is_atom(type) ->
        {:ok,
         %{
           size: size,
           type: type,
           mode: mode,
           links: links,
           major_device: major,
           inode: inode
         }}

      {:error, _} ->
        {:error, :fstat_failed}

      _other ->
        {:error, :fstat_failed}
    end
  end

  defp match_identity(%File.Stat{} = pre, opened) when is_map(opened) do
    # Descriptor-bound: final fstat must retain admitted mode/link count/size/
    # device/inode from the pre-hash observation. Mode changes during hashing
    # are identity drift, not accepted silently.
    cond do
      opened.type != :regular ->
        {:error, :identity_drift}

      opened.size != pre.size ->
        {:error, :identity_drift}

      opened.mode != pre.mode ->
        {:error, :identity_drift}

      opened.major_device != pre.major_device ->
        {:error, :identity_drift}

      opened.inode != pre.inode ->
        {:error, :identity_drift}

      opened.links != pre.links ->
        {:error, :identity_drift}

      opened.links != 1 ->
        {:error, :hardlink_rejected}

      true ->
        :ok
    end
  end

  defp stream_copy(src_io, dest_io, expected_size, expected_sha_hex, worker_state) do
    hash = :crypto.hash_init(:sha256)
    stream_copy_loop(src_io, dest_io, expected_size, expected_sha_hex, worker_state, 0, hash)
  end

  defp stream_copy_loop(
         src_io,
         dest_io,
         expected_size,
         expected_sha_hex,
         worker_state,
         read_so_far,
         hash
       ) do
    with :ok <- check_deadline_and_owner(worker_state) do
      remaining = expected_size - read_so_far

      if remaining == 0 do
        case :file.read(src_io, 1) do
          :eof ->
            digest = :crypto.hash_final(hash) |> Base.encode16(case: :lower)

            if digest == expected_sha_hex and read_so_far == expected_size do
              :ok
            else
              {:error, :digest_mismatch}
            end

          {:ok, _} ->
            {:error, :size_mismatch}

          {:error, _} ->
            {:error, :read_failed}
        end
      else
        to_read = min(@chunk_size, remaining)

        case :file.read(src_io, to_read) do
          {:ok, data} when byte_size(data) > 0 ->
            case :file.write(dest_io, data) do
              :ok ->
                stream_copy_loop(
                  src_io,
                  dest_io,
                  expected_size,
                  expected_sha_hex,
                  worker_state,
                  read_so_far + byte_size(data),
                  :crypto.hash_update(hash, data)
                )

              {:error, _} ->
                {:error, :write_failed}
            end

          :eof ->
            {:error, :size_mismatch}

          {:ok, <<>>} ->
            {:error, :size_mismatch}

          {:error, _} ->
            {:error, :read_failed}
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Destination verification
  # ---------------------------------------------------------------------------

  defp verify_destination_tree(dest_root, core_state, worker_state) do
    entries = Core.materialization_entries(core_state)

    with :ok <- check_deadline_and_owner(worker_state),
         :ok <- maybe_test_verify_hook(worker_state, dest_root),
         :ok <- verify_entries(dest_root, entries, worker_state),
         :ok <- verify_no_extra_names(dest_root, entries, worker_state),
         :ok <- check_deadline_and_owner(worker_state) do
      :ok
    end
  end

  defp maybe_test_verify_hook(%{test_verify_hook: hook}, dest_root)
       when is_function(hook, 1) do
    case hook.(dest_root) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :verify_hook_failed}
    end
  end

  defp maybe_test_verify_hook(_worker_state, _dest_root), do: :ok

  defp verify_entries(dest_root, entries, worker_state) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case verify_entry(dest_root, entry, worker_state) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp verify_entry(dest_root, %{type: "directory", path: rel}, worker_state) do
    with :ok <- check_deadline_and_owner(worker_state) do
      path = Path.join(dest_root, rel)

      case File.lstat(path, time: :posix) do
        {:ok, %File.Stat{type: :directory, mode: mode}} ->
          if (mode &&& 0o777) == 0o700, do: :ok, else: {:error, :mode_mismatch}

        {:ok, %File.Stat{type: :symlink}} ->
          {:error, :symlink_rejected}

        {:ok, %File.Stat{}} ->
          {:error, :destination_type_mismatch}

        {:error, _} ->
          {:error, :destination_missing}
      end
    end
  end

  defp verify_entry(
         dest_root,
         %{
           type: "regular",
           path: rel,
           size: size,
           sha256: sha256,
           executable: executable
         },
         worker_state
       ) do
    path = Path.join(dest_root, rel)

    with :ok <- check_deadline_and_owner(worker_state),
         {:ok, pre} <- lstat_regular(path),
         :ok <- require_link_count_one(pre),
         :ok <- require_size(pre, size),
         :ok <- require_dest_mode(pre, executable),
         {:ok, io} <- open_read(path) do
      try do
        with :ok <- check_deadline_and_owner(worker_state),
             {:ok, opened} <- fstat_io(io),
             :ok <- match_identity(pre, opened),
             :ok <- require_fstat_dest_mode(opened, executable),
             :ok <-
               read_and_hash(
                 io,
                 size,
                 0,
                 :crypto.hash_init(:sha256),
                 sha256,
                 worker_state
               ),
             {:ok, after_stat} <- fstat_io(io),
             :ok <- match_identity(pre, after_stat),
             :ok <- require_fstat_dest_mode(after_stat, executable),
             :ok <- check_deadline_and_owner(worker_state) do
          :ok
        end
      after
        _ = :file.close(io)
      end
    end
  end

  defp verify_entry(_dest_root, _entry, _worker_state), do: {:error, :invalid_entry}

  defp require_dest_mode(%File.Stat{mode: mode}, true) do
    if (mode &&& 0o777) == 0o700, do: :ok, else: {:error, :mode_mismatch}
  end

  defp require_dest_mode(%File.Stat{mode: mode}, false) do
    if (mode &&& 0o777) == 0o600, do: :ok, else: {:error, :mode_mismatch}
  end

  defp require_fstat_dest_mode(%{mode: mode}, true) when is_integer(mode) do
    if (mode &&& 0o777) == 0o700, do: :ok, else: {:error, :mode_mismatch}
  end

  defp require_fstat_dest_mode(%{mode: mode}, false) when is_integer(mode) do
    if (mode &&& 0o777) == 0o600, do: :ok, else: {:error, :mode_mismatch}
  end

  defp require_fstat_dest_mode(_, _), do: {:error, :mode_mismatch}

  defp read_and_hash(io, expected_size, read_so_far, hash, expected_hex, worker_state) do
    with :ok <- check_deadline_and_owner(worker_state) do
      remaining = expected_size - read_so_far

      if remaining == 0 do
        case :file.read(io, 1) do
          :eof ->
            digest = :crypto.hash_final(hash) |> Base.encode16(case: :lower)
            if digest == expected_hex, do: :ok, else: {:error, :digest_mismatch}

          {:ok, _} ->
            {:error, :size_mismatch}

          {:error, _} ->
            {:error, :read_failed}
        end
      else
        to_read = min(@chunk_size, remaining)

        case :file.read(io, to_read) do
          {:ok, data} when byte_size(data) > 0 ->
            read_and_hash(
              io,
              expected_size,
              read_so_far + byte_size(data),
              :crypto.hash_update(hash, data),
              expected_hex,
              worker_state
            )

          :eof ->
            {:error, :size_mismatch}

          {:ok, <<>>} ->
            {:error, :size_mismatch}

          {:error, _} ->
            {:error, :read_failed}
        end
      end
    end
  end

  defp verify_no_extra_names(dest_root, entries, worker_state) do
    children_by_parent = expected_children_by_parent(entries)

    # Verify root listing and every declared directory listing.
    roots = Map.get(children_by_parent, "", MapSet.new())

    with :ok <- check_deadline_and_owner(worker_state),
         :ok <- verify_dir_listing(dest_root, roots) do
      entries
      |> Enum.filter(&(&1.type == "directory"))
      |> Enum.reduce_while(:ok, fn %{path: rel}, :ok ->
        case check_deadline_and_owner(worker_state) do
          :ok ->
            expected = Map.get(children_by_parent, rel, MapSet.new())
            dir = Path.join(dest_root, rel)

            case verify_dir_listing(dir, expected) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp expected_children_by_parent(entries) do
    Enum.reduce(entries, %{}, fn %{path: path}, acc ->
      parent = path_parent(path)
      name = Path.basename(path)
      set = Map.get(acc, parent, MapSet.new())
      Map.put(acc, parent, MapSet.put(set, name))
    end)
  end

  defp path_parent(path) do
    case Path.dirname(path) do
      "." -> ""
      parent -> parent
    end
  end

  defp verify_dir_listing(dir, expected_names) do
    case File.ls(dir) do
      {:ok, names} ->
        actual = MapSet.new(names)

        cond do
          MapSet.difference(actual, expected_names) != MapSet.new() ->
            {:error, :extra_destination_names}

          MapSet.difference(expected_names, actual) != MapSet.new() ->
            {:error, :missing_destination_names}

          true ->
            # Reject any non regular/directory via lstat of each name.
            Enum.reduce_while(names, :ok, fn name, :ok ->
              path = Path.join(dir, name)

              case File.lstat(path, time: :posix) do
                {:ok, %File.Stat{type: t}} when t in [:regular, :directory] ->
                  {:cont, :ok}

                {:ok, %File.Stat{type: :symlink}} ->
                  {:halt, {:error, :symlink_rejected}}

                {:ok, %File.Stat{}} ->
                  {:halt, {:error, :special_file_rejected}}

                {:error, _} ->
                  {:halt, {:error, :destination_stat_failed}}
              end
            end)
        end

      {:error, _} ->
        {:error, :destination_list_failed}
    end
  end

  # ---------------------------------------------------------------------------
  # Deadline / redaction / bounds
  # ---------------------------------------------------------------------------

  defp check_deadline_and_owner(%{deadline: deadline, owner_pid: owner})
       when is_integer(deadline) and is_pid(owner) do
    with :ok <- check_deadline(deadline) do
      if Process.alive?(owner), do: :ok, else: {:error, :owner_dead}
    end
  end

  defp check_deadline_and_owner(%{deadline: deadline}) when is_integer(deadline) do
    check_deadline(deadline)
  end

  defp check_deadline(deadline) when is_integer(deadline) do
    if System.monotonic_time(:millisecond) <= deadline do
      :ok
    else
      {:error, :deadline_exceeded}
    end
  end

  defp remaining_ms(deadline) when is_integer(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp bound_public_reason(reason) when is_atom(reason), do: reason

  defp bound_public_reason(reason) when is_tuple(reason) do
    arity = tuple_size(reason)

    if arity > 0 and arity <= @max_reason_tuple_arity do
      components = Tuple.to_list(reason)

      if Enum.all?(components, &is_atom/1) do
        reason
      else
        :materialization_failed
      end
    else
      :materialization_failed
    end
  end

  defp bound_public_reason(_reason), do: :materialization_failed

  defp redact_state(state) when is_map(state) do
    %{
      status: Map.get(state, :status),
      owner_pid: if(is_pid(Map.get(state, :owner_pid)), do: :redacted, else: nil),
      owner_ref: if(is_reference(Map.get(state, :owner_ref)), do: :redacted, else: nil),
      token: if(is_binary(Map.get(state, :token)), do: :redacted, else: nil),
      deadline: Map.get(state, :deadline),
      authority: Map.get(state, :authority),
      root_path: if(is_binary(Map.get(state, :root_path)), do: :redacted, else: nil),
      root_identity: if(is_map(Map.get(state, :root_identity)), do: :redacted, else: nil),
      candidate_path: if(is_binary(Map.get(state, :candidate_path)), do: :redacted, else: nil),
      base_path: if(is_binary(Map.get(state, :base_path)), do: :redacted, else: nil),
      receipt: if(is_map(Map.get(state, :receipt)), do: :redacted, else: nil),
      plan_fingerprint:
        if(is_binary(Map.get(state, :plan_fingerprint)), do: :redacted, else: nil),
      owned: Map.get(state, :owned),
      cleanup_retry_ms: Map.get(state, :cleanup_retry_ms),
      cleanup_timer: if(is_reference(Map.get(state, :cleanup_timer)), do: :redacted, else: nil),
      test_verify_hook:
        if(is_function(Map.get(state, :test_verify_hook)), do: :redacted, else: nil)
    }
  end

  defp redact_state(_), do: :redacted

  defp redact_status_field(status, key) do
    if Map.has_key?(status, key), do: Map.put(status, key, :redacted), else: status
  end

  defp has_control_char?(value) when is_binary(value), do: has_control_char_bytes?(value)
  defp has_control_char_bytes?(<<>>), do: false
  defp has_control_char_bytes?(<<c, _rest::binary>>) when c < 32 or c == 127, do: true
  defp has_control_char_bytes?(<<_c, rest::binary>>), do: has_control_char_bytes?(rest)
end
