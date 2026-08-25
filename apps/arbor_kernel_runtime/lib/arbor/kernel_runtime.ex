defmodule Arbor.KernelRuntime do
  @moduledoc """
  Boundary owner for the active kernel runtime application.

  Runtime services remain in their stable public namespaces. This root owns
  only the application callback namespace and declares the service
  boundaries it composes plus the contracts it consumes. The public
  safe-management surface is `Arbor.KernelRuntime.SafeManagementSurface`.
  The VM-lifetime boot-profile snapshot is `boot_profile/0`.
  Bound Platform activation verification is `authorize_platform_activation/3`.
  """

  use Boundary,
    top_level?: true,
    deps: [Arbor.Common, Arbor.Contracts, Arbor.Signals, Arbor.Monitor, Logger],
    exports: [SafeManagementSurface]

  alias Arbor.Common.Extension.Activation
  alias Arbor.KernelRuntime.BootProfileBinding

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
end
