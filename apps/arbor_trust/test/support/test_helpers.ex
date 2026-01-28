defmodule Arbor.Trust.TestHelpers do
  @moduledoc """
  Shared test utilities for arbor_trust.
  """

  @doc """
  Safely stop a process by name or pid, tolerating the race condition
  where the process dies between the liveness check and the stop call.

  Handles both named processes (atoms) and direct pids. Returns `:ok`
  regardless of whether the process was alive.
  """
  @spec safe_stop(atom() | pid()) :: :ok
  def safe_stop(name) when is_atom(name) do
    if pid = Process.whereis(name) do
      safe_stop(pid)
    else
      :ok
    end
  end

  def safe_stop(pid) when is_pid(pid) do
    GenServer.stop(pid)
    :ok
  catch
    :exit, _ -> :ok
  end
end
