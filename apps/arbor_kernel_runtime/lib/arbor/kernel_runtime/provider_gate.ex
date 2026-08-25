defmodule Arbor.KernelRuntime.ProviderGate do
  @moduledoc """
  Startup-ordering barrier for Kernel Runtime provider roots.

  After this process wins its exact registered name, `init/1` admits
  `Core.roots()` via `Application.ensure_all_started/1`. It is not an
  application owner, rollback coordinator, or liveness bridge. Provider
  applications are VM-global monotonic state. A `rest_for_one` restart may
  re-call `ensure_all_started/1` (idempotent) and restart later Arbor
  children; that does not own provider liveness.

  Full-release inclusion and permanence of these `runtime: false` roots
  remain an explicit unsatisfied P1E-2 exit gate.
  """

  use GenServer

  alias Arbor.KernelRuntime.ProviderGate.Core

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      type: :worker,
      restart: :permanent
    }
  end

  @spec start_link(term()) :: {:ok, pid()} | {:error, term()}
  def start_link(_opts) do
    case GenServer.start_link(__MODULE__, :ok, name: __MODULE__) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} when is_pid(pid) ->
        {:error, {:provider_gate_name_collision, pid}}

      other ->
        other
    end
  end

  @impl true
  def init(:ok) do
    case start_each(Core.roots()) do
      :ok -> {:ok, %{}}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp start_each([]), do: :ok

  defp start_each([root | rest]) do
    case Application.ensure_all_started(root) do
      {:ok, _started} -> start_each(rest)
      {:error, reason} -> {:error, {:provider_start_failed, root, reason}}
    end
  end
end
