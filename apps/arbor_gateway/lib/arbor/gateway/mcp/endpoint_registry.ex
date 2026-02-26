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
    end

    :ok
  end

  @doc "Look up an agent's MCP endpoint."
  @spec lookup(String.t()) :: {:ok, pid(), [map()]} | :error
  def lookup(agent_id) do
    if table_exists?() do
      case :ets.lookup(@table, agent_id) do
        [{^agent_id, pid, tools, _started_at}] ->
          if Process.alive?(pid), do: {:ok, pid, tools}, else: :error

        _ ->
          :error
      end
    else
      :error
    end
  end

  @doc "List all registered agent endpoints."
  @spec list() :: [{String.t(), pid(), integer()}]
  def list do
    if table_exists?() do
      :ets.tab2list(@table)
      |> Enum.filter(fn {_id, pid, _tools, _ts} -> Process.alive?(pid) end)
      |> Enum.map(fn {id, pid, tools, _ts} -> {id, pid, length(tools)} end)
    else
      []
    end
  end

  # -- GenServer --

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call(_msg, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp table_exists? do
    :ets.info(@table) != :undefined
  end
end
