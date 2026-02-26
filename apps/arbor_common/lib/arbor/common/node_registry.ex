defmodule Arbor.Common.NodeRegistry do
  @moduledoc """
  Maps BEAM nodes to trust zones for distributed Arbor deployments.

  Trust zones define isolation boundaries for cross-node communication:

  | Zone | Level | Description | Example Apps |
  |------|-------|-------------|-------------|
  | 0 | Hostile/External | Untrusted: gateway, sandbox, plugins | arbor_gateway, arbor_sandbox |
  | 1 | Verified/Worker | Agent execution, LLM calls, orchestration | arbor_agent, arbor_ai |
  | 2 | Trusted/Core | Security kernel, persistence, trust | arbor_security, arbor_trust |

  ## Cross-Zone Resolution Rules

  - Zone 2 backends only resolvable from Zone 2 nodes
  - Zone 1 backends resolvable from Zone 1 and Zone 2
  - Zone 0 backends resolvable from anywhere (but taint-tagged)

  ## Configuration

      # Production — multi-node
      config :arbor_common, :trust_zones, %{
        :"security@host" => %{zone: 2, apps: [:arbor_security, :arbor_trust]},
        :"worker@host"   => %{zone: 1, apps: [:arbor_agent, :arbor_ai]},
        :"gateway@host"  => %{zone: 0, apps: [:arbor_gateway]}
      }

      # Development — single node, zones disabled
      config :arbor_common, :trust_zones, :disabled

  When disabled (default), all nodes are treated as Zone 2 (trusted).
  This is the single-node development experience.
  """

  use GenServer

  require Logger

  @table :arbor_node_registry

  @type zone :: 0 | 1 | 2
  @type zone_info :: %{zone: zone(), apps: [atom()]}

  # =========================================================================
  # Public API
  # =========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get the trust zone for a node. Returns the zone level (0, 1, or 2).

  When zones are disabled, returns 2 (trusted) for all nodes.
  For unknown nodes, returns 0 (hostile/external).
  """
  @spec trust_zone(node()) :: zone()
  def trust_zone(node_name) do
    case :ets.lookup(@table, node_name) do
      [{_, %{zone: zone}}] -> zone
      [] -> if zones_disabled?(), do: 2, else: 0
    end
  rescue
    ArgumentError -> if zones_disabled?(), do: 2, else: 0
  end

  @doc """
  Check if zones are disabled (single-node mode).
  """
  @spec zones_disabled?() :: boolean()
  def zones_disabled? do
    Application.get_env(:arbor_common, :trust_zones, :disabled) == :disabled
  end

  @doc """
  Check if data can flow from one zone to another.

  Returns `:ok` or `{:error, {:zone_violation, from_zone, to_zone}}`.
  """
  @spec can_access?(zone(), zone()) :: :ok | {:error, term()}
  def can_access?(from_zone, to_zone) when is_integer(from_zone) and is_integer(to_zone) do
    cond do
      # Same zone — always allowed
      from_zone == to_zone -> :ok
      # Higher zone accessing lower — always allowed (trusted can see everything below)
      from_zone > to_zone -> :ok
      # Zone 0 → Zone 2 — blocked (must go through Zone 1 first)
      from_zone == 0 and to_zone == 2 -> {:error, {:zone_violation, from_zone, to_zone}}
      # Zone 0 → Zone 1 or Zone 1 → Zone 2 — allowed with sanitization
      from_zone < to_zone -> :ok
    end
  end

  @doc """
  Check if a node in `from_zone` can resolve a registry entry from `entry_zone`.

  This enforces the cross-zone resolution rules:
  - Zone 2 entries: only from Zone 2 nodes
  - Zone 1 entries: from Zone 1 and Zone 2 nodes
  - Zone 0 entries: from any node
  """
  @spec can_resolve?(zone(), zone()) :: boolean()
  def can_resolve?(from_zone, entry_zone) do
    from_zone >= entry_zone
  end

  @doc """
  Register a node with its trust zone info.
  """
  @spec register_node(node(), zone_info()) :: :ok
  def register_node(node_name, zone_info) do
    GenServer.call(__MODULE__, {:register_node, node_name, zone_info})
  end

  @doc """
  Get all registered nodes and their zone info.
  """
  @spec list_nodes() :: [{node(), zone_info()}]
  def list_nodes do
    :ets.tab2list(@table)
  rescue
    ArgumentError -> []
  end

  @doc """
  Get all nodes in a specific zone.
  """
  @spec nodes_in_zone(zone()) :: [node()]
  def nodes_in_zone(zone) do
    :ets.tab2list(@table)
    |> Enum.filter(fn {_node, info} -> info.zone == zone end)
    |> Enum.map(fn {node, _info} -> node end)
  rescue
    ArgumentError -> []
  end

  @doc """
  Get the local node's trust zone.
  """
  @spec local_zone() :: zone()
  def local_zone do
    trust_zone(node())
  end

  # =========================================================================
  # GenServer callbacks
  # =========================================================================

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    # Load zone configuration
    load_config()

    # Monitor node connections/disconnections
    :net_kernel.monitor_nodes(true)

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register_node, node_name, zone_info}, _from, state) do
    :ets.insert(@table, {node_name, zone_info})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:nodeup, node_name}, state) do
    Logger.info("[NodeRegistry] Node connected: #{node_name}")

    # Check if this node is in our config
    case configured_zone(node_name) do
      nil ->
        # Unknown node — register as Zone 0 (hostile) by default
        :ets.insert(@table, {node_name, %{zone: 0, apps: []}})
        Logger.warning("[NodeRegistry] Unknown node #{node_name} registered as Zone 0 (hostile)")

      zone_info ->
        :ets.insert(@table, {node_name, zone_info})
        Logger.info("[NodeRegistry] Node #{node_name} registered as Zone #{zone_info.zone}")
    end

    {:noreply, state}
  end

  def handle_info({:nodedown, node_name}, state) do
    Logger.info("[NodeRegistry] Node disconnected: #{node_name}")
    :ets.delete(@table, node_name)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # =========================================================================
  # Internals
  # =========================================================================

  defp load_config do
    case Application.get_env(:arbor_common, :trust_zones, :disabled) do
      :disabled ->
        # Single-node mode — register local node as Zone 2
        :ets.insert(@table, {node(), %{zone: 2, apps: []}})

      zones when is_map(zones) ->
        Enum.each(zones, fn {node_name, zone_info} ->
          :ets.insert(@table, {node_name, zone_info})
        end)

        # Ensure local node is registered
        unless :ets.member(@table, node()) do
          :ets.insert(@table, {node(), %{zone: 2, apps: []}})
        end
    end
  end

  defp configured_zone(node_name) do
    case Application.get_env(:arbor_common, :trust_zones, :disabled) do
      :disabled -> %{zone: 2, apps: []}
      zones when is_map(zones) -> Map.get(zones, node_name)
    end
  end
end
