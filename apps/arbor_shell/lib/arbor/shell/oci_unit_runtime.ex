defmodule Arbor.Shell.OciUnitRuntime do
  @moduledoc false

  require Logger

  # Production OCI/Podman unit adapter. Uses the reviewed oci-unit launcher
  # mode (clone/fork permitted for pinned /usr/bin/podman argv) instead of
  # generic no-fork PortSession. Teardown kills the process group and also
  # issues reviewed `podman kill`/`rm --force` because conmon double-forks
  # out of the session.

  alias Arbor.Shell.ExecutablePolicy
  alias Arbor.Shell.ExecutablePolicy.Executable
  alias Arbor.Shell.Executor
  alias Arbor.Shell.OciHostEnv
  alias Arbor.Shell.OciHostEnvCore
  alias Arbor.Shell.OciUnitArgv
  alias Arbor.Shell.PortSession
  alias Arbor.Shell.SpawnCapableArgvLimits

  @runtime_path "/usr/bin/podman"
  @reap_timeout_ms 30_000
  @reap_max_output_bytes 8_192

  @doc false
  @spec monotonic_ms() :: integer()
  def monotonic_ms, do: System.monotonic_time(:millisecond)

  @spec start_command(term(), [String.t()], String.t(), term(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_command(executable, args, display_command, resource_profile, opts)
      when is_list(args) and is_binary(display_command) and is_list(opts) do
    with :ok <- require_runtime_executable(executable),
         :ok <- OciUnitArgv.review(args),
         :ok <- reject_launcher_opts(opts) do
      Logger.warning("shell oci unit start_command owner=#{inspect(self())}")

      PortSession.start_supervised_direct_for_oci_unit(
        executable,
        args,
        display_command,
        resource_profile,
        opts
      )
    end
  end

  def start_command(_executable, _args, _display_command, _resource_profile, _opts),
    do: {:error, :invalid_runtime_command}

  @spec kill(pid()) :: :ok
  def kill(session) when is_pid(session), do: PortSession.kill(session)
  def kill(_session), do: :ok

  @spec get_id(pid()) :: String.t() | nil
  def get_id(session) when is_pid(session) do
    PortSession.get_id(session)
  catch
    :exit, _ -> nil
  end

  def get_id(_session), do: nil

  @spec get_result(pid()) :: {:ok, map()} | {:error, term()}
  def get_result(session) when is_pid(session) do
    PortSession.get_result(session)
  catch
    :exit, reason -> {:error, reason}
  end

  def get_result(_session), do: {:error, :invalid_session}

  @doc false
  @spec authorize_unit_args(term()) :: :ok | {:error, term()}
  def authorize_unit_args(args), do: OciUnitArgv.review(args)

  @doc false
  @spec reap(term()) :: :ok
  def reap(unit_name) when is_binary(unit_name) do
    with :ok <- OciUnitArgv.review_unit_name(unit_name),
         {:ok, executable} <- resolve_runtime(),
         {:ok, env} <- closed_host_env() do
      _ = run_reap(executable, ["kill", "--signal", "KILL", unit_name], env)
      _ = run_reap(executable, ["rm", "--force", unit_name], env)
      :ok
    else
      _other ->
        :ok
    end
  end

  def reap(_unit_name), do: :ok

  defp require_runtime_executable(%Executable{path: @runtime_path}), do: :ok
  defp require_runtime_executable(_), do: {:error, :untrusted_path}

  defp reject_launcher_opts(opts) do
    if Keyword.has_key?(opts, :launcher_command) or Keyword.has_key?(opts, :execution_mode) or
         Keyword.has_key?(opts, :allow_fork) or Keyword.has_key?(opts, :fork_mode) do
      {:error, :invalid_runtime_command}
    else
      :ok
    end
  end

  defp resolve_runtime do
    case ExecutablePolicy.resolve(@runtime_path) do
      {:ok, %Executable{path: @runtime_path} = executable} -> {:ok, executable}
      {:ok, %Executable{}} -> {:error, :untrusted_path}
      {:error, _reason} -> {:error, :runtime_executable_unavailable}
    end
  end

  defp closed_host_env do
    case OciHostEnv.resolve() do
      {:ok, env} ->
        case OciHostEnvCore.require_closed(env) do
          :ok -> {:ok, env}
          error -> error
        end

      _other ->
        {:error, :rootless_host_env_unavailable}
    end
  end

  defp run_reap(executable, args, env) do
    Executor.run_oci_unit(executable, args,
      cwd: "/",
      clear_env: true,
      env: env,
      timeout: @reap_timeout_ms,
      max_output_bytes:
        min(@reap_max_output_bytes, SpawnCapableArgvLimits.max_command_arg_bytes())
    )
  end
end
