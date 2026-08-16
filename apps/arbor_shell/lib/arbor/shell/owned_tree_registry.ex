defmodule Arbor.Shell.OwnedTreeRegistry do
  @moduledoc false

  use GenServer

  @type purpose :: :unbound | :trusted_build_source | :trusted_build_workspace

  @type identity :: %{
          path: String.t(),
          type: :directory,
          device: non_neg_integer(),
          minor_device: non_neg_integer(),
          inode: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [List.wrap(opts)]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec checkout() :: {:ok, pid(), reference()} | {:error, :owned_tree_registry_unavailable}
  def checkout do
    call(:checkout)
  end

  @spec put(identity(), purpose()) :: :ok | {:error, term()}
  def put(identity, purpose) when purpose in [:unbound, :trusted_build_workspace] do
    call({:put, identity, purpose})
  end

  def put(_identity, _purpose), do: {:error, :invalid_owned_tree_purpose}

  @spec cas(identity(), purpose(), purpose()) :: :ok | {:error, term()}
  def cas(identity, from, to)
      when from in [:unbound, :trusted_build_source, :trusted_build_workspace] and
             to in [:unbound, :trusted_build_source, :trusted_build_workspace] do
    call({:cas, identity, from, to})
  end

  def cas(_identity, _from, _to), do: {:error, :invalid_owned_tree_purpose}

  @spec fetch(identity()) :: {:ok, purpose(), reference()} | {:error, term()}
  def fetch(identity), do: call({:fetch, identity})

  @spec delete(identity()) :: :ok | {:error, term()}
  def delete(identity), do: call({:delete, identity})

  @impl true
  def init(_opts) do
    {:ok, %{generation: make_ref(), entries: %{}}}
  end

  @impl true
  def handle_call(:checkout, _from, state) do
    {:reply, {:ok, self(), state.generation}, state}
  end

  def handle_call({:put, identity, purpose}, _from, state) do
    case identity_key(identity) do
      {:ok, key} ->
        if Map.has_key?(state.entries, key) do
          {:reply, {:error, :owned_tree_already_registered}, state}
        else
          entry = %{purpose: purpose, generation: state.generation}
          {:reply, :ok, %{state | entries: Map.put(state.entries, key, entry)}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cas, identity, from, to}, _from, state) do
    case identity_key(identity) do
      {:ok, key} ->
        case Map.get(state.entries, key) do
          %{purpose: ^from, generation: gen} when gen == state.generation ->
            entry = %{purpose: to, generation: state.generation}
            {:reply, :ok, %{state | entries: Map.put(state.entries, key, entry)}}

          %{purpose: _other} ->
            {:reply, {:error, :owned_tree_purpose_mismatch}, state}

          nil ->
            {:reply, {:error, :owned_tree_not_registered}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:fetch, identity}, _from, state) do
    case identity_key(identity) do
      {:ok, key} ->
        case Map.get(state.entries, key) do
          %{purpose: purpose, generation: gen} when gen == state.generation ->
            {:reply, {:ok, purpose, state.generation}, state}

          %{generation: _stale} ->
            {:reply, {:error, :owned_tree_registry_generation_mismatch}, state}

          nil ->
            {:reply, {:error, :owned_tree_not_registered}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete, identity}, _from, state) do
    case identity_key(identity) do
      {:ok, key} ->
        if Map.has_key?(state.entries, key) do
          {:reply, :ok, %{state | entries: Map.delete(state.entries, key)}}
        else
          {:reply, {:error, :owned_tree_not_registered}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :unsupported_owned_tree_registry_request}, state}
  end

  defp call(request) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :owned_tree_registry_unavailable}

      _pid ->
        GenServer.call(__MODULE__, request)
    end
  catch
    :exit, _ -> {:error, :owned_tree_registry_unavailable}
  end

  defp identity_key(%{
         path: path,
         type: :directory,
         device: device,
         minor_device: minor_device,
         inode: inode
       })
       when is_binary(path) and is_integer(device) and device >= 0 and
              is_integer(minor_device) and minor_device >= 0 and is_integer(inode) and
              inode >= 0 do
    {:ok, {path, device, minor_device, inode}}
  end

  defp identity_key(_identity), do: {:error, :invalid_owned_tree_identity}
end
