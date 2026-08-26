defmodule Arbor.KernelRuntime.ProviderGate do
  @moduledoc """
  Generic startup-ordering barrier for closed provider roots.

  After this process wins its exact registered name, `init/1` admits
  its ordered roots via `Application.ensure_all_started/1`. It is not an
  application owner, rollback coordinator, or liveness bridge. Provider
  applications are VM-global monotonic state. A `rest_for_one` restart may
  re-call `ensure_all_started/1` (idempotent) and restart later Arbor
  children; that does not own provider liveness.

  Full-release inclusion and permanence of these `runtime: false` roots
  remain an explicit unsatisfied P1E-2 exit gate.
  """

  use GenServer

  @roots [:os_mon, :recon, :mint, :finch, :req]

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Arbor.KernelRuntime.provider_gate_child_spec(__MODULE__, @roots)
  end

  @doc false
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) when is_list(opts) do
    name = Keyword.fetch!(opts, :name)
    roots = Keyword.fetch!(opts, :roots)

    case GenServer.start_link(__MODULE__, roots, name: name) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} when is_pid(pid) ->
        {:error, {:provider_gate_name_collision, pid}}

      other ->
        other
    end
  end

  @impl true
  def init(roots) do
    case start_each(roots) do
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
