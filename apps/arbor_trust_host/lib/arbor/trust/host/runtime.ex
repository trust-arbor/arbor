defmodule Arbor.Trust.Host.Runtime do
  @moduledoc "Product boot and concrete provider roots. The canonical Trust application remains the sole authority owner."
  use Boundary, top_level?: true, deps: [Arbor.Trust, Arbor.KernelRuntime], exports: []
  @behaviour Arbor.Trust.Contracts.RuntimeHost
  @roots [:arbor_persistence_host, :phoenix_pubsub]
  @impl true
  def prepare_startup do
    with {:ok, _} <- Application.ensure_all_started(:arbor_kernel_runtime),
         {:ok, snapshot} when is_map(snapshot) <- Arbor.KernelRuntime.boot_profile() do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_bound}
    end
  end

  @impl true
  def start_profile, do: Arbor.KernelRuntime.start_profile()
  @impl true
  def provider_gate_child_spec(name, []),
    do: Arbor.KernelRuntime.provider_gate_child_spec(name, @roots)

  @impl true
  defdelegate start_provider_gate_supervisor(children, supervisor_name, gate_name),
    to: Arbor.KernelRuntime
end
