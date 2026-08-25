defmodule Arbor.KernelRuntime.Application do
  @moduledoc false

  use Application

  alias Arbor.KernelRuntime.Config
  alias Arbor.KernelRuntime.ProviderGate

  @provider_gate Arbor.KernelRuntime.ProviderGate
  @supervisor Arbor.KernelRuntime.Supervisor

  @owner_child %{
    id: Arbor.KernelRuntime.BootProfileBinding,
    start: {Arbor.KernelRuntime.BootProfileBinding, :start_link, [[]]},
    type: :worker,
    restart: :permanent
  }

  @full_dependents [
    %{
      id: Arbor.Common.Application,
      start: {Arbor.Common.Application, :start, [:normal, []]},
      type: :supervisor
    },
    %{
      id: Arbor.Signals.Application,
      start: {Arbor.Signals.Application, :start, [:normal, []]},
      type: :supervisor
    },
    %{
      id: Arbor.Monitor.Application,
      start: {Arbor.Monitor.Application, :start, [:normal, []]},
      type: :supervisor
    }
  ]

  @impl true
  def start(_type, _args) do
    case admit_profile() do
      {:ok, :activation_only} ->
        Supervisor.start_link([@owner_child], strategy: :rest_for_one, name: @supervisor)

      {:ok, :full} ->
        start_full()

      {:error, _reason} = error ->
        error
    end
  end

  # Config.start_profile/0 raises ArgumentError on a malformed
  # :kernel_runtime namespace. Remap to a binding failure so
  # Application.start fails closed, later rest_for_one children
  # never start, and the VM-lifetime freeze is not replaced.
  defp admit_profile do
    case Config.start_profile() do
      :full -> {:ok, :full}
      :activation_only -> {:ok, :activation_only}
      other -> {:error, {:invalid_start_profile, other}}
    end
  rescue
    ArgumentError -> {:error, {:boot_profile_binding_failed, :malformed_stage_zero}}
  end

  defp start_full do
    start_named([@owner_child, ProviderGate.child_spec([])] ++ @full_dependents)
  end

  defp start_named(children) do
    case Supervisor.start_link(children, strategy: :rest_for_one, name: @supervisor) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, normalize_gate_start_error(reason)}
    end
  end

  defp normalize_gate_start_error(reason) do
    case gate_child_reason(reason) do
      {:already_started, pid} when is_pid(pid) ->
        {:provider_gate_name_collision, pid}

      {:provider_gate_name_collision, pid} = typed when is_pid(pid) ->
        typed

      {:provider_start_failed, root, _inner} = typed when is_atom(root) ->
        typed

      _other ->
        reason
    end
  end

  defp gate_child_reason({:shutdown, inner}), do: gate_child_reason(inner)

  defp gate_child_reason({:failed_to_start_child, id, inner}) when id == @provider_gate,
    do: inner

  # OTP 28 Supervisor.start_link wraps as {reason, #child{}}.
  # Id is elem 2 and MFA is elem 3 on OTP 24 (size 8) and OTP 25+ (size 9).
  defp gate_child_reason({inner, child})
       when is_tuple(child) and tuple_size(child) >= 4 and elem(child, 0) == :child do
    if provider_gate_child_record?(child), do: inner, else: :not_gate
  end

  defp gate_child_reason({inner, {mod, fun, args}})
       when mod == @provider_gate and is_atom(fun) and is_list(args),
       do: inner

  defp gate_child_reason(_), do: :not_gate

  defp provider_gate_child_record?(child)
       when is_tuple(child) and tuple_size(child) >= 4 and elem(child, 0) == :child do
    id = elem(child, 2)
    mfargs = elem(child, 3)
    id == @provider_gate or match?({@provider_gate, :start_link, _}, mfargs)
  end

  defp provider_gate_child_record?(_), do: false
end
