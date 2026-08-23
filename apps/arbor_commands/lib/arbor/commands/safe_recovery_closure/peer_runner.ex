defmodule Arbor.Commands.SafeRecoveryClosure.PeerRunner do
  @moduledoc """
  Monitored OTP `:peer` ownership for the E0B3 closure probe.

  Starts one descendant BEAM over `standard_io` using the current pinned
  Erlang executable, injects a process-private `RELEASE_COOKIE` and
  manager-owned ephemeral Security authority root, installs the admitted
  artifact ebin path plus the Commands probe path, and invokes only the
  fixed Commands-owned probe MFA. Callers cannot choose the executable,
  module, function, cookie, environment, authority root, or Erlang arguments.
  This module does not change K3B scenarios or baselines.
  """

  alias Arbor.Commands.SafeRecoveryClosure.{PeerProbe, ReleaseLayout}
  alias Arbor.Common.SafePath

  @probe_module PeerProbe
  @probe_function :measure
  @probe_arity 1

  @boot_timeout_ms 30_000
  @call_timeout_ms 60_000
  @shutdown_timeout_ms 5_000
  @worker_slack_ms 5_000
  @cookie_bytes 32
  @authority_root_token_bytes 32
  @authority_root_create_attempts 4
  # Keep this prefix and the 64-character lowercase-hex token contract paired
  # with PeerProbe's validation constants.
  @authority_root_prefix "arbor-e0b3-security-"
  @authority_root_cleanup_opts [max_entries: 100_000, timeout_ms: 10_000]
  @max_code_paths 512
  @max_path_bytes 4_096
  @max_path_bytes_total 256_000

  @spec probe_mfa() :: {module(), atom(), 1}
  def probe_mfa, do: {@probe_module, @probe_function, @probe_arity}

  @spec measure(String.t()) :: {:ok, map()} | {:error, term()}
  def measure(release_root) when is_binary(release_root) do
    with {:ok, ebins} <- ReleaseLayout.admit(release_root),
         {:ok, runtime} <- seed_ebins(),
         {:ok, commands} <- commands_ebin(),
         {:ok, paths} <- admit_paths(runtime ++ ebins ++ [commands]) do
      cookie = random_cookie()
      run_with_ephemeral_root(cookie, paths, release_root, "safe_recovery", nil)
    end
  end

  def measure(_), do: {:error, :invalid_release_root}

  if Mix.env() == :test do
    @doc false
    @spec __test_measure__(String.t(), String.t() | [String.t()]) ::
            {:ok, map()} | {:error, term()}
    def __test_measure__(release_root, profile_or_selected)
        when is_binary(release_root) do
      with {:ok, ebins} <- ReleaseLayout.admit(release_root),
           {:ok, runtime} <- seed_ebins(),
           {:ok, commands} <- commands_ebin(),
           {:ok, paths} <- admit_paths(runtime ++ ebins ++ [commands]) do
        cookie = random_cookie()
        run_with_ephemeral_root(cookie, paths, release_root, profile_or_selected, nil)
      end
    end

    def __test_measure__(_, _), do: {:error, :invalid_test_measure}

    @doc false
    @spec __test_measure__(String.t(), String.t() | [String.t()], pid()) ::
            {:ok, map()} | {:error, term()}
    def __test_measure__(release_root, profile_or_selected, observer)
        when is_binary(release_root) and is_pid(observer) do
      with {:ok, ebins} <- ReleaseLayout.admit(release_root),
           {:ok, runtime} <- seed_ebins(),
           {:ok, commands} <- commands_ebin(),
           {:ok, paths} <- admit_paths(runtime ++ ebins ++ [commands]) do
        cookie = random_cookie()
        run_with_ephemeral_root(cookie, paths, release_root, profile_or_selected, observer)
      end
    end

    def __test_measure__(_, _, _), do: {:error, :invalid_test_measure}

    @doc false
    @spec __test_authority_root_validation__(String.t(), :missing | :wrong_prefix) ::
            {:error, term()}
    def __test_authority_root_validation__(release_root, mode)
        when is_binary(release_root) and mode in [:missing, :wrong_prefix] do
      with {:ok, ebins} <- ReleaseLayout.admit(release_root),
           {:ok, runtime} <- seed_ebins(),
           {:ok, commands} <- commands_ebin(),
           {:ok, paths} <- admit_paths(runtime ++ ebins ++ [commands]) do
        cookie = random_cookie()
        request = {:authority_root_validation, mode}
        run_with_ephemeral_root(cookie, paths, release_root, request, nil)
      end
    end

    def __test_authority_root_validation__(_, _), do: {:error, :invalid_test_measure}
  end

  defp run_with_ephemeral_root(cookie, paths, release_root, request, observer) do
    caller = self()
    token = make_ref()

    {manager, manager_mon} =
      spawn_monitor(fn ->
        authority_root_manager(caller, token, cookie, paths, release_root, request, observer)
      end)

    await_authority_root_manager(token, manager, manager_mon)
  end

  defp authority_root_manager(caller, token, cookie, paths, release_root, request, observer) do
    caller_mon = Process.monitor(caller)

    case create_ephemeral_authority_root(observer) do
      {:ok, identity} ->
        result =
          run_managed_peer(
            caller,
            caller_mon,
            token,
            cookie,
            paths,
            release_root,
            identity.path,
            request,
            observer
          )

        final_result =
          case result do
            {:settled, work_result} ->
              case cleanup_authority_root(identity) do
                :ok -> redact_authority_root_result(work_result, identity.path)
                {:error, _reason} -> {:error, :authority_root_cleanup_failed}
              end

            {:unsettled, _reason} ->
              {:error, :authority_root_cleanup_failed}
          end

        send_result_if_alive(caller, token, final_result)

      {:error, reason} ->
        send_result_if_alive(caller, token, {:error, reason})
    end
  end

  defp run_managed_peer(
         caller,
         caller_mon,
         token,
         cookie,
         paths,
         release_root,
         authority_root,
         request,
         observer
       ) do
    if caller_down?(caller, caller_mon) do
      {:settled, {:error, :measurement_caller_down}}
    else
      manager = self()
      cancel_ref = make_ref()

      {runner, runner_mon} =
        spawn_monitor(fn ->
          result =
            capture_owned_result(
              cookie,
              paths,
              release_root,
              authority_root,
              request,
              cancel_ref,
              observer
            )

          send(manager, {cancel_ref, :result, result})
        end)

      deadline = monotonic_ms() + worker_budget_ms() + @shutdown_timeout_ms

      await_managed_peer(
        caller,
        caller_mon,
        token,
        runner,
        runner_mon,
        cancel_ref,
        false,
        deadline
      )
    end
  end

  defp await_authority_root_manager(token, manager, manager_mon) do
    receive do
      {^token, :result, result} ->
        Process.demonitor(manager_mon, [:flush])
        result

      {:DOWN, ^manager_mon, :process, ^manager, reason} ->
        receive do
          {^token, :result, result} -> result
        after
          0 -> {:error, {:authority_root_manager_down, reason}}
        end
    end
  end

  defp await_managed_peer(
         caller,
         caller_mon,
         token,
         runner,
         runner_mon,
         cancel_ref,
         cancelled?,
         deadline
       ) do
    timeout = max(0, deadline - monotonic_ms())

    receive do
      {^cancel_ref, :result, result} ->
        case await_down(runner_mon, @shutdown_timeout_ms) do
          :ok -> {:settled, result}
          :timeout -> {:unsettled, :runner_down_missing}
        end

      {:DOWN, ^runner_mon, :process, ^runner, reason} ->
        case flush_managed_result(cancel_ref) do
          {:ok, result} -> {:settled, result}
          :none -> {:unsettled, {:runner_down, reason}}
        end

      {:DOWN, ^caller_mon, :process, ^caller, _reason} ->
        send(runner, {cancel_ref, :cancel})

        await_managed_peer(
          caller,
          caller_mon,
          token,
          runner,
          runner_mon,
          cancel_ref,
          true,
          monotonic_ms() + worker_budget_ms()
        )

      {^token, :cancel} when not cancelled? ->
        send(runner, {cancel_ref, :cancel})

        await_managed_peer(
          caller,
          caller_mon,
          token,
          runner,
          runner_mon,
          cancel_ref,
          true,
          monotonic_ms() + worker_budget_ms()
        )
    after
      timeout ->
        if cancelled? do
          {:unsettled, :runner_cancel_timeout}
        else
          send(runner, {cancel_ref, :cancel})

          await_managed_peer(
            caller,
            caller_mon,
            token,
            runner,
            runner_mon,
            cancel_ref,
            true,
            monotonic_ms() + worker_budget_ms()
          )
        end
    end
  end

  defp caller_down?(caller, caller_mon) do
    receive do
      {:DOWN, ^caller_mon, :process, ^caller, _reason} -> true
    after
      0 -> not Process.alive?(caller)
    end
  end

  defp flush_managed_result(cancel_ref) do
    receive do
      {^cancel_ref, :result, result} -> {:ok, result}
    after
      0 -> :none
    end
  end

  defp send_result_if_alive(caller, token, result) do
    if Process.alive?(caller), do: send(caller, {token, :result, result})
    result
  end

  defp capture_owned_result(
         cookie,
         paths,
         release_root,
         authority_root,
         request,
         cancel_ref,
         observer
       ) do
    run_owned(cookie, paths, release_root, authority_root, request, cancel_ref, observer)
  catch
    kind, reason -> {:error, {:peer_runner_crash, {kind, reason}}}
  end

  defp run_owned(cookie, paths, release_root, authority_root, request, cancel_ref, observer) do
    parent = self()
    token = make_ref()
    budget_ms = worker_budget_ms()

    {worker, worker_mon} =
      spawn_monitor(fn ->
        owned_worker(
          parent,
          token,
          cookie,
          paths,
          release_root,
          authority_root,
          request,
          observer
        )
      end)

    deadline = monotonic_ms() + budget_ms
    await_owned(token, cancel_ref, worker, worker_mon, nil, nil, nil, false, false, deadline)
  end

  defp owned_worker(
         caller,
         token,
         cookie,
         paths,
         release_root,
         authority_root,
         request,
         observer
       ) do
    guardian = spawn_link(fn -> guard_caller(caller) end)
    send(caller, {token, :guardian, guardian})

    result =
      case start_peer(cookie, release_root, authority_root) do
        {:ok, control} ->
          send(caller, {token, :control, control})
          notify_peer_control_observer(observer, control)
          work_result = invoke_work(control, paths, request)
          true = Process.unlink(control)
          stop_result = stop_peer(control)
          finish_work(work_result, stop_result, control)

        {:error, _} = err ->
          err
      end

    case reap_guardian(guardian) do
      :ok ->
        send(caller, {token, :result, result})

      {:error, reason} ->
        send(caller, {token, :result, {:error, {:guardian_reap_failed, reason}}})
    end
  end

  defp invoke_work(control, paths, request) do
    with :ok <- add_paths(control, paths),
         :ok <- start_elixir(control) do
      call_probe(control, request)
    end
  catch
    kind, reason ->
      {:error, {:peer_crash, {kind, reason}}}
  end

  defp finish_work(result, :ok, _control), do: result

  defp finish_work(_result, {:error, reason}, control) do
    {:error, {:peer_cleanup_failed, control, reason}}
  end

  defp start_peer(cookie, release_root, authority_root) do
    with {:ok, exec} <- pinned_erlang_executable() do
      case :peer.start_link(fixed_start_opts(exec, cookie, release_root, authority_root)) do
        {:ok, control, _node} when is_pid(control) -> {:ok, control}
        {:ok, control} when is_pid(control) -> {:ok, control}
        {:error, reason} -> {:error, {:peer_boot_failed, reason}}
      end
    end
  catch
    :exit, {:timeout, _} ->
      {:error, {:peer_boot_timeout, @boot_timeout_ms}}

    kind, reason ->
      {:error, {:peer_boot_failed, {kind, reason}}}
  end

  defp fixed_start_opts(exec, cookie, release_root, authority_root) do
    %{
      connection: :standard_io,
      exec: String.to_charlist(exec),
      wait_boot: @boot_timeout_ms,
      shutdown: {:halt, @shutdown_timeout_ms},
      peer_down: :crash,
      env: [
        {~c"RELEASE_COOKIE", String.to_charlist(cookie)},
        {~c"RELEASE_ROOT", String.to_charlist(release_root)},
        {~c"MIX_ENV", ~c"prod"},
        {~c"ARBOR_HOME", String.to_charlist(absent_home())},
        {~c"ARBOR_SECURITY_STATE_DIR", String.to_charlist(authority_root)}
      ]
    }
  end

  defp pinned_erlang_executable do
    root = List.to_string(:code.root_dir())
    exec = Path.join([root, "bin", "erl"])

    cond do
      not String.valid?(exec) ->
        {:error, :peer_exec_invalid}

      true ->
        case File.lstat(exec) do
          {:ok, %{type: :regular, mode: mode}} ->
            if Bitwise.band(mode, 0o111) != 0 do
              {:ok, exec}
            else
              {:error, :peer_exec_not_executable}
            end

          {:ok, _} ->
            {:error, :peer_exec_not_regular}

          {:error, :enoent} ->
            {:error, :peer_exec_missing}

          {:error, reason} ->
            {:error, {:peer_exec_unreadable, reason}}
        end
    end
  end

  defp add_paths(control, paths) do
    charlists = Enum.map(paths, &String.to_charlist/1)

    case bounded_peer_call(control, :code, :add_paths, [charlists], :install) do
      {:ok, :ok} -> :ok
      {:ok, true} -> :ok
      {:ok, other} -> {:error, {:peer_code_path_install, other}}
      {:error, _} = err -> err
    end
  end

  defp start_elixir(control) do
    case bounded_peer_call(control, :application, :ensure_all_started, [:elixir], :elixir) do
      {:ok, {:ok, _started}} -> :ok
      {:ok, :ok} -> :ok
      {:ok, other} -> {:error, {:peer_elixir_start_failed, other}}
      {:error, _} = err -> err
    end
  end

  defp call_probe(control, request) when is_binary(request) do
    case bounded_peer_call(control, @probe_module, @probe_function, [request], :measure) do
      {:ok, {:ok, sample}} when is_map(sample) -> {:ok, sample}
      {:ok, {:error, reason}} -> {:error, {:peer_measure_failed, reason}}
      {:ok, other} -> {:error, {:peer_measure_invalid, other}}
      {:error, _} = err -> err
    end
  end

  defp call_probe(control, selected) when is_list(selected) do
    case bounded_peer_call(control, @probe_module, :__test_measure__, [selected], :test_measure) do
      {:ok, {:ok, sample}} when is_map(sample) -> {:ok, sample}
      {:ok, {:error, reason}} -> {:error, {:peer_measure_failed, reason}}
      {:ok, other} -> {:error, {:peer_measure_invalid, other}}
      {:error, _} = err -> err
    end
  end

  if Mix.env() == :test do
    defp call_probe(control, {:authority_root_validation, mode})
         when mode in [:missing, :wrong_prefix] do
      case bounded_peer_call(
             control,
             @probe_module,
             :__test_authority_root_validation__,
             [mode],
             :authority_root_validation
           ) do
        {:ok, {:error, reason}} -> {:error, {:peer_measure_failed, reason}}
        {:ok, other} -> {:error, {:peer_measure_invalid, other}}
        {:error, _} = err -> err
      end
    end
  end

  defp bounded_peer_call(control, module, function, args, context) do
    {:ok, :peer.call(control, module, function, args, @call_timeout_ms)}
  catch
    :exit, {:timeout, _} -> {:error, {:peer_call_timeout, context}}
    :exit, reason -> {:error, {:peer_call_crash, context, reason}}
    kind, reason -> {:error, {:peer_call_crash, context, {kind, reason}}}
  end

  defp stop_peer(control) when is_pid(control) do
    if Process.alive?(control) do
      mon = Process.monitor(control)

      try do
        _ = :peer.stop(control)
      catch
        _, _ -> Process.exit(control, :kill)
      end

      case await_down(mon, @shutdown_timeout_ms) do
        :ok ->
          :ok

        :timeout ->
          Process.exit(control, :kill)

          case await_down(mon, @shutdown_timeout_ms) do
            :ok -> :ok
            :timeout -> {:error, {:peer_stop_timeout, control}}
          end
      end
    else
      :ok
    end
  end

  defp stop_peer(_), do: :ok

  defp guard_caller(caller) do
    mon = Process.monitor(caller)

    receive do
      {:DOWN, ^mon, :process, ^caller, reason} -> exit({:caller_death, reason})
    end
  end

  defp reap_guardian(guardian) when is_pid(guardian) do
    Process.unlink(guardian)
    Process.exit(guardian, :shutdown)
    mon = Process.monitor(guardian)

    case await_down(mon, @shutdown_timeout_ms) do
      :ok ->
        :ok

      :timeout ->
        Process.exit(guardian, :kill)

        case await_down(mon, @shutdown_timeout_ms) do
          :ok -> :ok
          :timeout -> {:error, {:guardian_alive, guardian}}
        end
    end
  end

  defp await_owned(
         token,
         cancel_ref,
         worker,
         worker_mon,
         control,
         control_mon,
         guardian,
         worker_down?,
         control_down?,
         deadline
       ) do
    timeout = max(0, deadline - monotonic_ms())

    receive do
      {^token, :guardian, new_guardian} when is_pid(new_guardian) ->
        await_owned(
          token,
          cancel_ref,
          worker,
          worker_mon,
          control,
          control_mon,
          new_guardian,
          worker_down?,
          control_down?,
          deadline
        )

      {^token, :control, new_control} when is_pid(new_control) ->
        await_owned(
          token,
          cancel_ref,
          worker,
          worker_mon,
          new_control,
          Process.monitor(new_control),
          guardian,
          worker_down?,
          false,
          deadline
        )

      {^token, :result, result} ->
        finish_await(
          worker,
          worker_mon,
          control,
          control_mon,
          guardian,
          worker_down?,
          control_down?,
          result
        )

      {:DOWN, ^worker_mon, :process, ^worker, reason} ->
        case flush_result(token) do
          {:ok, result} ->
            finish_await(
              worker,
              worker_mon,
              control,
              control_mon,
              guardian,
              true,
              control_down?,
              result
            )

          :none ->
            finish_await(
              worker,
              worker_mon,
              control,
              control_mon,
              guardian,
              true,
              control_down?,
              {:error, {:peer_crash, reason}}
            )
        end

      {:DOWN, ^control_mon, :process, ^control, _reason} ->
        await_owned(
          token,
          cancel_ref,
          worker,
          worker_mon,
          control,
          control_mon,
          guardian,
          worker_down?,
          true,
          deadline
        )

      {^cancel_ref, :cancel} ->
        cancel_owned(
          worker,
          worker_mon,
          control,
          control_mon,
          guardian,
          worker_down?,
          control_down?,
          :peer_cancelled
        )
    after
      timeout ->
        cancel_owned(
          worker,
          worker_mon,
          control,
          control_mon,
          guardian,
          worker_down?,
          control_down?,
          :peer_timeout
        )
    end
  end

  defp cancel_owned(
         worker,
         worker_mon,
         control,
         control_mon,
         guardian,
         worker_down?,
         control_down?,
         reason
       ) do
    Process.exit(worker, :kill)

    if is_pid(control) and not control_down? do
      Process.exit(control, :kill)
    end

    case await_descendants_down(
           worker,
           worker_mon,
           control,
           control_mon,
           guardian,
           worker_down?,
           control_down?
         ) do
      :ok -> {:error, reason}
      {:error, cleanup_reason} -> {:error, {:peer_cleanup_failed, cleanup_reason}}
    end
  end

  defp finish_await(
         worker,
         worker_mon,
         control,
         control_mon,
         guardian,
         worker_down?,
         control_down?,
         result
       ) do
    case await_descendants_down(
           worker,
           worker_mon,
           control,
           control_mon,
           guardian,
           worker_down?,
           control_down?
         ) do
      :ok -> result
      {:error, reason} -> {:error, {:peer_cleanup_failed, reason}}
    end
  end

  defp flush_result(token) do
    receive do
      {^token, :result, result} -> {:ok, result}
    after
      0 -> :none
    end
  end

  defp await_descendants_down(
         worker,
         worker_mon,
         control,
         control_mon,
         guardian,
         worker_down?,
         control_down?
       ) do
    with :ok <-
           await_pair_down(worker, worker_mon, control, control_mon, worker_down?, control_down?) do
      await_guardian_down(guardian)
    end
  end

  defp await_guardian_down(nil), do: :ok

  defp await_guardian_down(guardian) when is_pid(guardian) do
    mon = Process.monitor(guardian)

    case await_down(mon, @shutdown_timeout_ms) do
      :ok ->
        :ok

      :timeout ->
        Process.exit(guardian, :kill)

        case await_down(mon, @shutdown_timeout_ms) do
          :ok -> :ok
          :timeout -> {:error, {:guardian_alive, guardian}}
        end
    end
  end

  defp await_pair_down(worker, worker_mon, control, control_mon, worker_down?, control_down?) do
    deadline = monotonic_ms() + @shutdown_timeout_ms

    await_pair_loop(
      worker,
      worker_mon,
      control,
      control_mon,
      worker_down?,
      control_down? or is_nil(control_mon),
      deadline
    )
  end

  defp await_pair_loop(_worker, _worker_mon, _control, _control_mon, true, true, _deadline),
    do: :ok

  defp await_pair_loop(
         worker,
         worker_mon,
         control,
         control_mon,
         worker_down?,
         control_down?,
         deadline
       ) do
    timeout = max(0, deadline - monotonic_ms())

    receive do
      {:DOWN, ^worker_mon, :process, _, _} ->
        await_pair_loop(worker, worker_mon, control, control_mon, true, control_down?, deadline)

      {:DOWN, ^control_mon, :process, _, _} ->
        await_pair_loop(worker, worker_mon, control, control_mon, worker_down?, true, deadline)
    after
      timeout -> {:error, :monitor_down_missing}
    end
  end

  defp await_down(nil, _timeout_ms), do: :ok

  defp await_down(mon, timeout_ms) do
    receive do
      {:DOWN, ^mon, :process, _, _} -> :ok
    after
      timeout_ms -> :timeout
    end
  end

  @seed_apps [:elixir, :logger, :telemetry]

  defp seed_ebins do
    Enum.reduce_while(@seed_apps, {:ok, []}, fn app, {:ok, acc} ->
      case app_ebin(app) do
        {:ok, ebin} -> {:cont, {:ok, acc ++ [ebin]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp commands_ebin, do: app_ebin(:arbor_commands)

  defp app_ebin(app) do
    case :code.lib_dir(app) do
      {:error, _} ->
        {:error, {:peer_code_path_missing_app, app}}

      dir ->
        dir_string = if is_list(dir), do: List.to_string(dir), else: dir
        ebin = Path.join(dir_string, "ebin")
        name = Atom.to_string(app) <> ".app"

        cond do
          File.regular?(Path.join(ebin, name)) -> {:ok, ebin}
          File.regular?(Path.join(dir_string, name)) -> {:ok, dir_string}
          true -> {:error, {:peer_code_path_missing_app, app}}
        end
    end
  end

  defp admit_paths(paths) when is_list(paths) do
    if length(paths) > @max_code_paths do
      {:error, :peer_code_path_count}
    else
      reduce_paths(paths, [], MapSet.new(), 0)
    end
  end

  defp reduce_paths([], acc, _seen, _total), do: {:ok, Enum.reverse(acc)}

  defp reduce_paths([path | rest], acc, seen, total) do
    case admit_one_path(path) do
      {:ok, canonical, size} ->
        cond do
          MapSet.member?(seen, canonical) ->
            reduce_paths(rest, acc, seen, total)

          total + size > @max_path_bytes_total ->
            {:error, :peer_code_path_total_bytes}

          true ->
            reduce_paths(rest, [canonical | acc], MapSet.put(seen, canonical), total + size)
        end

      {:error, _} = error ->
        error
    end
  end

  defp admit_one_path(path) when is_binary(path) do
    cond do
      path == "" ->
        {:error, :peer_code_path_empty_entry}

      not String.valid?(path) ->
        {:error, :peer_code_path_invalid}

      byte_size(path) > @max_path_bytes ->
        {:error, :peer_code_path_entry_bytes}

      true ->
        case SafePath.resolve_real(path) do
          {:ok, real} ->
            case File.lstat(real) do
              {:ok, %{type: :directory}} -> {:ok, real, byte_size(real)}
              {:ok, _} -> {:error, :peer_code_path_not_directory}
              {:error, reason} -> {:error, {:peer_code_path_stat, reason}}
            end

          {:error, reason} ->
            {:error, {:peer_code_path_unresolved, reason}}
        end
    end
  end

  defp admit_one_path(_), do: {:error, :peer_code_path_invalid}

  defp random_cookie do
    :crypto.strong_rand_bytes(@cookie_bytes) |> Base.encode16(case: :lower)
  end

  defp create_ephemeral_authority_root(observer) do
    case SafePath.resolve_real(System.tmp_dir!()) do
      {:ok, tmp} ->
        create_ephemeral_authority_root(tmp, @authority_root_create_attempts, observer)

      {:error, _reason} ->
        {:error, :authority_root_create_failed}
    end
  end

  defp create_ephemeral_authority_root(_tmp, 0, _observer),
    do: {:error, :authority_root_create_failed}

  defp create_ephemeral_authority_root(tmp, attempts, observer) do
    token =
      :crypto.strong_rand_bytes(@authority_root_token_bytes)
      |> Base.encode16(case: :lower)

    path = Path.join(tmp, @authority_root_prefix <> token)

    case Arbor.Shell.create_private_owned_tree(path) do
      {:ok, identity} ->
        notify_authority_root_observer(observer, identity.path)
        {:ok, identity}

      {:error, :root_exists} ->
        create_ephemeral_authority_root(tmp, attempts - 1, observer)

      {:error, {:owned_tree_cleanup_retained, _reason, %{identity: identity}}}
      when is_map(identity) ->
        case cleanup_authority_root(identity) do
          :ok -> {:error, :authority_root_create_failed}
          {:error, _cleanup_reason} -> {:error, :authority_root_cleanup_failed}
        end

      {:error, {:owned_tree_cleanup_retained, _reason, _evidence}} ->
        {:error, :authority_root_cleanup_failed}

      {:error, _reason} ->
        {:error, :authority_root_create_failed}
    end
  end

  defp notify_authority_root_observer(observer, path)
       when is_pid(observer) and is_binary(path) do
    send(observer, {:safe_recovery_authority_root_created, path})
    :ok
  end

  defp notify_authority_root_observer(_observer, _path), do: :ok

  defp notify_peer_control_observer(observer, control)
       when is_pid(observer) and is_pid(control) do
    send(observer, {:safe_recovery_peer_control_started, control})
    :ok
  end

  defp notify_peer_control_observer(_observer, _control), do: :ok

  defp cleanup_authority_root(identity) do
    Arbor.Shell.remove_owned_tree(identity, @authority_root_cleanup_opts)
  rescue
    _exception -> {:error, :cleanup_crash}
  catch
    _kind, _reason -> {:error, :cleanup_crash}
  end

  defp redact_authority_root_result({:ok, sample}, root) when is_map(sample) do
    {:ok, redact_json_value(sample, root)}
  end

  defp redact_authority_root_result({:error, reason} = error, root) do
    if term_contains_authority_root?(reason, root),
      do: {:error, :peer_error_redacted},
      else: error
  end

  defp redact_authority_root_result(_invalid, _root),
    do: {:error, :peer_result_redaction_failed}

  defp redact_json_value(value, root) when is_binary(value),
    do: String.replace(value, root, "[REDACTED]")

  defp redact_json_value(value, root) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, redact_json_value(item, root)} end)
  end

  defp redact_json_value(value, root) when is_list(value),
    do: Enum.map(value, &redact_json_value(&1, root))

  defp redact_json_value(value, _root), do: value

  defp term_contains_authority_root?(value, root) when is_binary(value),
    do: String.contains?(value, root)

  defp term_contains_authority_root?(value, root) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.any?(&term_contains_authority_root?(&1, root))
  end

  defp term_contains_authority_root?(value, root) when is_list(value) do
    if List.ascii_printable?(value) do
      String.contains?(List.to_string(value), root)
    else
      Enum.any?(value, &term_contains_authority_root?(&1, root))
    end
  rescue
    _exception -> true
  end

  defp term_contains_authority_root?(value, root) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.any?(fn {key, item} ->
      term_contains_authority_root?(key, root) or term_contains_authority_root?(item, root)
    end)
  end

  defp term_contains_authority_root?(_value, _root), do: false

  defp absent_home do
    "/private/tmp/arbor-e0b3-absent-" <>
      Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp worker_budget_ms do
    @boot_timeout_ms + @call_timeout_ms + @shutdown_timeout_ms + @worker_slack_ms
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
