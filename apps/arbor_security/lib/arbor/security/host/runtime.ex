defmodule Arbor.Security.Host.Runtime do
  @moduledoc "Product boot and provider composition for the passive Security host."

  use Boundary, top_level?: true, deps: [Arbor.Security, Arbor.KernelRuntime], exports: []

  @behaviour Arbor.Security.Contracts.RuntimeHost

  @impl true
  def prepare_startup do
    with {:ok, _started} <- Application.ensure_all_started(:arbor_kernel_runtime),
         {:ok, snapshot} when is_map(snapshot) <- Arbor.KernelRuntime.boot_profile() do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :not_bound}
    end
  end

  @impl true
  def start_profile, do: Arbor.KernelRuntime.start_profile()

  @impl true
  def boot_profile, do: Arbor.KernelRuntime.boot_profile()

  @impl true
  defdelegate provider_gate_child_spec(name, roots), to: Arbor.KernelRuntime

  @impl true
  defdelegate start_provider_gate_supervisor(children, supervisor_name, gate_name),
    to: Arbor.KernelRuntime
end
