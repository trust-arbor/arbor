defmodule Arbor.Security.Identity.Registry do
  @moduledoc """
  In-memory registry for agent identities.

  Stores public keys indexed by agent ID for fast lookup during signature
  verification. Private keys are never stored — only the public portion
  of an identity is retained.

  Follows the same GenServer pattern as `CapabilityStore`.
  """

  use GenServer

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security.Crypto

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

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok,
     %{
       by_agent_id: %{},
       by_public_key_hash: %{},
       by_name: %{},
       stats: %{total_registered: 0, total_deregistered: 0}
     }}
  end

  @impl true
  def handle_call({:register, %Identity{} = identity}, _from, state) do
    expected_id = Crypto.derive_agent_id(identity.public_key)

    cond do
      identity.agent_id != expected_id ->
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
          metadata: identity.metadata
        }

        state =
          state
          |> put_in([:by_agent_id, identity.agent_id], entry)
          |> put_in([:by_public_key_hash, pk_hash], identity.agent_id)
          |> index_by_name(identity.name, identity.agent_id)
          |> update_in([:stats, :total_registered], &(&1 + 1))

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:lookup, agent_id}, _from, state) do
    result =
      case Map.get(state.by_agent_id, agent_id) do
        nil -> {:error, :not_found}
        %{public_key: pk} -> {:ok, pk}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:lookup_encryption_key, agent_id}, _from, state) do
    result =
      case Map.get(state.by_agent_id, agent_id) do
        nil -> {:error, :not_found}
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

  # Private helpers

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
end
