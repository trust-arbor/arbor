defmodule Arbor.Trust.PolicyEnforcer do
  @moduledoc """
  Trust-layer JIT capability granting.

  This module is the policy-side pre-authorize step from the A1 authorization
  boundary move. It may mint a session-scoped capability from an explicit trust
  policy decision, then the security kernel authorizes that concrete capability.

  `Arbor.Security.AuthDecision` must not call this module. The dependency only
  points policy -> kernel.
  """

  alias Arbor.Security.CapabilityStore
  alias Arbor.Trust.Config

  require Logger

  @source :trust_policy_enforcer
  @legacy_source :policy_enforcer

  @doc """
  Ensure `principal_id` has a capability for `resource_uri`.

  Existing capabilities are returned unchanged. On a miss, the trust policy may
  mint an explicit capability. `:block` denies; `:ask`, `:allow`, and `:auto`
  mint normal capabilities stamped with policy provenance. Runtime ask-vs-auto
  modulation happens in `Arbor.Trust.ApprovalGuard`, not in the security kernel.
  """
  @spec ensure_capability(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def ensure_capability(principal_id, resource_uri, opts \\ []) do
    resource_uri = Arbor.Security.authorization_resource_uri(resource_uri, opts)

    case find_existing_capability(principal_id, resource_uri) do
      {:ok, cap} -> {:ok, cap}
      {:error, :not_found} -> check(principal_id, resource_uri, opts)
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  @doc """
  Check trust profile and optionally mint a session-scoped capability.
  """
  @spec check(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def check(principal_id, resource_uri, opts \\ []) do
    if enabled?() do
      case get_effective_mode(principal_id, resource_uri, opts) do
        mode when mode in [:auto, :allow] ->
          auto_grant(principal_id, resource_uri, opts, %{}, mode)

        :ask ->
          auto_grant(principal_id, resource_uri, opts, %{}, :ask)

        :block ->
          {:error, :unauthorized}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Audit and re-sync trust-minted capabilities after a profile change.
  """
  @spec sync_capabilities(String.t()) :: :ok
  def sync_capabilities(principal_id) do
    if enabled?() do
      do_sync_capabilities(principal_id)
    else
      :ok
    end
  end

  @doc "Whether trust-policy JIT minting is enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: Config.policy_enforcer_enabled?()

  defp find_existing_capability(principal_id, resource_uri) do
    if Code.ensure_loaded?(CapabilityStore) and
         function_exported?(CapabilityStore, :find_authorizing, 2) do
      CapabilityStore.find_authorizing(principal_id, resource_uri)
    else
      {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    :exit, _ -> {:error, :store_unavailable}
  end

  defp do_sync_capabilities(principal_id) do
    with true <- Code.ensure_loaded?(CapabilityStore),
         {:ok, caps} <- CapabilityStore.list_for_principal(principal_id) do
      revoked =
        caps
        |> Enum.filter(&trust_minted?/1)
        |> Enum.count(fn cap ->
          current_mode = get_effective_mode(principal_id, cap.resource_uri, [])
          minted_mode = minted_mode(cap)
          requires_approval? = approval_required?(cap)

          stale? =
            cond do
              current_mode == :block -> true
              minted_mode == :ask -> current_mode != :ask
              minted_mode in [:auto, :allow] -> current_mode not in [:auto, :allow]
              is_nil(minted_mode) and requires_approval? -> current_mode in [:auto, :allow]
              is_nil(minted_mode) and not requires_approval? -> current_mode == :ask
              true -> false
            end

          if stale? do
            Arbor.Security.revoke(cap.id)
            true
          else
            false
          end
        end)

      if revoked > 0 do
        Logger.info(
          "[Trust.PolicyEnforcer] Synced #{revoked} stale capabilities for #{principal_id}",
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
      Logger.warning("[Trust.PolicyEnforcer] sync_capabilities crashed: #{inspect(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  defp auto_grant(principal_id, resource_uri, opts, constraints, mode) do
    grant_opts = [
      principal: principal_id,
      resource: resource_uri,
      constraints: constraints,
      metadata: %{
        source: @source,
        legacy_source: @legacy_source,
        mode: mode,
        granted_by: __MODULE__,
        granted_at: DateTime.utc_now()
      }
    ]

    grant_opts =
      case Keyword.get(opts, :session_id) do
        nil -> grant_opts
        session_id -> Keyword.put(grant_opts, :session_id, session_id)
      end

    case Arbor.Security.grant(grant_opts) do
      {:ok, cap} ->
        Logger.debug(
          "[Trust.PolicyEnforcer] minted #{resource_uri} for #{principal_id}",
          principal_id: principal_id,
          resource_uri: resource_uri,
          mode: mode
        )

        safe_emit_signal(:policy_enforcer_grant, %{
          principal_id: principal_id,
          resource_uri: resource_uri,
          constraints: constraints,
          mode: mode,
          source: @source
        })

        {:ok, cap}

      {:error, reason} ->
        Logger.debug(
          "[Trust.PolicyEnforcer] grant failed for #{resource_uri}: #{inspect(reason)}",
          principal_id: principal_id,
          resource_uri: resource_uri,
          reason: reason
        )

        {:error, :unauthorized}
    end
  rescue
    e ->
      Logger.warning("[Trust.PolicyEnforcer] grant crashed: #{inspect(e)}")
      {:error, :unauthorized}
  end

  defp get_effective_mode(principal_id, resource_uri, opts) do
    policy = Config.policy_module()

    if Code.ensure_loaded?(policy) and function_exported?(policy, :effective_mode, 3) do
      apply(policy, :effective_mode, [principal_id, resource_uri, opts])
    else
      :block
    end
  rescue
    _ -> :block
  catch
    :exit, _ -> :block
  end

  defp trust_minted?(cap) do
    metadata = cap.metadata || %{}
    source = Map.get(metadata, :source) || Map.get(metadata, "source")
    legacy = Map.get(metadata, :legacy_source) || Map.get(metadata, "legacy_source")

    source in [@source, Atom.to_string(@source), @legacy_source, Atom.to_string(@legacy_source)] or
      legacy in [@legacy_source, Atom.to_string(@legacy_source)]
  end

  defp minted_mode(cap) do
    metadata = cap.metadata || %{}
    Map.get(metadata, :mode) || Map.get(metadata, "mode")
  end

  defp approval_required?(cap) do
    cap.constraints[:requires_approval] == true or
      cap.constraints["requires_approval"] == true
  end

  defp safe_emit_signal(type, data) do
    Arbor.Signals.emit(:security, type, data)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
