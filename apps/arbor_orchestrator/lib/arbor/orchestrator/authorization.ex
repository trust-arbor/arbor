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

  ## Usage
      case Authorization.check_orchestrator_access(agent_id, signer) do
        :ok -> proceed()
        {:error, reason} -> {:error, {:unauthorized, reason}}
      end

  The signer (if present) is a 1-arity function that produces a fresh
  SignedRequest for the resource (see Builders for construction).
  """

  require Logger

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
          (String.t() -> {:ok, term()} | {:error, term()}) | nil
        ) ::
          :ok | {:error, term()}
  def check_orchestrator_access(agent_id, signer \\ nil) when is_binary(agent_id) do
    if Config.security_available?() do
      auth_opts = build_auth_opts(signer)

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Arbor.Security, :authorize, [
             agent_id,
             @orchestrator_resource,
             :execute,
             auth_opts
           ]) do
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

  defp build_auth_opts(nil), do: []

  defp build_auth_opts(signer) when is_function(signer, 1) do
    case signer.(@orchestrator_resource) do
      {:ok, signed_request} -> [signed_request: signed_request]
      {:error, _} -> []
      _ -> []
    end
  end

  defp build_auth_opts(_other), do: []
end
