defmodule Arbor.Shell.ProcessGroup do
  @moduledoc false

  alias Arbor.Shell.ExecutablePolicy
  alias Arbor.Shell.ExecutablePolicy.Executable
  alias Arbor.Common.SafePath

  @ready 1
  @output 2
  @terminal 3
  @error 4

  @start 10
  @input 11
  @cancel 12
  @close_stdin 13

  @normal 0
  @timeout 1
  @output_limit 2
  @cancelled 3
  @containment_failure 4
  @stdin_frame_bytes 8_192

  @teardown_timeout_ms 2_000
  @cleanup_retry_ms 100

  @generic_launcher_command "exec"
  @apple_container_probe_launcher_command "apple-container-probe"

  defstruct [:port, :group_id, :deadline, :start_time, :max_output_bytes, stdin_open: true]

  @type t :: %__MODULE__{
          port: port(),
          group_id: pos_integer(),
          deadline: integer(),
          start_time: integer(),
          max_output_bytes: pos_integer(),
          stdin_open: boolean()
        }

  @type terminal_reason ::
          :normal | :timeout | :output_limit | :cancelled | :containment_failure

  @spec run(String.t(), [String.t()], keyword(), integer(), pos_integer(), pos_integer()) ::
          {:ok,
           %{
             reason: terminal_reason(),
             exit_code: non_neg_integer(),
             output: binary()
           }}
          | {:error, term()}
  def run(command, args, opts, start_time, timeout, max_output_bytes) do
    with {:ok, executable} <- ExecutablePolicy.resolve(command),
         result <- run_executable(executable, args, opts, start_time, timeout, max_output_bytes) do
      result
    else
      {:error, :executable_not_found} -> {:error, {:executable_not_found, command}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec run_executable(
          Executable.t(),
          [String.t()],
          keyword(),
          integer(),
          pos_integer(),
          pos_integer()
        ) :: {:ok, map()} | {:error, term()}
  def run_executable(executable, args, opts, start_time, timeout, max_output_bytes) do
    run_executable_with_launcher(
      @generic_launcher_command,
      executable,
      args,
      opts,
      start_time,
      timeout,
      max_output_bytes
    )
  end

  @doc false
  @spec run_apple_container_probe_executable(
          Executable.t(),
          [String.t()],
          keyword(),
          integer(),
          pos_integer(),
          pos_integer()
        ) :: {:ok, map()} | {:error, term()}
  def run_apple_container_probe_executable(
        executable,
        args,
        opts,
        start_time,
        timeout,
        max_output_bytes
      ) do
    run_executable_with_launcher(
      @apple_container_probe_launcher_command,
      executable,
      args,
      opts,
      start_time,
      timeout,
      max_output_bytes
    )
  end

  defp run_executable_with_launcher(
         launcher_command,
         executable,
         args,
         opts,
         start_time,
         timeout,
         max_output_bytes
       ) do
    # Port.open always links the native port to its owner. A fast target/launcher
    # close can deliver an asynchronous abnormal EXIT (:epipe) that would kill an
    # arbitrary one-shot caller. Own the port on a dedicated process that traps
    # exits, forwards cancel, and still tears down on caller death.
    caller = self()
    reply_ref = make_ref()
    cancel_id = Keyword.get(opts, :cancel_id)

    owner =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        caller_mon = Process.monitor(caller)

        result =
          try do
            run_owned_one_shot(
              launcher_command,
              executable,
              args,
              opts,
              start_time,
              timeout,
              max_output_bytes,
              caller_mon,
              caller
            )
          catch
            kind, reason -> {:error, {:port_owner_exception, {kind, reason}}}
          end

        # Always publish before exit so a concurrent :DOWN cannot race away a
        # successful terminal. The waiter drains a late reply after :DOWN.
        send(caller, {:"$arbor_shell_port_owner_reply", reply_ref, result})
      end)

    owner_mon = Process.monitor(owner)
    await_owned_one_shot_result(owner, owner_mon, reply_ref, cancel_id)
  end

  defp run_owned_one_shot(
         launcher_command,
         executable,
         args,
         opts,
         start_time,
         timeout,
         max_output_bytes,
         caller_mon,
         caller
       ) do
    with :ok <- ensure_caller_alive(caller_mon, caller),
         {:ok, handle} <-
           open_with_launcher(
             launcher_command,
             executable,
             args,
             opts,
             start_time,
             timeout,
             max_output_bytes
           ),
         :ok <- ensure_caller_alive(caller_mon, caller, handle),
         :ok <- start(handle, Keyword.get(opts, :stdin)),
         :ok <- ensure_caller_alive(caller_mon, caller, handle),
         # One-shot path always closes child stdin after optional initial bytes so
         # EOF-reading programs (e.g. cat) exit. Interactive PortSession leaves
         # stdin open for later send_input/2.
         {:ok, handle} <- close_stdin(handle) do
      collect(handle, Keyword.get(opts, :cancel_id), [], 0, caller_mon, caller)
    else
      {:error, :caller_dead} = error ->
        error

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_owned_one_shot_result(owner, owner_mon, reply_ref, cancel_id) do
    receive do
      {:"$arbor_shell_port_owner_reply", ^reply_ref, result} ->
        Process.demonitor(owner_mon, [:flush])
        result

      {:DOWN, ^owner_mon, :process, ^owner, reason} ->
        # Owner exit can be delivered before the reply already in this mailbox.
        # Prefer a published result over a false port_owner_failed under load.
        receive do
          {:"$arbor_shell_port_owner_reply", ^reply_ref, result} ->
            result
        after
          0 ->
            {:error, {:port_owner_failed, reason}}
        end

      {:cancel_shell_execution, ^cancel_id} when not is_nil(cancel_id) ->
        send(owner, {:cancel_shell_execution, cancel_id})
        await_owned_one_shot_result(owner, owner_mon, reply_ref, cancel_id)
    end
  end

  defp ensure_caller_alive(caller_mon, caller) do
    receive do
      {:DOWN, ^caller_mon, :process, ^caller, _reason} -> {:error, :caller_dead}
    after
      0 -> :ok
    end
  end

  defp ensure_caller_alive(caller_mon, caller, handle) do
    case ensure_caller_alive(caller_mon, caller) do
      :ok ->
        :ok

      {:error, :caller_dead} ->
        {:ok, _terminal_reason} = terminate_until_exhausted(handle, :cancelled)
        {:error, :caller_dead}
    end
  end

  @spec open(Executable.t(), [String.t()], keyword(), integer(), pos_integer(), pos_integer()) ::
          {:ok, t()} | {:error, term()}
  def open(%Executable{} = executable, args, opts, start_time, timeout, max_output_bytes)
      when is_list(args) do
    open_with_launcher(
      @generic_launcher_command,
      executable,
      args,
      opts,
      start_time,
      timeout,
      max_output_bytes
    )
  end

  defp open_with_launcher(
         launcher_command,
         %Executable{} = executable,
         args,
         opts,
         start_time,
         timeout,
         max_output_bytes
       )
       when is_binary(launcher_command) and is_list(args) do
    deadline = start_time + timeout

    with :ok <- validate_args(args),
         {:ok, cwd} <- capture_cwd(Keyword.get(opts, :cwd)),
         :ok <- ExecutablePolicy.verify_pinned(executable),
         {:ok, child_path} <- ExecutablePolicy.child_path(),
         {:ok, launcher} <- launcher_path(),
         remaining when remaining > 0 <- remaining_ms(deadline),
         {:ok, port} <-
           open_port(
             launcher,
             launcher_command,
             executable,
             args,
             opts,
             child_path,
             cwd,
             remaining,
             max_output_bytes
           ),
         {:ok, group_id} <- await_ready(port, deadline) do
      {:ok,
       %__MODULE__{
         port: port,
         group_id: group_id,
         deadline: deadline,
         start_time: start_time,
         max_output_bytes: max_output_bytes,
         stdin_open: true
       }}
    else
      remaining when is_integer(remaining) and remaining <= 0 -> {:error, :timeout_during_setup}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec start(t(), iodata() | nil) :: :ok | {:error, term()}
  def start(%__MODULE__{port: port} = handle, stdin) do
    with {:ok, encoded_stdin} <- encode_input(stdin),
         :ok <- command(port, <<@start>>),
         :ok <- maybe_send_stdin(port, encoded_stdin) do
      :ok
    else
      {:error, reason} ->
        {:ok, _terminal_reason} = terminate_until_exhausted(handle, :cancelled)
        {:error, reason}
    end
  end

  @doc """
  Close the child process stdin write end (EOF).

  Idempotent: a second close is a no-op success. After close, `send_input/2`
  fails closed without writing. One-shot `run_executable/6` always closes;
  interactive `PortSession` leaves stdin open for later input.
  """
  @spec close_stdin(t()) :: {:ok, t()} | {:error, term()}
  def close_stdin(%__MODULE__{stdin_open: false} = handle), do: {:ok, handle}

  def close_stdin(%__MODULE__{port: port} = handle) do
    case command(port, <<@close_stdin>>) do
      :ok ->
        {:ok, %{handle | stdin_open: false}}

      {:error, reason} ->
        {:ok, _terminal_reason} = terminate_until_exhausted(handle, :cancelled)
        {:error, reason}
    end
  end

  @spec terminate(t(), :timeout | :output_limit | :cancelled) ::
          {:ok, terminal_reason()} | {:error, term()}
  def terminate(%__MODULE__{} = handle, requested_reason) do
    _ = command(handle.port, <<@cancel>>)
    teardown_deadline = System.monotonic_time(:millisecond) + @teardown_timeout_ms

    case await_terminal(handle.port, teardown_deadline) do
      {:ok, reason, _exit_code} ->
        settle_terminal_port(handle.port)
        {:ok, normalize_requested_reason(reason, requested_reason)}

      {:error, _reason} ->
        kill_result = kill_group(handle.group_id)
        close_port(handle.port)

        case kill_result do
          :ok -> {:ok, requested_reason}
          {:error, reason} -> {:error, {:process_group_containment_failed, reason}}
        end
    end
  end

  @doc false
  @spec terminate_until_exhausted(t(), :timeout | :output_limit | :cancelled) ::
          {:ok, terminal_reason()}
  def terminate_until_exhausted(%__MODULE__{} = handle, requested_reason) do
    case terminate(handle, requested_reason) do
      {:ok, terminal_reason} ->
        {:ok, terminal_reason}

      {:error, _reason} ->
        Process.sleep(@cleanup_retry_ms)
        terminate_until_exhausted(handle, requested_reason)
    end
  end

  @spec send_input(t(), iodata()) :: :ok | {:error, term()}
  def send_input(%__MODULE__{stdin_open: false}, _data), do: {:error, :stdin_closed}

  def send_input(%__MODULE__{port: port}, data) do
    with {:ok, encoded} <- encode_input(data) do
      command(port, [<<@input>>, encoded])
    end
  end

  @spec decode_message(t(), term()) ::
          {:output, binary()}
          | {:terminal, terminal_reason(), non_neg_integer()}
          | {:error, term()}
          | :ignore
  def decode_message(%__MODULE__{port: port}, {port, {:data, <<@output, data::binary>>}}),
    do: {:output, data}

  def decode_message(
        %__MODULE__{port: port},
        {port, {:data, <<@terminal, reason, exit_code::signed-big-32>>}}
      ),
      do: {:terminal, decode_reason(reason), max(exit_code, 0)}

  def decode_message(%__MODULE__{port: port}, {port, {:data, <<@error, message::binary>>}}),
    do: {:error, {:launcher_error, message}}

  def decode_message(%__MODULE__{port: port}, {port, {:exit_status, status}}),
    do: {:error, {:launcher_exited_without_terminal, status}}

  # Abnormal native-port EXIT (e.g. :epipe) must fail closed without crashing a
  # trap_exit port owner such as PortSession.
  def decode_message(%__MODULE__{port: port}, {:EXIT, port, reason})
      when reason != :normal do
    {:error, {:port_exited, reason}}
  end

  def decode_message(%__MODULE__{port: port}, {:EXIT, port, :normal}), do: :ignore

  def decode_message(_handle, _message), do: :ignore

  defp collect(%__MODULE__{} = handle, cancel_id, acc, bytes, caller_mon, caller) do
    remaining = remaining_ms(handle.deadline)

    if remaining <= 0 do
      finish_forced(handle, :timeout, acc)
    else
      receive do
        {port, {:data, <<@output, data::binary>>}} when port == handle.port ->
          collect(handle, cancel_id, [data | acc], bytes + byte_size(data), caller_mon, caller)

        {port, {:data, <<@terminal, reason, exit_code::signed-big-32>>}}
        when port == handle.port ->
          # Terminal frame is the launcher's containment proof (terminate/2).
          # Do not re-kill the process group on normal terminals — PGID may be
          # reused and substring ps matches on launcher argv are false positives.
          settle_terminal_port(port)

          {:ok,
           %{
             reason: decode_reason(reason),
             exit_code: max(exit_code, 0),
             output: acc_to_binary(acc)
           }}

        {port, {:data, <<@error, message::binary>>}} when port == handle.port ->
          cleanup_error(handle, {:launcher_error, message})

        # Abnormal launcher death without a terminal frame. exit_status and
        # {:EXIT, port, reason} can arrive in either order (e.g. SIGKILL); both
        # must prove process-group exhaustion then publish containment_failure.
        {port, {:exit_status, status}} when port == handle.port ->
          finish_abnormal_launcher_exit(handle, acc, {:exit_status, status})

        {:EXIT, port, reason} when port == handle.port and reason != :normal ->
          finish_abnormal_launcher_exit(handle, acc, {:port_exit, reason})

        {:EXIT, port, :normal} when port == handle.port ->
          collect(handle, cancel_id, acc, bytes, caller_mon, caller)

        {:DOWN, ^caller_mon, :process, ^caller, _reason} ->
          finish_forced(handle, :cancelled, acc)

        {:cancel_shell_execution, ^cancel_id} when not is_nil(cancel_id) ->
          finish_forced(handle, :cancelled, acc)
      after
        remaining -> finish_forced(handle, :timeout, acc)
      end
    end
  end

  defp finish_forced(handle, reason, acc) do
    # terminate/2 treats a terminal frame as launcher containment proof; only
    # its no-terminal path invokes kill_group. Do not add a second kill on every
    # forced stop.
    {:ok, terminal_reason} = terminate_until_exhausted(handle, reason)
    {:ok, %{reason: terminal_reason, exit_code: 137, output: acc_to_binary(acc)}}
  end

  defp cleanup_error(handle, original_reason) do
    {:ok, _terminal_reason} = terminate_until_exhausted(handle, :cancelled)
    {:error, original_reason}
  end

  # Shared path for abnormal launcher death observed as exit_status and/or port
  # EXIT (ordering is racy under SIGKILL). The launcher cannot provide a terminal
  # proof here — exhaust the process group, then publish containment_failure.
  defp finish_abnormal_launcher_exit(
         %__MODULE__{port: port, group_id: group_id} = _handle,
         acc,
         _detail
       ) do
    close_port(port)
    drain_port_mailbox(port)

    case kill_group_until_exhausted(group_id) do
      :ok ->
        {:ok,
         %{
           reason: :containment_failure,
           exit_code: 137,
           output: acc_to_binary(acc)
         }}
    end
  end

  defp drain_port_mailbox(port) do
    receive do
      {^port, _message} -> drain_port_mailbox(port)
      {:EXIT, ^port, _reason} -> drain_port_mailbox(port)
    after
      0 -> :ok
    end
  end

  # Fail-closed retry for abnormal paths only: only :ok from kill_group/1 proves
  # the group is gone when the launcher did not emit a terminal frame.
  defp kill_group_until_exhausted(group_id) do
    case kill_group(group_id) do
      :ok ->
        :ok

      {:error, _reason} ->
        Process.sleep(@cleanup_retry_ms)
        kill_group_until_exhausted(group_id)
    end
  end

  defp await_ready(port, deadline) do
    remaining = remaining_ms(deadline)

    if remaining <= 0 do
      close_port(port)
      {:error, :timeout_during_setup}
    else
      receive do
        {^port, {:data, <<@ready, group_id::unsigned-big-64>>}} when group_id > 0 ->
          {:ok, group_id}

        {^port, {:data, <<@error, message::binary>>}} ->
          close_port(port)
          {:error, {:launcher_error, message}}

        {^port, {:exit_status, status}} ->
          {:error, {:launcher_exited_before_ready, status}}

        {:EXIT, ^port, reason} when reason != :normal ->
          close_port(port)
          {:error, {:port_exited, reason}}

        {:EXIT, ^port, :normal} ->
          {:error, {:port_exited, :normal}}

        {:cancel_shell_execution, _cancel_id} ->
          close_port(port)
          {:error, :cancelled_during_setup}
      after
        remaining ->
          close_port(port)
          {:error, :timeout_during_setup}
      end
    end
  end

  defp await_terminal(port, deadline) do
    remaining = remaining_ms(deadline)

    if remaining <= 0 do
      {:error, :teardown_timeout}
    else
      receive do
        {^port, {:data, <<@terminal, reason, exit_code::signed-big-32>>}} ->
          {:ok, decode_reason(reason), max(exit_code, 0)}

        {^port, {:data, <<@output, _data::binary>>}} ->
          await_terminal(port, deadline)

        {^port, {:data, <<@error, message::binary>>}} ->
          {:error, {:launcher_error, message}}

        {^port, {:exit_status, status}} ->
          {:error, {:launcher_exited_during_teardown, status}}

        {:EXIT, ^port, reason} when reason != :normal ->
          {:error, {:port_exited, reason}}

        {:EXIT, ^port, :normal} ->
          {:error, {:port_exited, :normal}}
      after
        remaining -> {:error, :teardown_timeout}
      end
    end
  end

  defp open_port(
         launcher,
         launcher_command,
         executable,
         args,
         opts,
         child_path,
         cwd,
         timeout,
         max_output_bytes
       ) do
    # Identity is bound to executable.path (opened by the native launcher).
    # argv0 uses executable.name so multi-call binaries (busybox applets such as
    # /bin/echo → /bin/busybox) select the authorized applet. Using the resolved
    # path as argv0 makes basename "busybox" and breaks every applet.
    argv0 = multi_call_argv0(executable)

    launcher_args = [
      launcher_command,
      Integer.to_string(timeout),
      Integer.to_string(max_output_bytes),
      Integer.to_string(executable.device),
      Integer.to_string(executable.inode),
      Integer.to_string(executable.size),
      Integer.to_string(executable.mtime),
      Integer.to_string(executable.ctime),
      Integer.to_string(executable.mode),
      executable.sha256,
      executable.path,
      Integer.to_string(cwd.device),
      Integer.to_string(cwd.inode),
      cwd.path,
      "--",
      argv0
      | args
    ]

    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      {:packet, 4},
      args: Enum.map(launcher_args, &to_charlist/1),
      env:
        build_env(
          Keyword.get(opts, :env, %{}),
          child_path,
          Keyword.get(opts, :clear_env, false) == true
        )
    ]

    try do
      {:ok, Port.open({:spawn_executable, to_charlist(launcher)}, port_opts)}
    catch
      :error, reason -> {:error, {:port_open_failed, reason}}
    end
  end

  # When TrustedPath resolves a multi-call symlink (/bin/echo → /bin/busybox),
  # basename(path) differs from the pin name. Use the pin name as argv0 so the
  # applet is selected. Otherwise keep the full path as argv0 (macOS coreutils,
  # Apple control-plane fixed paths that require argv0 == absolute path).
  defp multi_call_argv0(%Executable{name: name, path: path})
       when is_binary(name) and is_binary(path) and byte_size(name) > 0 and
              byte_size(name) <= 64 do
    cond do
      String.contains?(name, ["/", "\\", <<0>>]) or name != Path.basename(name) ->
        path

      Path.basename(path) == name ->
        path

      true ->
        name
    end
  end

  defp multi_call_argv0(%Executable{path: path}), do: path

  # Port.env merges into the BEAM process environment by default. When
  # `clear_env` is true, every ambient key not in the intentional map is
  # unset via `{name, false}` so only the pinned PATH and trusted facade
  # values remain for the launcher/target. Trusted system callers leave
  # `clear_env` false unless they opt in.
  defp build_env(env, child_path, clear_env?) when is_map(env) do
    desired = Map.put(env, "PATH", child_path)
    entries = encode_env_entries(desired)

    if clear_env? do
      desired_keys = MapSet.new(Map.keys(desired))

      unsets =
        for {key, _value} <- System.get_env(),
            not MapSet.member?(desired_keys, key),
            do: {String.to_charlist(key), false}

      unsets ++ entries
    else
      entries
    end
  end

  defp build_env(_env, child_path, clear_env?), do: build_env(%{}, child_path, clear_env?)

  defp encode_env_entries(env) when is_map(env) do
    Enum.map(env, fn
      {key, false} when is_binary(key) ->
        {to_charlist(key), false}

      {key, value} when is_binary(key) and is_binary(value) ->
        {to_charlist(key), to_charlist(value)}
    end)
  end

  defp launcher_path do
    case :code.priv_dir(:arbor_shell) do
      path when is_list(path) ->
        launcher = Path.join(List.to_string(path), "arbor_shell_launcher")
        if File.regular?(launcher), do: {:ok, launcher}, else: {:error, :launcher_unavailable}

      _ ->
        {:error, :launcher_unavailable}
    end
  end

  # Optional test interceptor: fun.(group_id, &native_kill_group/1).
  # Production never sets this; public execute paths still require a real :ok
  # kill proof before returning a terminal.
  @kill_group_interceptor_env :process_group_kill_group_interceptor

  defp kill_group(group_id) when is_integer(group_id) and group_id > 0 do
    case Application.get_env(:arbor_shell, @kill_group_interceptor_env) do
      fun when is_function(fun, 2) -> fun.(group_id, &native_kill_group/1)
      _other -> native_kill_group(group_id)
    end
  end

  defp native_kill_group(group_id) when is_integer(group_id) and group_id > 0 do
    with {:ok, launcher} <- launcher_path() do
      try do
        case System.cmd(
               launcher,
               ["kill", Integer.to_string(group_id), Integer.to_string(@teardown_timeout_ms)],
               stderr_to_stdout: true
             ) do
          {_output, 0} -> :ok
          {output, status} -> {:error, {:kill_helper_failed, status, output}}
        end
      rescue
        error -> {:error, {:kill_helper_failed, Exception.message(error)}}
      catch
        :exit, reason -> {:error, {:kill_helper_failed, reason}}
      end
    end
  end

  defp command(port, payload) do
    if Port.command(port, payload), do: :ok, else: {:error, :port_command_failed}
  catch
    :error, reason -> {:error, reason}
  end

  defp maybe_send_stdin(_port, nil), do: :ok

  defp maybe_send_stdin(port, stdin) when is_binary(stdin) do
    send_stdin_frames(port, stdin)
  end

  defp send_stdin_frames(_port, <<>>), do: :ok

  defp send_stdin_frames(port, stdin) when byte_size(stdin) <= @stdin_frame_bytes do
    command(port, [<<@input>>, stdin])
  end

  defp send_stdin_frames(port, stdin) do
    <<frame::binary-size(@stdin_frame_bytes), rest::binary>> = stdin

    with :ok <- command(port, [<<@input>>, frame]) do
      send_stdin_frames(port, rest)
    end
  end

  defp encode_input(nil), do: {:ok, nil}

  defp encode_input(data) do
    {:ok, IO.iodata_to_binary(data)}
  rescue
    ArgumentError -> {:error, :invalid_shell_input}
  end

  defp close_port(port) do
    Port.close(port)
    :ok
  catch
    :error, _ -> :ok
  end

  defp settle_terminal_port(port) do
    deadline = System.monotonic_time(:millisecond) + 100
    await_port_exit(port, deadline)
    close_port(port)
  end

  defp await_port_exit(port, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      receive do
        {^port, {:exit_status, _status}} -> :ok
        {^port, _message} -> await_port_exit(port, deadline)
      after
        remaining -> :ok
      end
    else
      :ok
    end
  end

  defp validate_args(args) do
    if Enum.all?(args, &(is_binary(&1) and not String.contains?(&1, <<0>>))) do
      :ok
    else
      {:error, {:invalid_argv, :non_binary_or_nul_argument}}
    end
  end

  defp capture_cwd(nil), do: capture_cwd(File.cwd!())

  defp capture_cwd(cwd) when is_binary(cwd) do
    with {:ok, canonical} <- SafePath.resolve_real(cwd),
         {:ok, %File.Stat{type: :directory} = stat} <- File.stat(canonical, time: :posix) do
      {:ok, %{path: canonical, device: stat.major_device, inode: stat.inode}}
    else
      _other -> {:error, {:invalid_cwd, cwd}}
    end
  end

  defp capture_cwd(cwd), do: {:error, {:invalid_cwd, cwd}}

  defp remaining_ms(deadline), do: deadline - System.monotonic_time(:millisecond)

  defp decode_reason(@normal), do: :normal
  defp decode_reason(@timeout), do: :timeout
  defp decode_reason(@output_limit), do: :output_limit
  defp decode_reason(@cancelled), do: :cancelled
  defp decode_reason(@containment_failure), do: :containment_failure
  defp decode_reason(_unknown), do: :containment_failure

  defp normalize_requested_reason(:cancelled, requested), do: requested
  defp normalize_requested_reason(reason, _requested), do: reason

  defp acc_to_binary(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
end
