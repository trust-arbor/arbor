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
    with {:ok, handle} <-
           open_with_launcher(
             launcher_command,
             executable,
             args,
             opts,
             start_time,
             timeout,
             max_output_bytes
           ),
         :ok <- start(handle, Keyword.get(opts, :stdin)),
         # One-shot path always closes child stdin after optional initial bytes so
         # EOF-reading programs (e.g. cat) exit. Interactive PortSession leaves
         # stdin open for later send_input/2.
         {:ok, handle} <- close_stdin(handle) do
      collect(handle, Keyword.get(opts, :cancel_id), [], 0)
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

  def decode_message(_handle, _message), do: :ignore

  defp collect(%__MODULE__{} = handle, cancel_id, acc, bytes) do
    remaining = remaining_ms(handle.deadline)

    if remaining <= 0 do
      finish_forced(handle, :timeout, acc)
    else
      receive do
        {port, {:data, <<@output, data::binary>>}} when port == handle.port ->
          collect(handle, cancel_id, [data | acc], bytes + byte_size(data))

        {port, {:data, <<@terminal, reason, exit_code::signed-big-32>>}}
        when port == handle.port ->
          settle_terminal_port(port)

          {:ok,
           %{
             reason: decode_reason(reason),
             exit_code: max(exit_code, 0),
             output: acc_to_binary(acc)
           }}

        {port, {:data, <<@error, message::binary>>}} when port == handle.port ->
          cleanup_error(handle, {:launcher_error, message})

        {port, {:exit_status, status}} when port == handle.port ->
          cleanup_error(handle, {:launcher_exited_without_terminal, status})

        {:cancel_shell_execution, ^cancel_id} when not is_nil(cancel_id) ->
          finish_forced(handle, :cancelled, acc)
      after
        remaining -> finish_forced(handle, :timeout, acc)
      end
    end
  end

  defp finish_forced(handle, reason, acc) do
    {:ok, terminal_reason} = terminate_until_exhausted(handle, reason)
    {:ok, %{reason: terminal_reason, exit_code: 137, output: acc_to_binary(acc)}}
  end

  defp cleanup_error(handle, original_reason) do
    {:ok, _terminal_reason} = terminate_until_exhausted(handle, :cancelled)
    {:error, original_reason}
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

  defp kill_group(group_id) when is_integer(group_id) and group_id > 0 do
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
