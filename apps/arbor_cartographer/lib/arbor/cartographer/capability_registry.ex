defmodule Arbor.Cartographer.CapabilityRegistry do
  @moduledoc """
  Local capability registry using ETS.

  Stores and retrieves capability information for nodes. Currently supports
  local-only operation with the current node's capabilities.

  ## Architecture

  The registry stores node capabilities in an ETS table with the structure:
  - Key: `node_id` (atom)
  - Value: `node_capabilities` map

  ## Future Extensions

  This module is designed to support cluster-wide capability queries once
  mesh integration is added. Current implementation focuses on local operations.
  """

  use GenServer

  alias Arbor.Contracts.Libraries.Cartographer, as: Contract

  @type node_capabilities :: Contract.node_capabilities()
  @type capability_tag :: Contract.capability_tag()
  @type node_id :: Contract.node_id()

  @table_name :arbor_cartographer_capabilities
  @load_table_name :arbor_cartographer_loads

  # ==========================================================================
  # Client API
  # ==========================================================================

  @doc """
  Start the capability registry.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register capabilities for a node.

  ## Parameters
  - `node_id` - The node identifier (defaults to current node)
  - `capabilities` - The full capabilities map
  """
  @spec register(node_id(), node_capabilities()) :: :ok
  def register(node_id \\ Node.self(), capabilities) do
    GenServer.call(__MODULE__, {:register, node_id, capabilities})
  end

  @doc """
  Add additional capability tags to a node.

  Merges the new tags with existing tags.
  """
  @spec add_tags(node_id(), [capability_tag()]) :: :ok | {:error, :not_found}
  def add_tags(node_id \\ Node.self(), tags) do
    GenServer.call(__MODULE__, {:add_tags, node_id, tags})
  end

  @doc """
  Remove capability tags from a node.
  """
  @spec remove_tags(node_id(), [capability_tag()]) :: :ok
  def remove_tags(node_id \\ Node.self(), tags) do
    GenServer.call(__MODULE__, {:remove_tags, node_id, tags})
  end

  @doc """
  Get capabilities for a specific node.
  """
  @spec get(node_id()) :: {:ok, node_capabilities()} | {:error, :not_found}
  def get(node_id) do
    case :ets.lookup(@table_name, node_id) do
      [{^node_id, capabilities}] -> {:ok, capabilities}
      [] -> {:error, :not_found}
    end
  catch
    :error, :badarg -> {:error, :not_found}
  end

  @doc """
  Get capabilities for the current node.
  """
  @spec my_capabilities() :: {:ok, [capability_tag()]} | {:error, :not_registered}
  def my_capabilities do
    case get(Node.self()) do
      {:ok, caps} -> {:ok, caps.tags}
      {:error, _} -> {:error, :not_registered}
    end
  end

  @doc """
  List all registered node capabilities.
  """
  @spec list_all() :: {:ok, [node_capabilities()]}
  def list_all do
    capabilities =
      :ets.tab2list(@table_name)
      |> Enum.map(fn {_node_id, caps} -> caps end)

    {:ok, capabilities}
  catch
    :error, :badarg -> {:ok, []}
  end

  @doc """
  Find nodes matching all required capabilities.

  ## Options
  - `:min_load` - Minimum acceptable load score (0-100)
  - `:max_load` - Maximum acceptable load score (0-100)
  - `:limit` - Maximum number of nodes to return
  """
  @spec find_nodes([capability_tag()], keyword()) :: {:ok, [node_id()]}
  def find_nodes(required_capabilities, opts \\ []) do
    min_load = Keyword.get(opts, :min_load, 0)
    max_load = Keyword.get(opts, :max_load, 100)
    limit = Keyword.get(opts, :limit, :infinity)

    nodes =
      :ets.tab2list(@table_name)
      |> Enum.filter(fn {_node_id, caps} ->
        has_all_capabilities?(caps.tags, required_capabilities) &&
          caps.load >= min_load &&
          caps.load <= max_load
      end)
      |> Enum.sort_by(fn {_node_id, caps} -> caps.load end)
      |> Enum.map(fn {node_id, _caps} -> node_id end)
      |> maybe_limit(limit)

    {:ok, nodes}
  catch
    :error, :badarg -> {:ok, []}
  end

  @doc """
  Find nodes that have a specific tag.
  """
  @spec nodes_with_tag(capability_tag()) :: {:ok, [node_id()]}
  def nodes_with_tag(tag) do
    nodes =
      :ets.tab2list(@table_name)
      |> Enum.filter(fn {_node_id, caps} -> tag in caps.tags end)
      |> Enum.map(fn {node_id, _caps} -> node_id end)

    {:ok, nodes}
  catch
    :error, :badarg -> {:ok, []}
  end

  @doc """
  Check if a node has all specified capabilities.
  """
  @spec node_has_capabilities?(node_id(), [capability_tag()]) :: boolean()
  def node_has_capabilities?(node_id, required_capabilities) do
    case get(node_id) do
      {:ok, caps} -> has_all_capabilities?(caps.tags, required_capabilities)
      {:error, _} -> false
    end
  end

  @doc """
  Unregister a node from the registry.
  """
  @spec unregister(node_id()) :: :ok
  def unregister(node_id) do
    GenServer.call(__MODULE__, {:unregister, node_id})
  end

  # ==========================================================================
  # Load Tracking
  # ==========================================================================

  @doc """
  Update the load score for a node.
  """
  @spec update_load(node_id(), float()) :: :ok
  def update_load(node_id \\ Node.self(), load_score) do
    GenServer.call(__MODULE__, {:update_load, node_id, load_score})
  end

  @doc """
  Get the load score for a node.
  """
  @spec get_load(node_id()) :: {:ok, float()} | {:error, :not_found}
  def get_load(node_id) do
    case :ets.lookup(@load_table_name, node_id) do
      [{^node_id, load}] -> {:ok, load}
      [] -> {:error, :not_found}
    end
  catch
    :error, :badarg -> {:error, :not_found}
  end

  @doc """
  Get all node load scores.
  """
  @spec get_all_loads() :: {:ok, %{node_id() => float()}}
  def get_all_loads do
    loads =
      :ets.tab2list(@load_table_name)
      |> Map.new()

    {:ok, loads}
  catch
    :error, :badarg -> {:ok, %{}}
  end

  # ==========================================================================
  # GenServer Callbacks
  # ==========================================================================

  @impl true
  def init(_opts) do
    # Create ETS tables
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@load_table_name, [:named_table, :set, :public, read_concurrency: true])

    # Monitor cluster membership
    :net_kernel.monitor_nodes(true, node_type: :visible)

    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, node_id, capabilities}, _from, state) do
    :ets.insert(@table_name, {node_id, capabilities})
    :ets.insert(@load_table_name, {node_id, capabilities.load})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:add_tags, node_id, new_tags}, _from, state) do
    case :ets.lookup(@table_name, node_id) do
      [{^node_id, caps}] ->
        updated_tags = Enum.uniq(caps.tags ++ new_tags)
        updated_caps = %{caps | tags: updated_tags}
        :ets.insert(@table_name, {node_id, updated_caps})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:remove_tags, node_id, tags_to_remove}, _from, state) do
    case :ets.lookup(@table_name, node_id) do
      [{^node_id, caps}] ->
        updated_tags = caps.tags -- tags_to_remove
        updated_caps = %{caps | tags: updated_tags}
        :ets.insert(@table_name, {node_id, updated_caps})
        {:reply, :ok, state}

      [] ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:unregister, node_id}, _from, state) do
    :ets.delete(@table_name, node_id)
    :ets.delete(@load_table_name, node_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update_load, node_id, load_score}, _from, state) do
    :ets.insert(@load_table_name, {node_id, load_score})

    # Also update in capabilities table if exists
    case :ets.lookup(@table_name, node_id) do
      [{^node_id, caps}] ->
        :ets.insert(@table_name, {node_id, %{caps | load: load_score}})

      [] ->
        :ok
    end

    {:reply, :ok, state}
  end

  # ==========================================================================
  # Cluster Sync
  # ==========================================================================

  @doc """
  Receive capabilities from a remote node's Scout.

  Called via RPC when a node joins the cluster or broadcasts updates.
  """
  @spec receive_capabilities(node_id(), node_capabilities()) :: :ok
  def receive_capabilities(node_id, capabilities) do
    GenServer.call(__MODULE__, {:register, node_id, capabilities})
  end

  @doc """
  Request capabilities exchange with all connected nodes.

  Sends our capabilities to each node and requests theirs.
  """
  @spec sync_cluster() :: :ok
  def sync_cluster do
    GenServer.cast(__MODULE__, :sync_cluster)
  end

  @impl true
  def handle_info({:nodeup, node, _info}, state) do
    require Logger
    Logger.info("[Cartographer.Registry] Node joined: #{node}")

    # Request capabilities from the new node's Scout (async to avoid blocking)
    Task.start(fn -> request_remote_capabilities(node) end)

    # Send our capabilities to the new node
    Task.start(fn -> push_local_capabilities(node) end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node, _info}, state) do
    require Logger
    Logger.info("[Cartographer.Registry] Node left: #{node}")

    # Clean up the departed node's capabilities
    :ets.delete(@table_name, node)
    :ets.delete(@load_table_name, node)

    {:noreply, state}
  end

  @impl true
  def handle_cast(:sync_cluster, state) do
    for node <- Node.list() do
      Task.start(fn -> request_remote_capabilities(node) end)
      Task.start(fn -> push_local_capabilities(node) end)
    end

    {:noreply, state}
  end

  defp request_remote_capabilities(node) do
    require Logger

    case :rpc.call(node, __MODULE__, :get, [node], 5_000) do
      {:ok, capabilities} ->
        :ets.insert(@table_name, {node, capabilities})
        :ets.insert(@load_table_name, {node, capabilities.load})

        Logger.info(
          "[Cartographer.Registry] Synced capabilities from #{node}: #{inspect(capabilities.tags)}"
        )

      {:error, _} ->
        # Node doesn't have Cartographer running — try raw hardware detection
        case :rpc.call(node, Arbor.Cartographer.Hardware, :detect, [], 10_000) do
          {:ok, hardware} ->
            tags = Arbor.Cartographer.Hardware.to_capability_tags(hardware)

            capabilities = %{
              node: node,
              tags: tags,
              hardware: hardware,
              load: 0.0,
              registered_at: DateTime.utc_now()
            }

            :ets.insert(@table_name, {node, capabilities})
            :ets.insert(@load_table_name, {node, 0.0})
            Logger.info("[Cartographer.Registry] Detected hardware on #{node}: #{inspect(tags)}")

          {:badrpc, _reason} ->
            Logger.debug("[Cartographer.Registry] Cannot reach Cartographer on #{node}")
        end

      {:badrpc, _reason} ->
        Logger.debug("[Cartographer.Registry] RPC to #{node} failed")
    end
  end

  defp push_local_capabilities(node) do
    case get(Node.self()) do
      {:ok, capabilities} ->
        :rpc.call(node, __MODULE__, :receive_capabilities, [Node.self(), capabilities], 5_000)

      {:error, _} ->
        :ok
    end
  end

  # ==========================================================================
  # Private Helpers
  # ==========================================================================

  defp has_all_capabilities?(node_tags, required) do
    Enum.all?(required, fn cap -> cap in node_tags end)
  end

  defp maybe_limit(list, :infinity), do: list
  defp maybe_limit(list, limit) when is_integer(limit), do: Enum.take(list, limit)
end
