defmodule Arbor.Security.CapabilityStore do
  @moduledoc """
  In-memory storage for capabilities.

  Stores capabilities indexed by ID and by principal for fast lookup.
  Handles expiration cleanup automatically.
  """

  use GenServer

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.Config
  alias Arbor.Security.SystemAuthority

  @cleanup_interval_ms 60_000

  # Client API

  @doc """
  Start the capability store.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Store a capability.

  Returns `{:ok, :stored}` on success, or `{:error, reason}` if quota is exceeded:
  - `{:error, {:quota_exceeded, :per_agent_capability_limit, context}}`
  - `{:error, {:quota_exceeded, :global_capability_limit, context}}`
  - `{:error, {:quota_exceeded, :delegation_depth_limit, context}}`
  """
  @spec put(Capability.t()) :: {:ok, :stored} | {:error, term()}
  def put(%Capability{} = cap) do
    GenServer.call(__MODULE__, {:put, cap})
  end

  @doc """
  Get a capability by ID.
  """
  @spec get(String.t()) :: {:ok, Capability.t()} | {:error, :not_found}
  def get(capability_id) do
    GenServer.call(__MODULE__, {:get, capability_id})
  end

  @doc """
  List capabilities for a principal.
  """
  @spec list_for_principal(String.t(), keyword()) :: {:ok, [Capability.t()]}
  def list_for_principal(principal_id, opts \\ []) do
    GenServer.call(__MODULE__, {:list_for_principal, principal_id, opts})
  end

  @doc """
  Find a capability that authorizes access to the given resource.

  The action is encoded in the resource URI: `arbor://{type}/{action}/{path}`
  """
  @spec find_authorizing(String.t(), String.t()) ::
          {:ok, Capability.t()} | {:error, :not_found}
  def find_authorizing(principal_id, resource_uri) do
    GenServer.call(__MODULE__, {:find_authorizing, principal_id, resource_uri})
  end

  @doc """
  Revoke a capability by ID.
  """
  @spec revoke(String.t()) :: :ok | {:error, :not_found}
  def revoke(capability_id) do
    GenServer.call(__MODULE__, {:revoke, capability_id})
  end

  @doc """
  Revoke all capabilities for a principal.
  """
  @spec revoke_all(String.t()) :: {:ok, non_neg_integer()}
  def revoke_all(principal_id) do
    GenServer.call(__MODULE__, {:revoke_all, principal_id})
  end

  @doc """
  Cascade revoke a capability and all its delegated children.

  Revokes the specified capability and recursively revokes all capabilities
  that were delegated from it (directly or transitively).

  Returns `{:ok, count}` where count is the total number of capabilities revoked.
  """
  @spec cascade_revoke(String.t()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def cascade_revoke(capability_id) do
    GenServer.call(__MODULE__, {:cascade_revoke, capability_id})
  end

  @doc """
  Get store statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    schedule_cleanup()

    {:ok,
     %{
       by_id: %{},
       by_principal: %{},
       by_issuer: %{},
       by_parent: %{},
       stats: %{
         total_granted: 0,
         total_revoked: 0,
         total_expired: 0,
         total_cascade_revoked: 0
       }
     }}
  end

  @impl true
  def handle_call({:put, cap}, _from, state) do
    case check_quotas(state, cap) do
      :ok ->
        state =
          state
          |> put_in([:by_id, cap.id], cap)
          |> update_in([:by_principal, cap.principal_id], fn
            nil -> [cap.id]
            ids -> [cap.id | ids]
          end)
          |> index_by_issuer(cap)
          |> index_by_parent(cap)
          |> update_in([:stats, :total_granted], &(&1 + 1))

        {:reply, {:ok, :stored}, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get, capability_id}, _from, state) do
    result =
      case Map.get(state.by_id, capability_id) do
        nil -> {:error, :not_found}
        cap -> check_expiration(cap)
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:list_for_principal, principal_id, opts}, _from, state) do
    include_expired = Keyword.get(opts, :include_expired, false)

    cap_ids = Map.get(state.by_principal, principal_id, [])

    caps =
      cap_ids
      |> Enum.map(&Map.get(state.by_id, &1))
      |> Enum.reject(&is_nil/1)
      |> maybe_filter_expired(include_expired)

    {:reply, {:ok, caps}, state}
  end

  @impl true
  def handle_call({:find_authorizing, principal_id, resource_uri}, _from, state) do
    cap_ids = Map.get(state.by_principal, principal_id, [])

    result =
      cap_ids
      |> Enum.map(&Map.get(state.by_id, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.find(fn cap ->
        not expired?(cap) and authorizes_resource?(cap, resource_uri) and
          signature_acceptable?(cap)
      end)
      |> case do
        nil -> {:error, :not_found}
        cap -> {:ok, cap}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:revoke, capability_id}, _from, state) do
    case Map.get(state.by_id, capability_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      cap ->
        state =
          state
          |> update_in([:by_id], &Map.delete(&1, capability_id))
          |> update_in([:by_principal, cap.principal_id], fn ids ->
            List.delete(ids || [], capability_id)
          end)
          |> update_in([:stats, :total_revoked], &(&1 + 1))

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:revoke_all, principal_id}, _from, state) do
    cap_ids = Map.get(state.by_principal, principal_id, [])
    count = length(cap_ids)

    state =
      state
      |> update_in([:by_id], fn by_id ->
        Enum.reduce(cap_ids, by_id, &Map.delete(&2, &1))
      end)
      |> put_in([:by_principal, principal_id], [])
      |> update_in([:stats, :total_revoked], &(&1 + count))

    {:reply, {:ok, count}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        active_capabilities: map_size(state.by_id),
        principals_with_capabilities: map_size(state.by_principal),
        quota_max_per_agent: Config.max_capabilities_per_agent(),
        quota_max_global: Config.max_global_capabilities(),
        quota_max_delegation_depth: Config.max_delegation_depth(),
        quota_enforcement_enabled: Config.quota_enforcement_enabled?()
      })

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:cascade_revoke, capability_id}, _from, state) do
    case Map.get(state.by_id, capability_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _cap ->
        # Collect all capability IDs to revoke (this one + all children recursively)
        all_ids = collect_cascade_ids(state, [capability_id], [])
        count = length(all_ids)

        state =
          state
          |> revoke_capability_ids(all_ids)
          |> update_in([:stats, :total_revoked], &(&1 + count))
          |> update_in([:stats, :total_cascade_revoked], &(&1 + count))

        {:reply, {:ok, count}, state}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    state = cleanup_expired(state)
    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp check_expiration(cap) do
    if expired?(cap) do
      {:error, :capability_expired}
    else
      {:ok, cap}
    end
  end

  defp expired?(%{expires_at: nil}), do: false

  defp expired?(%{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  defp maybe_filter_expired(caps, true), do: caps
  defp maybe_filter_expired(caps, false), do: Enum.reject(caps, &expired?/1)

  defp index_by_issuer(state, %{issuer_id: nil}), do: state

  defp index_by_issuer(state, cap) do
    update_in(state, [:by_issuer, cap.issuer_id], fn
      nil -> [cap.id]
      ids -> [cap.id | ids]
    end)
  end

  defp index_by_parent(state, %{parent_capability_id: nil}), do: state

  defp index_by_parent(state, cap) do
    update_in(state, [:by_parent, cap.parent_capability_id], fn
      nil -> [cap.id]
      ids -> [cap.id | ids]
    end)
  end

  defp signature_acceptable?(cap) do
    cond do
      # Signature present — verify it
      Capability.signed?(cap) ->
        case SystemAuthority.verify_capability_signature(cap) do
          :ok -> true
          {:error, _} -> false
        end

      # No signature, but signing is required — reject
      Config.capability_signing_required?() ->
        false

      # No signature, signing not required — backward compat accept
      true ->
        true
    end
  end

  defp authorizes_resource?(cap, resource_uri) do
    # Check if capability's resource pattern matches the requested resource
    # The action is encoded in the URI: arbor://{type}/{action}/{path}
    # Matching is done via prefix: capability for "arbor://fs/read/project"
    # authorizes access to "arbor://fs/read/project/src/file.ex"
    String.starts_with?(resource_uri, cap.resource_uri) or
      cap.resource_uri == resource_uri
  end

  defp cleanup_expired(state) do
    now = DateTime.utc_now()

    {expired_entries, _} =
      Enum.split_with(state.by_id, fn {_id, cap} ->
        cap.expires_at != nil and DateTime.compare(now, cap.expires_at) == :gt
      end)

    expired_ids = Enum.map(expired_entries, fn {id, _} -> id end)

    if expired_ids == [] do
      state
    else
      state
      |> remove_expired_capabilities(expired_ids)
      |> remove_expired_from_principals(expired_ids)
      |> update_in([:stats, :total_expired], &(&1 + length(expired_ids)))
    end
  end

  defp remove_expired_capabilities(state, expired_ids) do
    update_in(state, [:by_id], fn by_id ->
      Enum.reduce(expired_ids, by_id, &Map.delete(&2, &1))
    end)
  end

  defp remove_expired_from_principals(state, expired_ids) do
    update_in(state, [:by_principal], fn by_principal ->
      Map.new(by_principal, &remove_expired_from_principal(&1, expired_ids))
    end)
  end

  defp remove_expired_from_principal({principal, ids}, expired_ids) do
    {principal, ids -- expired_ids}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  # ===========================================================================
  # Cascade Revocation Helpers
  # ===========================================================================

  # Recursively collect all capability IDs that should be revoked
  # (the root + all children in the delegation tree)
  defp collect_cascade_ids(_state, [], acc), do: acc

  defp collect_cascade_ids(state, [cap_id | rest], acc) do
    children = Map.get(state.by_parent, cap_id, [])
    collect_cascade_ids(state, children ++ rest, [cap_id | acc])
  end

  # Revoke multiple capability IDs, cleaning up all indexes
  defp revoke_capability_ids(state, cap_ids) do
    Enum.reduce(cap_ids, state, &revoke_single_capability_if_exists/2)
  end

  defp revoke_single_capability_if_exists(cap_id, state) do
    case Map.get(state.by_id, cap_id) do
      nil -> state
      cap -> remove_capability_from_indexes(state, cap_id, cap)
    end
  end

  defp remove_capability_from_indexes(state, cap_id, cap) do
    state
    |> update_in([:by_id], &Map.delete(&1, cap_id))
    |> update_in([:by_principal, cap.principal_id], &List.delete(&1 || [], cap_id))
    |> deindex_by_parent(cap)
  end

  # Remove a capability from its parent's children list
  defp deindex_by_parent(state, %{parent_capability_id: nil}), do: state

  defp deindex_by_parent(state, cap) do
    update_in(state, [:by_parent, cap.parent_capability_id], fn
      nil -> nil
      ids -> List.delete(ids, cap.id)
    end)
  end

  # ===========================================================================
  # Quota Enforcement (Phase 7)
  # ===========================================================================

  defp check_quotas(state, cap) do
    if Config.quota_enforcement_enabled?() do
      with :ok <- check_delegation_depth(cap),
           :ok <- check_per_agent_limit(state, cap) do
        check_global_limit(state)
      end
    else
      :ok
    end
  end

  defp check_delegation_depth(cap) do
    max_depth = Config.max_delegation_depth()
    depth = Map.get(cap, :delegation_depth, 0)

    cond do
      depth < 0 ->
        {:error,
         {:quota_exceeded, :delegation_depth_limit,
          %{depth: depth, limit: max_depth, reason: :negative_depth}}}

      depth > max_depth ->
        {:error,
         {:quota_exceeded, :delegation_depth_limit, %{depth: depth, limit: max_depth}}}

      true ->
        :ok
    end
  end

  defp check_per_agent_limit(state, cap) do
    max_per_agent = Config.max_capabilities_per_agent()
    agent_cap_ids = Map.get(state.by_principal, cap.principal_id, [])
    current_count = length(agent_cap_ids)

    if current_count >= max_per_agent do
      {:error,
       {:quota_exceeded, :per_agent_capability_limit,
        %{agent_id: cap.principal_id, current: current_count, limit: max_per_agent}}}
    else
      :ok
    end
  end

  defp check_global_limit(state) do
    max_global = Config.max_global_capabilities()
    current_count = map_size(state.by_id)

    if current_count >= max_global do
      {:error,
       {:quota_exceeded, :global_capability_limit,
        %{current: current_count, limit: max_global}}}
    else
      :ok
    end
  end
end
