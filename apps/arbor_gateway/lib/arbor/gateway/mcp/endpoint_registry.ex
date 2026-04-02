defmodule Arbor.Gateway.MCP.EndpointRegistry do
  @moduledoc """
  Registry for agent MCP endpoints.

  Tracks which agents have active MCP endpoints, allowing other agents
  to discover and connect to them for agent-to-agent communication.

  Uses an ETS table for fast lookups. The registry is started as part
  of the Gateway supervision tree.
  """

  use GenServer
  require Logger

  @table :arbor_mcp_endpoints

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register an agent's MCP endpoint."
  @spec register(String.t(), pid(), [map()]) :: :ok
  def register(agent_id, endpoint_pid, tools \\ []) do
    if table_exists?() do
      :ets.insert(@table, {agent_id, endpoint_pid, tools, DateTime.utc_now()})
      emit_distributed_signal(:endpoint_registered, agent_id, tools)
      :ok
    else
      :ok
    end
  end

  @doc "Unregister an agent's MCP endpoint."
  @spec unregister(String.t()) :: :ok
  def unregister(agent_id) do
    if table_exists?() do
      :ets.delete(@table, agent_id)
      emit_distributed_signal(:endpoint_unregistered, agent_id, [])
    end

    :ok
  end

  @doc "Look up an agent's MCP endpoint."
  @spec lookup(String.t()) :: {:ok, pid() | {:remote, node()}, [map()]} | :error
  def lookup(agent_id) do
    if table_exists?() do
      case :ets.lookup(@table, agent_id) do
        [{^agent_id, {:remote, _node} = remote, tools, _started_at}] ->
          {:ok, remote, tools}

        [{^agent_id, pid, tools, _started_at}] when is_pid(pid) ->
          if Process.alive?(pid), do: {:ok, pid, tools}, else: :error

        _ ->
          :error
      end
    else
      :error
    end
  end

  @doc "List all registered agent endpoints."
  @spec list() :: [{String.t(), pid() | {:remote, node()}, integer()}]
  def list do
    if table_exists?() do
      :ets.tab2list(@table)
      |> Enum.filter(fn
        {_id, {:remote, _node}, _tools, _ts} -> true
        {_id, pid, _tools, _ts} when is_pid(pid) -> Process.alive?(pid)
        _ -> false
      end)
      |> Enum.map(fn {id, pid_or_remote, tools, _ts} -> {id, pid_or_remote, length(tools)} end)
    else
      []
    end
  end

  # -- GenServer --

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    subscribe_to_distributed_signals()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call(_msg, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:signal_received, %{data: %{origin_node: origin}}}, state)
      when origin == node() do
    {:noreply, state}
  end

  @impl true
  def handle_info({:signal_received, %{type: :endpoint_registered, data: data}}, state) do
    # Store remote endpoint info (pid is remote — can't be called directly,
    # but discovery knows the agent has an endpoint on that node)
    agent_id = Map.get(data, :agent_id)
    tools = Map.get(data, :tools, [])
    remote_node = Map.get(data, :origin_node)

    :ets.insert(state.table, {agent_id, {:remote, remote_node}, tools, DateTime.utc_now()})
    Logger.debug("[EndpointRegistry] Discovered remote endpoint #{agent_id} on #{remote_node}")

    {:noreply, state}
  end

  @impl true
  def handle_info({:signal_received, %{type: :endpoint_unregistered, data: data}}, state) do
    agent_id = Map.get(data, :agent_id)

    # Only remove if it's a remote entry (don't delete our own local entry)
    case :ets.lookup(state.table, agent_id) do
      [{^agent_id, {:remote, _}, _, _}] ->
        :ets.delete(state.table, agent_id)
        Logger.debug("[EndpointRegistry] Removed remote endpoint #{agent_id}")

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp table_exists? do
    :ets.info(@table) != :undefined
  end

  defp emit_distributed_signal(type, agent_id, tools) do
    if Code.ensure_loaded?(Arbor.Signals) do
      Arbor.Signals.emit(
        :gateway,
        type,
        %{
          agent_id: agent_id,
          tools: tools,
          origin_node: node()
        },
        scope: :cluster
      )
    end

    :ok
  catch
    kind, reason ->
      Logger.debug("[EndpointRegistry] signal broadcast failed: #{kind} #{inspect(reason)}")
      :ok
  end

  defp subscribe_to_distributed_signals do
    bus = Arbor.Signals.Bus

    if Code.ensure_loaded?(bus) and Process.whereis(bus) do
      me = self()

      for type <- ~w(endpoint_registered endpoint_unregistered) do
        Arbor.Signals.subscribe("gateway.#{type}", fn signal ->
          send(me, {:signal_received, signal})
          :ok
        end)
      end
    end

    :ok
  catch
    kind, reason ->
      Logger.debug("[EndpointRegistry] signal subscription failed: #{kind} #{inspect(reason)}")
      :ok
  end
end
