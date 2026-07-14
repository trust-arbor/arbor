defmodule Arbor.Shell.AppleContainerUnitRuntime do
  @moduledoc false

  # Thin same-library adapter over PortSession supervised direct execution.
  # Reuses ProcessGroup via PortSession; no new launcher.

  alias Arbor.Shell.PortSession

  @doc false
  @spec monotonic_ms() :: integer()
  def monotonic_ms, do: System.monotonic_time(:millisecond)

  @spec start_command(term(), [String.t()], String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_command(executable, args, display_command, opts)
      when is_list(args) and is_binary(display_command) and is_list(opts) do
    PortSession.start_supervised_direct(executable, args, display_command, opts)
  end

  def start_command(_executable, _args, _display_command, _opts),
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
end
