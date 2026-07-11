defmodule Arbor.Orchestrator.Authorization do
  @moduledoc """
  Centralized, fail-closed authorization gate for orchestrator execution.

  Provides the once-per-turn `arbor://orchestrator/execute` check used by
  Session (user turns) and HeartbeatService. Bridges at runtime to
  `Arbor.Security.authorize/4` when the security subsystem is present.

  ## Policy (see Arbor.Orchestrator.Config)
  - `security_required?: true` (default) → any unavailable or error during
    check → `{:error, :security_unavailable}` (fail-closed, no execution).
  - `security_required?: false` → only for intentional standalone use without
    arbor_security; permits when subsystem missing.

  ## No fail-open on errors
  Unlike previous duplicated implementations, there is no broad `rescue _ -> :ok`.
  Exceptions or exits during the authorize call (e.g. CapabilityStore down
  mid-check) are logged and result in denial when required.

  ## Credentials
  Accepts either:
  - a legacy 1-arity signer function that produces a fresh SignedRequest, or
  - a `%Arbor.Contracts.Security.SigningAuthority{}` for the reload-stable path

  The SigningAuthority path always signs via `Arbor.Security.sign_with_authority/2`
  and authorizes via the fixed `Arbor.Security.authorize/4` facade. It never
  consults `Config.security_available?/0`, `security_required?/0`, or
  `security_module/0`. Unavailable Security, raises, exits, and signing or
  authorization errors fail closed — never fall back to unsigned/legacy
  credentials. The legacy signer path retains Config availability policy.

  ## Usage
      case Authorization.check_orchestrator_access(agent_id, signer) do
        :ok -> proceed()
        {:error, reason} -> {:error, {:unauthorized, reason}}
      end
  """

  require Logger

  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Orchestrator.Config

  @orchestrator_resource "arbor://orchestrator/execute"

  @doc "The canonical resource URI for the orchestrator execution gate."
  @spec orchestrator_resource() :: String.t()
  def orchestrator_resource, do: @orchestrator_resource

  @doc """
  Check whether `agent_id` may execute orchestrator turns or heartbeats.

  Returns `:ok` on success or `{:error, reason}` on denial.
  """
  @spec check_orchestrator_access(
          String.t(),
          (String.t() -> {:ok, term()} | {:error, term()}) | SigningAuthority.t() | nil
        ) ::
          :ok | {:error, term()}
  def check_orchestrator_access(agent_id, credential \\ nil)

  def check_orchestrator_access(agent_id, %SigningAuthority{} = authority)
      when is_binary(agent_id) do
    # Authority path: fixed Arbor.Security only. Never consult Config
    # availability / required / security_module seams — always fail closed.
    if authority.principal_id != agent_id do
      {:error, :principal_mismatch}
    else
      authorize_with_authority(agent_id, authority)
    end
  rescue
    error ->
      Logger.warning(
        "[Authorization] Orchestrator gate check raised (failing closed): #{inspect(error)}",
        agent_id: agent_id
      )

      {:error, :security_unavailable}
  catch
    :exit, reason ->
      Logger.warning(
        "[Authorization] Orchestrator gate check exited (failing closed): #{inspect(reason)}",
        agent_id: agent_id
      )

      {:error, :security_unavailable}
  end

  def check_orchestrator_access(agent_id, signer) when is_binary(agent_id) do
    if Config.security_available?() do
      auth_opts = build_auth_opts(signer)

      case Arbor.Security.authorize(
             agent_id,
             @orchestrator_resource,
             :execute,
             auth_opts
           ) do
        {:ok, :authorized} -> :ok
        {:ok, :pending_approval, proposal_id} -> {:error, {:pending_approval, proposal_id}}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_auth_result, other}}
      end
    else
      if Config.security_required?() do
        {:error, :security_unavailable}
      else
        :ok
      end
    end
  rescue
    error ->
      Logger.warning(
        "[Authorization] Orchestrator gate check raised (failing closed): #{inspect(error)}",
        agent_id: agent_id
      )

      if Config.security_required?(), do: {:error, :security_unavailable}, else: :ok
  catch
    :exit, reason ->
      Logger.warning(
        "[Authorization] Orchestrator gate check exited (failing closed): #{inspect(reason)}",
        agent_id: agent_id
      )

      if Config.security_required?(), do: {:error, :security_unavailable}, else: :ok
  end

  # Fixed Security facade path — never consults Config.security_module /
  # security_available? / security_required?.
  defp authorize_with_authority(agent_id, %SigningAuthority{} = authority) do
    if security_facade_available?() do
      case Arbor.Security.sign_with_authority(authority, @orchestrator_resource) do
        {:ok, signed_request} ->
          case Arbor.Security.authorize(
                 agent_id,
                 @orchestrator_resource,
                 :execute,
                 signed_request: signed_request
               ) do
            {:ok, :authorized} -> :ok
            {:ok, :pending_approval, proposal_id} -> {:error, {:pending_approval, proposal_id}}
            {:error, reason} -> {:error, reason}
            other -> {:error, {:unexpected_auth_result, other}}
          end

        {:error, reason} ->
          # Fail closed — never fall back to unsigned or legacy credentials.
          {:error, {:authority_signing_failed, reason}}
      end
    else
      {:error, :security_unavailable}
    end
  end

  defp security_facade_available? do
    Code.ensure_loaded?(Arbor.Security) and
      function_exported?(Arbor.Security, :sign_with_authority, 2) and
      function_exported?(Arbor.Security, :authorize, 4)
  end

  defp build_auth_opts(nil), do: []

  defp build_auth_opts(signer) when is_function(signer, 1) do
    # Legacy compatibility: missing/failed signer opts remain empty so
    # pre-authority callers keep their prior authorize behavior.
    case signer.(@orchestrator_resource) do
      {:ok, signed_request} -> [signed_request: signed_request]
      {:error, _} -> []
      _ -> []
    end
  end

  defp build_auth_opts(_other), do: []
end
