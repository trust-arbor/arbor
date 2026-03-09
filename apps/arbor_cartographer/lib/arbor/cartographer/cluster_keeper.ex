defmodule Arbor.Cartographer.ClusterKeeper do
  @moduledoc """
  Monitors cluster connectivity and automatically reconnects known nodes.

  When a node disconnects (due to network hiccup, sleep, or temporary
  outage), the ClusterKeeper remembers it and periodically attempts
  to reconnect. This keeps the cluster resilient to transient failures
  without requiring manual `mix arbor.cluster connect` each time.

  ## Configuration

      config :arbor_cartographer, :cluster_keeper,
        reconnect_interval: 30_000,   # Check every 30s (default)
        enabled: true                  # Set false to disable

  Nodes are remembered for the lifetime of the BEAM process. On restart,
  the node list starts fresh (nodes reconnect via initial cluster setup).
  """

  use GenServer

  require Logger

  @default_interval 30_000

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List all known nodes and their current status."
  @spec known_nodes() :: [{node(), :connected | :disconnected}]
  def known_nodes do
    GenServer.call(__MODULE__, :known_nodes)
  end

  @doc "Manually add a node to the known set."
  @spec remember_node(node()) :: :ok
  def remember_node(node) do
    GenServer.cast(__MODULE__, {:remember, node})
  end

  @doc "Remove a node from the known set (stop reconnecting)."
  @spec forget_node(node()) :: :ok
  def forget_node(node) do
    GenServer.cast(__MODULE__, {:forget, node})
  end

  # ── GenServer ───────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :reconnect_interval, @default_interval)

    # Monitor node connections/disconnections
    :net_kernel.monitor_nodes(true, node_type: :visible)

    # Seed with currently connected nodes (excluding ephemeral mix task nodes)
    known =
      Node.list()
      |> Enum.reject(&ephemeral_node?/1)
      |> MapSet.new()

    schedule_reconnect(interval)

    {:ok, %{known: known, interval: interval}}
  end

  @impl true
  def handle_call(:known_nodes, _from, state) do
    connected = MapSet.new(Node.list())

    status =
      state.known
      |> Enum.map(fn node ->
        if MapSet.member?(connected, node),
          do: {node, :connected},
          else: {node, :disconnected}
      end)
      |> Enum.sort()

    {:reply, status, state}
  end

  @impl true
  def handle_cast({:remember, node}, state) do
    {:noreply, %{state | known: MapSet.put(state.known, node)}}
  end

  @impl true
  def handle_cast({:forget, node}, state) do
    {:noreply, %{state | known: MapSet.delete(state.known, node)}}
  end

  @impl true
  def handle_info({:nodeup, node, _info}, state) do
    if ephemeral_node?(node) do
      {:noreply, state}
    else
      Logger.info("ClusterKeeper: node connected — #{node}")
      {:noreply, %{state | known: MapSet.put(state.known, node)}}
    end
  end

  @impl true
  def handle_info({:nodedown, node, _info}, state) do
    Logger.warning("ClusterKeeper: node disconnected — #{node}")
    {:noreply, state}
  end

  @impl true
  def handle_info(:reconnect, state) do
    connected = MapSet.new(Node.list())
    disconnected = MapSet.difference(state.known, connected)

    unless MapSet.size(disconnected) == 0 do
      for node <- disconnected do
        case :net_adm.ping(node) do
          :pong ->
            Logger.info("ClusterKeeper: reconnected to #{node}")

            # Trigger capability sync if available
            if Code.ensure_loaded?(Arbor.Cartographer.CapabilityRegistry) do
              spawn(fn ->
                Arbor.Cartographer.CapabilityRegistry.sync_cluster()
              end)
            end

          :pang ->
            :ok
        end
      end
    end

    schedule_reconnect(state.interval)
    {:noreply, state}
  end

  defp schedule_reconnect(interval) do
    Process.send_after(self(), :reconnect, interval)
  end

  defp ephemeral_node?(node) do
    node |> Atom.to_string() |> String.starts_with?("arbor_mix_")
  end
end
