defmodule Arbor.Security.Identity.Registry do
  @moduledoc """
  Registry for agent identities with pluggable persistence.

  Stores public keys indexed by agent ID for fast lookup during signature
  verification. Private keys are never stored — only the public portion
  of an identity is retained.

  Identity entries are persisted via a configurable storage backend
  (implementing `Arbor.Contracts.Persistence.Store`) and restored on startup.

  ## Configuration

      config :arbor_security, :storage_backend, Arbor.Security.Store.JSONFile

  Set to `nil` to disable persistence (in-memory only).
  """

  use GenServer

  require Logger

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Crypto

  # Runtime bridge — arbor_persistence is Level 1 peer, no compile-time dep
  @buffered_store Arbor.Persistence.BufferedStore

  # Client API

  @doc """
  Start the identity registry.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register an identity (public key only).

  The identity's private key is stripped before storage. Rejects registration
  if the agent_id does not match the derived ID from the public key, or if
  the agent_id is already registered.
  """
  @spec register(Identity.t()) :: :ok | {:error, term()}
  def register(%Identity{} = identity) do
    GenServer.call(__MODULE__, {:register, identity})
  end

  @doc """
  Look up the public key for an agent.
  """
  @spec lookup(String.t()) :: {:ok, binary()} | {:error, :not_found}
  def lookup(agent_id) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:lookup, agent_id})
  end

  @doc """
  Look up the encryption public key (X25519) for an agent.

  Returns `{:error, :not_found}` if the agent is not registered, and
  `{:error, :no_encryption_key}` if registered but has no encryption key.
  """
  @spec lookup_encryption_key(String.t()) ::
          {:ok, binary()} | {:error, :not_found | :no_encryption_key}
  def lookup_encryption_key(agent_id) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:lookup_encryption_key, agent_id})
  end

  @doc """
  Check if an agent is registered.
  """
  @spec registered?(String.t()) :: boolean()
  def registered?(agent_id) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:registered?, agent_id})
  end

  @doc """
  Remove a registered identity.
  """
  @spec deregister(String.t()) :: :ok | {:error, :not_found}
  def deregister(agent_id) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:deregister, agent_id})
  end

  @doc """
  Look up agent IDs by human-readable name.

  Names are not unique — returns all agent IDs registered with the given name.
  """
  @spec lookup_by_name(String.t()) :: {:ok, [String.t()]} | {:error, :not_found}
  def lookup_by_name(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:lookup_by_name, name})
  end

  @doc """
  Get registry statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ===========================================================================
  # Identity Lifecycle Management
  # ===========================================================================

  @doc """
  Suspend an identity.

  Sets status to `:suspended`, recording the timestamp and optional reason.
  Suspended identities cannot be looked up (lookup returns error) but
  can be resumed later.

  ## Examples

      :ok = Registry.suspend("agent_001", "Suspicious activity detected")
  """
  @spec suspend(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def suspend(agent_id, reason \\ nil) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:suspend, agent_id, reason})
  end

  @doc """
  Resume a suspended identity.

  Sets status back to `:active`. Only works for `:suspended` identities.
  Returns error if the identity is `:revoked` (terminal state).

  ## Examples

      :ok = Registry.resume("agent_001")
  """
  @spec resume(String.t()) :: :ok | {:error, term()}
  def resume(agent_id) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:resume, agent_id})
  end

  @doc """
  Revoke an identity.

  Sets status to `:revoked` (terminal state). The identity entry remains
  for audit trail but cannot be used. This also triggers capability
  revocation via the CapabilityStore.

  Returns `{:ok, count}` where count is the number of capabilities that
  were revoked as a result of this identity revocation.

  ## Examples

      {:ok, 3} = Registry.revoke_identity("agent_001", "Account compromised")
  """
  @spec revoke_identity(String.t(), String.t() | nil) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def revoke_identity(agent_id, reason \\ nil) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:revoke_identity, agent_id, reason})
  end

  # DEPRECATED: get_status creates a TOCTOU race with separate lookup+status check.
  # Prefer lookup/1 which returns the full identity including status atomically.
  @doc """
  Get the current status of an identity.

  **Deprecated**: This function creates a TOCTOU (time-of-check-time-of-use) race
  condition when used in combination with `lookup/1`. Prefer using `lookup/1` which
  returns the full identity including status atomically.

  ## Examples

      {:ok, :active} = Registry.get_status("agent_001")
      {:ok, :suspended} = Registry.get_status("agent_002")
  """
  @spec get_status(String.t()) :: {:ok, Identity.status()} | {:error, :not_found}
  def get_status(agent_id) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:get_status, agent_id})
  end

  @doc """
  Check if an identity is active.

  Returns `true` only if the identity exists AND has status `:active`.
  Returns `false` for suspended, revoked, or non-existent identities.

  ## Examples

      true = Registry.active?("agent_001")
      false = Registry.active?("suspended_agent")
  """
  @spec active?(String.t()) :: boolean()
  def active?(agent_id) when is_binary(agent_id) do
    case get_status(agent_id) do
      {:ok, :active} -> true
      _ -> false
    end
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    state = %{
      by_agent_id: %{},
      by_public_key_hash: %{},
      by_name: %{},
      stats: %{total_registered: 0, total_deregistered: 0}
    }

    {:ok, restore_from_store(state)}
  end

  @impl true
  def handle_call({:register, %Identity{} = identity}, _from, state) do
    expected_id = Crypto.derive_agent_id(identity.public_key)

    cond do
      # Human identities derive agent_id from OIDC iss:sub, not from public key.
      # The OIDC token verification authenticates the binding; IdentityStore ensures
      # the same iss:sub always loads the same keypair.
      not String.starts_with?(identity.agent_id, "human_") and identity.agent_id != expected_id ->
        {:reply, {:error, {:agent_id_mismatch, identity.agent_id, :expected, expected_id}}, state}

      Map.has_key?(state.by_agent_id, identity.agent_id) ->
        {:reply, {:error, {:already_registered, identity.agent_id}}, state}

      true ->
        pk_hash = Crypto.hash(identity.public_key)

        entry = %{
          public_key: identity.public_key,
          encryption_public_key: identity.encryption_public_key,
          name: identity.name,
          key_version: identity.key_version,
          created_at: identity.created_at,
          metadata: identity.metadata,
          # Lifecycle status (defaults to :active for backward compatibility)
          status: Map.get(identity, :status, :active),
          status_changed_at: Map.get(identity, :status_changed_at),
          status_reason: Map.get(identity, :status_reason)
        }

        state =
          state
          |> put_in([:by_agent_id, identity.agent_id], entry)
          |> put_in([:by_public_key_hash, pk_hash], identity.agent_id)
          |> index_by_name(identity.name, identity.agent_id)
          |> update_in([:stats, :total_registered], &(&1 + 1))

        persist_to_store(identity.agent_id, entry)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:lookup, agent_id}, _from, state) do
    result =
      case Map.get(state.by_agent_id, agent_id) do
        nil -> {:error, :not_found}
        %{status: :suspended} -> {:error, :identity_suspended}
        %{status: :revoked} -> {:error, :identity_revoked}
        %{public_key: pk} -> {:ok, pk}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:lookup_encryption_key, agent_id}, _from, state) do
    result =
      case Map.get(state.by_agent_id, agent_id) do
        nil -> {:error, :not_found}
        %{status: :suspended} -> {:error, :identity_suspended}
        %{status: :revoked} -> {:error, :identity_revoked}
        %{encryption_public_key: nil} -> {:error, :no_encryption_key}
        %{encryption_public_key: key} -> {:ok, key}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:registered?, agent_id}, _from, state) do
    {:reply, Map.has_key?(state.by_agent_id, agent_id), state}
  end

  @impl true
  def handle_call({:deregister, agent_id}, _from, state) do
    case Map.get(state.by_agent_id, agent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{public_key: pk, name: name} ->
        pk_hash = Crypto.hash(pk)

        state =
          state
          |> update_in([:by_agent_id], &Map.delete(&1, agent_id))
          |> update_in([:by_public_key_hash], &Map.delete(&1, pk_hash))
          |> deindex_by_name(name, agent_id)
          |> update_in([:stats, :total_deregistered], &(&1 + 1))

        delete_from_store(agent_id)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:lookup_by_name, name}, _from, state) do
    case Map.get(state.by_name, name) do
      nil -> {:reply, {:error, :not_found}, state}
      [] -> {:reply, {:error, :not_found}, state}
      agent_ids -> {:reply, {:ok, agent_ids}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        active_identities: map_size(state.by_agent_id),
        named_identities: map_size(state.by_name)
      })

    {:reply, stats, state}
  end

  # ===========================================================================
  # Lifecycle Callbacks
  # ===========================================================================

  @impl true
  def handle_call({:suspend, agent_id, reason}, _from, state) do
    case Map.get(state.by_agent_id, agent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: :revoked} ->
        {:reply, {:error, :cannot_suspend_revoked}, state}

      entry ->
        updated_entry = %{
          entry
          | status: :suspended,
            status_changed_at: DateTime.utc_now(),
            status_reason: reason
        }

        state = put_in(state, [:by_agent_id, agent_id], updated_entry)
        persist_to_store(agent_id, updated_entry)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:resume, agent_id}, _from, state) do
    case Map.get(state.by_agent_id, agent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: :revoked} ->
        {:reply, {:error, :cannot_resume_revoked}, state}

      entry ->
        updated_entry = %{
          entry
          | status: :active,
            status_changed_at: DateTime.utc_now(),
            status_reason: nil
        }

        state = put_in(state, [:by_agent_id, agent_id], updated_entry)
        persist_to_store(agent_id, updated_entry)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:revoke_identity, agent_id, reason}, _from, state) do
    case Map.get(state.by_agent_id, agent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        updated_entry = %{
          entry
          | status: :revoked,
            status_changed_at: DateTime.utc_now(),
            status_reason: reason
        }

        state = put_in(state, [:by_agent_id, agent_id], updated_entry)
        persist_to_store(agent_id, updated_entry)

        # Revoke all capabilities for this agent
        {:ok, revoked_count} = CapabilityStore.revoke_all(agent_id)

        {:reply, {:ok, revoked_count}, state}
    end
  end

  @impl true
  def handle_call({:get_status, agent_id}, _from, state) do
    result =
      case Map.get(state.by_agent_id, agent_id) do
        nil -> {:error, :not_found}
        %{status: status} -> {:ok, status}
        # Old entries without status field default to :unknown
        _entry -> {:ok, :unknown}
      end

    {:reply, result, state}
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  defp index_by_name(state, nil, _agent_id), do: state

  defp index_by_name(state, name, agent_id) do
    update_in(state, [:by_name, name], fn
      nil -> [agent_id]
      ids -> [agent_id | ids]
    end)
  end

  defp deindex_by_name(state, nil, _agent_id), do: state

  defp deindex_by_name(state, name, agent_id) do
    update_in(state, [:by_name, name], fn
      nil -> nil
      ids -> List.delete(ids, agent_id)
    end)
  end

  # ===========================================================================
  # Persistence via BufferedStore
  # ===========================================================================

  @id_store :arbor_security_identities

  defp persist_to_store(agent_id, entry) do
    if Process.whereis(@id_store) do
      data = serialize_entry(agent_id, entry)
      record = Record.new(agent_id, data)
      apply(@buffered_store, :put, [agent_id, record, [name: @id_store]])
    end

    :ok
  catch
    _, reason ->
      Logger.warning("Failed to persist identity #{agent_id}: #{inspect(reason)}")
      :ok
  end

  defp delete_from_store(agent_id) do
    if Process.whereis(@id_store) do
      apply(@buffered_store, :delete, [agent_id, [name: @id_store]])
    end

    :ok
  catch
    _, reason ->
      Logger.warning("Failed to delete persisted identity #{agent_id}: #{inspect(reason)}")
      :ok
  end

  defp restore_from_store(state) do
    if Process.whereis(@id_store) do
      case apply(@buffered_store, :list, [[name: @id_store]]) do
        {:ok, keys} ->
          Enum.reduce(keys, state, &restore_key_from_store/2)

        {:error, _reason} ->
          state
      end
    else
      state
    end
  catch
    _, reason ->
      Logger.warning("Failed to restore identities: #{inspect(reason)}")
      state
  end

  defp restore_key_from_store(key, acc) do
    case apply(@buffered_store, :get, [key, [name: @id_store]]) do
      {:ok, %Record{data: data}} ->
        restore_entry(acc, data)

      {:error, reason} ->
        Logger.warning("Failed to restore identity #{key}: #{inspect(reason)}")
        acc
    end
  end

  defp restore_entry(state, data) do
    case deserialize_entry(data) do
      {:ok, agent_id, entry} ->
        pk_hash = Crypto.hash(entry.public_key)

        state
        |> put_in([:by_agent_id, agent_id], entry)
        |> put_in([:by_public_key_hash, pk_hash], agent_id)
        |> index_by_name(entry.name, agent_id)
        |> update_in([:stats, :total_registered], &(&1 + 1))

      {:error, reason} ->
        Logger.warning("Failed to deserialize identity: #{inspect(reason)}")
        state
    end
  rescue
    e ->
      Logger.warning("Failed to restore identity entry: #{inspect(e)}")
      state
  end

  # ===========================================================================
  # Serialization (binary keys ↔ hex strings for JSON)
  # ===========================================================================

  defp serialize_entry(agent_id, entry) do
    %{
      "agent_id" => agent_id,
      "public_key" => Base.encode16(entry.public_key, case: :lower),
      "encryption_public_key" => encode_optional_key(entry.encryption_public_key),
      "name" => entry.name,
      "key_version" => entry.key_version,
      "created_at" => DateTime.to_iso8601(entry.created_at),
      "metadata" => entry.metadata,
      "status" => Atom.to_string(entry.status),
      "status_changed_at" => encode_optional_datetime(entry.status_changed_at),
      "status_reason" => entry.status_reason
    }
  end

  defp deserialize_entry(data) when is_map(data) do
    entry = %{
      public_key: Base.decode16!(data["public_key"], case: :mixed),
      encryption_public_key: decode_optional_key(data["encryption_public_key"]),
      name: data["name"],
      key_version: data["key_version"] || 1,
      created_at: parse_datetime(data["created_at"]),
      metadata: data["metadata"] || %{},
      status: String.to_existing_atom(data["status"] || "active"),
      status_changed_at: parse_optional_datetime(data["status_changed_at"]),
      status_reason: data["status_reason"]
    }

    {:ok, data["agent_id"], entry}
  rescue
    e -> {:error, e}
  end

  defp encode_optional_key(nil), do: nil
  defp encode_optional_key(key) when is_binary(key), do: Base.encode16(key, case: :lower)

  defp decode_optional_key(nil), do: nil
  defp decode_optional_key(hex) when is_binary(hex), do: Base.decode16!(hex, case: :mixed)

  defp encode_optional_datetime(nil), do: nil
  defp encode_optional_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_optional_datetime(nil), do: nil

  defp parse_optional_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
