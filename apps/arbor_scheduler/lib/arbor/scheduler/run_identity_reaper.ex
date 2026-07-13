defmodule Arbor.Scheduler.RunIdentityReaper do
  @moduledoc """
  Reconciles scheduler-run identities owned by this local BEAM runtime.

  The default runtime marker is stable across scheduler application restarts
  and distinct from peer nodes, preventing one scheduler from reaping another
  live scheduler's identities. Residue from an obsolete BEAM runtime cannot be
  discovered safely without a durable node-ownership registry; operators that
  need cross-BEAM reconciliation must configure a stable
  `:run_identity_runtime_id` unique to that scheduler node.
  """

  alias Arbor.Scheduler.{RunIdentity, RunLease}
  alias Arbor.Security
  alias Arbor.Trust

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  # Reconciliation is synchronous so Oban cannot start a new run until residue
  # from an earlier scheduler/application lifetime has been removed.
  def start_link(opts) do
    case reconcile(opts) do
      :ok -> :ignore
      {:error, reason} -> {:error, {:run_identity_reconciliation_failed, reason}}
    end
  end

  def reconcile(opts \\ []) do
    security = Keyword.get(opts, :security_facade, Security)
    trust = Keyword.get(opts, :trust_facade, Trust)
    identity_name = Keyword.get(opts, :identity_name, RunIdentity.identity_name())
    active_ids = Keyword.get_lazy(opts, :active_agent_ids, &RunLease.active_agent_ids/0)

    with {:ok, agent_ids} <- lookup_run_identities(security, identity_name) do
      agent_ids
      |> Enum.reject(&MapSet.member?(active_ids, &1))
      |> Enum.reduce_while(:ok, fn agent_id, :ok ->
        case reap(agent_id, security, trust) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {agent_id, reason}}}
        end
      end)
    end
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp lookup_run_identities(security, identity_name) do
    case security.lookup_identity_ids_by_display_name(identity_name) do
      {:ok, agent_ids} when is_list(agent_ids) -> {:ok, agent_ids}
      {:error, :not_found} -> {:ok, []}
      {:error, reason} -> {:error, {:identity_lookup_failed, reason}}
      other -> {:error, {:identity_lookup_failed, {:unexpected_result, other}}}
    end
  end

  defp reap(agent_id, security, trust) do
    with {:ok, caps} <- list_capabilities(security, agent_id),
         :ok <- revoke_capabilities(security, caps),
         :ok <- delete_trust_profile(trust, agent_id),
         :ok <- deregister_identity(security, agent_id) do
      :ok
    end
  end

  defp list_capabilities(security, agent_id) do
    case security.list_capabilities(agent_id) do
      {:ok, caps} when is_list(caps) -> {:ok, caps}
      {:error, reason} -> {:error, {:capability_lookup_failed, reason}}
      other -> {:error, {:capability_lookup_failed, {:unexpected_result, other}}}
    end
  end

  defp revoke_capabilities(security, caps) do
    Enum.reduce_while(caps, :ok, fn cap, :ok ->
      case normalize_delete(security.revoke(cap.id), :capability_revoke_failed) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp delete_trust_profile(trust, agent_id) do
    normalize_delete(trust.delete_trust_profile(agent_id), :trust_profile_delete_failed)
  end

  defp deregister_identity(security, agent_id) do
    normalize_delete(security.deregister_identity(agent_id), :identity_deregister_failed)
  end

  defp normalize_delete(:ok, _tag), do: :ok
  defp normalize_delete({:error, :not_found}, _tag), do: :ok
  defp normalize_delete({:error, reason}, tag), do: {:error, {tag, reason}}
  defp normalize_delete(other, tag), do: {:error, {tag, {:unexpected_result, other}}}
end
