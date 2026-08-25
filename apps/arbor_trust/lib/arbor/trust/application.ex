defmodule Arbor.Trust.Application do
  @moduledoc false

  use Application

  alias Arbor.Trust.ProviderGate

  @provider_gate Arbor.Trust.ProviderGate
  @supervisor Arbor.Trust.ApplicationSupervisor

  @impl true
  def start(_type, _args) do
    with {:ok, profile} <- closed_start_profile() do
      start_profile(profile, start_children())
    end
  end

  @doc false
  @spec closed_start_profile() :: {:ok, :full | :activation_only} | {:error, term()}
  def closed_start_profile do
    case Arbor.KernelRuntime.Config.start_profile() do
      :full -> {:ok, :full}
      :activation_only -> {:ok, :activation_only}
      other -> {:error, {:invalid_start_profile, other}}
    end
  rescue
    ArgumentError -> {:error, {:invalid_start_profile, :malformed_namespace}}
  end

  defp start_children do
    Application.get_env(:arbor_trust, :start_children, true)
  end

  # PolicyHost is mandatory reference-monitor infrastructure. start_children
  # may suppress Arbor.Trust.Supervisor (Store/Manager/etc.) but not the host.
  # The provider gate is omitted when those consumers are suppressed.
  defp start_profile(:activation_only, _start_children) do
    Supervisor.start_link([policy_host_child(:activation_only)],
      strategy: :rest_for_one,
      name: @supervisor
    )
  end

  defp start_profile(:full, true) do
    start_named([
      policy_host_child(:full),
      ProviderGate.child_spec([]),
      {Arbor.Trust.Supervisor, []}
    ])
  end

  defp start_profile(:full, _start_children) do
    Supervisor.start_link([policy_host_child(:full)],
      strategy: :rest_for_one,
      name: @supervisor
    )
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

  defp policy_host_child(profile) do
    {Arbor.Trust.PolicyHost, [start_profile: profile]}
  end
end
