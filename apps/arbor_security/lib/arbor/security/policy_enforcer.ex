defmodule Arbor.Security.PolicyEnforcer do
  @moduledoc """
  JIT capability granting via trust profile bridge.

  When `Security.authorize/4` can't find an existing capability for a
  principal+resource pair, PolicyEnforcer checks the trust profile to
  determine if a session-scoped capability should be auto-granted.

  ## Decision Modes

  - `:auto` / `:allow` — auto-grant a session-scoped capability
  - `:ask` — grant with `requires_approval: true` constraint (ApprovalGuard handles)
  - `:block` — deny (`{:error, :unauthorized}`)

  ## Performance

  First call per URI per session hits the Trust bridge (~1ms).
  Subsequent calls hit CapabilityStore directly (cached capability).

  ## Configuration

      config :arbor_security,
        policy_enforcer_enabled: true  # default: true
  """

  require Logger

  @doc """
  Check trust profile and optionally auto-grant a session-scoped capability.

  Called by `find_capability/3` when CapabilityStore has no matching capability.
  Returns `{:ok, cap}` on successful grant or `{:error, :unauthorized}` on denial.
  """
  @spec check(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def check(principal_id, resource_uri, opts \\ []) do
    if not enabled?() or not trust_policy_available?() do
      {:error, :unauthorized}
    else
      case get_effective_mode(principal_id, resource_uri) do
        mode when mode in [:auto, :allow] ->
          auto_grant(principal_id, resource_uri, opts, %{})

        :ask ->
          auto_grant(principal_id, resource_uri, opts, %{requires_approval: true})

        :block ->
          {:error, :unauthorized}
      end
    end
  end

  @doc """
  Audit and re-sync capabilities for an agent after a trust profile change.

  Revokes capabilities whose constraints no longer match the current trust
  profile mode. For example, if a capability has `requires_approval: true`
  but the profile now says `:auto` for that URI, the stale capability is
  revoked so PolicyEnforcer re-grants a clean one on next access.
  """
  @spec sync_capabilities(String.t()) :: :ok
  def sync_capabilities(principal_id) do
    if not enabled?() or not trust_policy_available?() do
      :ok
    else
      do_sync_capabilities(principal_id)
    end
  end

  defp do_sync_capabilities(principal_id) do
    cap_store = Module.concat([:Arbor, :Security, :CapabilityStore])
    security_mod = Module.concat([:Arbor, :Security])

    with true <- Code.ensure_loaded?(cap_store),
         {:ok, caps} <- apply(cap_store, :list_for_principal, [principal_id]) do
      # Only audit PolicyEnforcer-granted caps (source: :policy_enforcer)
      pe_caps =
        Enum.filter(caps, fn c ->
          Map.get(c.metadata || %{}, :source) == :policy_enforcer or
            Map.get(c.metadata || %{}, "source") == "policy_enforcer"
        end)

      revoked =
        Enum.count(pe_caps, fn cap ->
          current_mode = get_effective_mode(principal_id, cap.resource_uri)
          has_approval = cap.constraints[:requires_approval] == true

          stale? =
            cond do
              # Was :ask (requires_approval), now :auto/:allow → stale
              has_approval and current_mode in [:auto, :allow] -> true
              # Was :auto (no requires_approval), now :block → stale
              not has_approval and current_mode == :block -> true
              # Was :auto, now :ask → stale (needs requires_approval added)
              not has_approval and current_mode == :ask -> true
              true -> false
            end

          if stale? do
            apply(security_mod, :revoke, [cap.id])
            true
          else
            false
          end
        end)

      if revoked > 0 do
        Logger.info(
          "[PolicyEnforcer] Synced #{revoked} stale capabilities for #{principal_id}",
          principal_id: principal_id,
          revoked: revoked
        )
      end

      :ok
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("[PolicyEnforcer] sync_capabilities crashed: #{inspect(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Whether the PolicyEnforcer is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    Arbor.Security.Config.policy_enforcer_enabled?()
  end

  # ===========================================================================
  # Internals
  # ===========================================================================

  defp auto_grant(principal_id, resource_uri, opts, constraints) do
    security_mod = Module.concat([:Arbor, :Security])

    grant_opts = [
      principal: principal_id,
      resource: resource_uri,
      constraints: constraints,
      metadata: %{source: :policy_enforcer}
    ]

    # Session-scope the capability if session_id is available
    grant_opts =
      case Keyword.get(opts, :session_id) do
        nil -> grant_opts
        sid -> Keyword.put(grant_opts, :session_id, sid)
      end

    case apply(security_mod, :grant, [grant_opts]) do
      {:ok, cap} ->
        Logger.debug(
          "PolicyEnforcer: auto-granted #{resource_uri} for #{principal_id}",
          principal_id: principal_id,
          resource_uri: resource_uri,
          mode: if(constraints[:requires_approval], do: :ask, else: :auto)
        )

        safe_emit_signal(:policy_enforcer_grant, %{
          principal_id: principal_id,
          resource_uri: resource_uri,
          constraints: constraints
        })

        {:ok, cap}

      {:error, reason} ->
        Logger.debug(
          "PolicyEnforcer: grant failed for #{resource_uri}: #{inspect(reason)}",
          principal_id: principal_id,
          resource_uri: resource_uri,
          reason: reason
        )

        {:error, :unauthorized}
    end
  rescue
    e ->
      Logger.warning("PolicyEnforcer: grant crashed: #{inspect(e)}")
      {:error, :unauthorized}
  end

  defp get_effective_mode(principal_id, resource_uri) do
    if Code.ensure_loaded?(Arbor.Trust.Policy) and
         function_exported?(Arbor.Trust.Policy, :effective_mode, 3) do
      apply(Arbor.Trust.Policy, :effective_mode, [principal_id, resource_uri, []])
    else
      :block
    end
  rescue
    _ -> :block
  catch
    :exit, _ -> :block
  end

  defp trust_policy_available? do
    Code.ensure_loaded?(Arbor.Trust.Policy) and
      function_exported?(Arbor.Trust.Policy, :effective_mode, 3)
  end

  defp safe_emit_signal(type, data) do
    if Code.ensure_loaded?(Arbor.Signals) and
         function_exported?(Arbor.Signals, :emit, 3) do
      Arbor.Signals.emit(:security, type, data)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
