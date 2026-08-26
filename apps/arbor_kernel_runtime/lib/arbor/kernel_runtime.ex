defmodule Arbor.KernelRuntime do
  @moduledoc """
  Boundary owner for the active kernel runtime application.

  Runtime services remain in their stable public namespaces. This root owns
  the application callback namespace and the shared provider-gate lifecycle
  facade, `provider_gate_child_spec/2` and `start_provider_gate_supervisor/3`.
  It also declares the service boundaries it composes plus the contracts it
  consumes. The public safe-management surface is
  `Arbor.KernelRuntime.SafeManagementSurface`.
  The VM-lifetime boot-profile snapshot is `boot_profile/0`.
  Bound Platform activation verification is `authorize_platform_activation/3`.
  """

  use Boundary,
    top_level?: true,
    deps: [Arbor.Common, Arbor.Contracts, Arbor.Signals, Arbor.Monitor, Logger],
    exports: [SafeManagementSurface]

  alias Arbor.Common.Extension.Activation
  alias Arbor.KernelRuntime.BootProfileBinding
  alias Arbor.KernelRuntime.ProviderGate

  @doc """
  Builds a permanent provider-gate child specification.

  `name` is preserved as both the registered process name and supervisor
  child id. `roots` is a closed, ordered application list owned by the
  calling application's ProviderGate declaration module.
  """
  @spec provider_gate_child_spec(atom(), [atom()]) :: Supervisor.child_spec()
  def provider_gate_child_spec(name, roots)
      when is_atom(name) and is_list(roots) and roots != [] do
    unless Enum.all?(roots, &is_atom/1) do
      raise ArgumentError, "provider roots must be atoms"
    end

    %{
      id: name,
      start: {ProviderGate, :start_link, [[name: name, roots: roots]]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Starts a named `:rest_for_one` supervisor and preserves provider-gate errors.

  Only failures belonging to `gate_name` are normalized. Unrelated child and
  supervisor failures retain their OTP-produced shape.
  """
  @spec start_provider_gate_supervisor(
          [Supervisor.child_spec() | {module(), term()}],
          atom(),
          atom()
        ) :: Supervisor.on_start()
  def start_provider_gate_supervisor(children, supervisor_name, gate_name)
      when is_list(children) and is_atom(supervisor_name) and is_atom(gate_name) do
    case Supervisor.start_link(children, strategy: :rest_for_one, name: supervisor_name) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, normalize_gate_start_error(reason, gate_name)}
    end
  end

  @doc """
  Returns the immutable VM-lifetime boot-profile snapshot.

  The map is closed plain data. It does not include process tokens,
  verifier input, private keys, or internal slot state. This read does
  not invoke Envelope; each fetch validates the bounded table and
  snapshot. Publication waits for a synchronous successful-init
  handshake, then admits the table. Returns `{:error, :not_bound}` when
  the handshake is missing, dead, or timed out, or bounded admission
  fails.
  """
  @spec boot_profile() :: {:ok, map()} | {:error, :not_bound}
  def boot_profile, do: BootProfileBinding.snapshot()

  @doc """
  Authorize a staged activation transaction with a Platform-bound envelope.

  Boot digest, epoch, issuer, key, and Platform public key are taken only
  from `boot_profile/0`. Caller-supplied replacements are rejected.
  Production commit stays disabled.
  """
  @spec authorize_platform_activation(map(), term(), keyword()) ::
          {:ok, map(), [term()]} | {:error, String.t()}
  def authorize_platform_activation(state, document, opts \\ [])

  def authorize_platform_activation(state, document, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case boot_profile() do
        {:ok, snapshot} -> Activation.authorize_bound(state, document, snapshot, opts)
        {:error, :not_bound} -> {:error, "not_ready"}
        {:error, _reason} -> {:error, "not_ready"}
      end
    else
      {:error, "malformed"}
    end
  end

  def authorize_platform_activation(_state, _document, _opts), do: {:error, "malformed"}

  defp normalize_gate_start_error(reason, gate_name) do
    case gate_child_reason(reason, gate_name) do
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

  defp gate_child_reason({:shutdown, inner}, gate_name),
    do: gate_child_reason(inner, gate_name)

  defp gate_child_reason({:failed_to_start_child, id, inner}, gate_name)
       when id == gate_name,
       do: inner

  # OTP 28 Supervisor.start_link wraps as {reason, #child{}}.
  # Id is elem 2 and MFA is elem 3 on OTP 24 (size 8) and OTP 25+ (size 9).
  defp gate_child_reason({inner, child}, gate_name)
       when is_tuple(child) and tuple_size(child) >= 4 and elem(child, 0) == :child do
    if provider_gate_child_record?(child, gate_name), do: inner, else: :not_gate
  end

  defp gate_child_reason({inner, {ProviderGate, :start_link, [opts]}}, gate_name)
       when is_list(opts) do
    if Keyword.get(opts, :name) == gate_name, do: inner, else: :not_gate
  end

  defp gate_child_reason(_reason, _gate_name), do: :not_gate

  defp provider_gate_child_record?(child, gate_name)
       when is_tuple(child) and tuple_size(child) >= 4 and elem(child, 0) == :child do
    id = elem(child, 2)
    mfargs = elem(child, 3)

    id == gate_name or provider_gate_mfa?(mfargs, gate_name)
  end

  defp provider_gate_child_record?(_child, _gate_name), do: false

  defp provider_gate_mfa?({ProviderGate, :start_link, [opts]}, gate_name)
       when is_list(opts) do
    Keyword.get(opts, :name) == gate_name
  end

  defp provider_gate_mfa?(_mfargs, _gate_name), do: false
end
