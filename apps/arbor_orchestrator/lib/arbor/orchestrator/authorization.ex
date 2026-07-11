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

  Any other non-`nil` credential returns `{:error, :invalid_credential}` and
  never enters unsigned or legacy authorization.

  ### SigningAuthority path (fixed facade, always fail-closed)
  Signs via `Arbor.Security.sign_with_authority/2` and authorizes via the fixed
  `Arbor.Security.authorize/4` facade only. It never consults
  `Config.security_available?/0`, `security_required?/0`, or `security_module/0`
  — those seams remain on the legacy signer path only. Unavailable Security,
  raises, exits, and signing or authorization errors always deny; there is no
  fall-back to unsigned credentials and no fail-open via
  `security_required?: false`.

  Struct-tagged partial/forged maps are canonicalized through
  `SigningAuthority.canonicalize/1` before any field access or Security call.

  ### Legacy signer path
  Retains Config availability / required policy for pre-authority callers.

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

  Accepts `nil`, a 1-arity signer function, or a `%SigningAuthority{}`.
  Any other non-`nil` credential returns `{:error, :invalid_credential}` and
  never enters unsigned/legacy authorization. Non-binary principals return
  `{:error, :invalid_execution_principal}` (shaped, not FunctionClauseError).

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
    # Canonicalize first so partial/forged struct-tagged maps never raise or
    # reach the broker GenServer.
    case SigningAuthority.canonicalize(authority) do
      {:ok, authority} ->
        if authority.principal_id != agent_id do
          {:error, :principal_mismatch}
        else
          authorize_with_authority(agent_id, authority)
        end

      {:error, reason} ->
        {:error, {:invalid_signing_authority, reason}}
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

  def check_orchestrator_access(agent_id, nil) when is_binary(agent_id) do
    check_orchestrator_access_legacy(agent_id, nil)
  end

  def check_orchestrator_access(agent_id, signer)
      when is_binary(agent_id) and is_function(signer, 1) do
    check_orchestrator_access_legacy(agent_id, signer)
  end

  def check_orchestrator_access(agent_id, _invalid) when is_binary(agent_id) do
    # Non-nil credentials that are neither SigningAuthority nor function/1
    # must never enter unsigned legacy authorization.
    {:error, :invalid_credential}
  end

  def check_orchestrator_access(_agent_id, _credential) do
    # Non-binary principals get a shaped error, not FunctionClauseError.
    {:error, :invalid_execution_principal}
  end

  defp check_orchestrator_access_legacy(agent_id, signer) do
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
end
