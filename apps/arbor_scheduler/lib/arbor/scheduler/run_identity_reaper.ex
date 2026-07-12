defmodule Arbor.Scheduler.RunIdentityReaper do
  @moduledoc false

  require Logger

  alias Arbor.Scheduler.RunIdentity
  alias Arbor.Security
  alias Arbor.Trust

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      restart: :temporary
    }
  end

  # Reconciliation is synchronous so Oban cannot start a new run until residue
  # from an earlier scheduler/application lifetime has been removed.
  def start_link(_opts) do
    reconcile()
    :ignore
  end

  def reconcile do
    case Security.lookup_identity_ids_by_display_name(RunIdentity.identity_name()) do
      {:ok, agent_ids} -> Enum.each(agent_ids, &reap/1)
      {:error, :not_found} -> :ok
      {:error, reason} -> Logger.warning("[RunIdentityReaper] lookup failed: #{inspect(reason)}")
    end
  end

  defp reap(agent_id) do
    case Security.list_capabilities(agent_id) do
      {:ok, caps} ->
        Enum.each(caps, &safe_revoke(&1.id))

      {:error, reason} ->
        Logger.warning("[RunIdentityReaper] cap lookup failed: #{inspect(reason)}")
    end

    _ = Trust.delete_trust_profile(agent_id)
    _ = Security.deregister_identity(agent_id)
    :ok
  rescue
    exception ->
      Logger.warning(
        "[RunIdentityReaper] failed to reap #{agent_id}: #{Exception.message(exception)}"
      )
  catch
    :exit, reason ->
      Logger.warning("[RunIdentityReaper] exited while reaping #{agent_id}: #{inspect(reason)}")
  end

  defp safe_revoke(cap_id) do
    case Security.revoke(cap_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> Logger.warning("[RunIdentityReaper] revoke failed: #{inspect(reason)}")
    end
  end
end
