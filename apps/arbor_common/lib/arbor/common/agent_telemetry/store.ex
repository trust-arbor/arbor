defmodule Arbor.Common.AgentTelemetry.Store do
  @moduledoc """
  ETS-backed store for agent telemetry metrics.

  The GenServer's only responsibility is to own the ETS table and manage its
  lifecycle. All reads and writes go directly through ETS (which is
  concurrent-safe for single-key operations), avoiding GenServer bottlenecks.

  ## Usage

      # Atomic read-modify-write for a turn
      Store.record_turn("agent_abc", %{input_tokens: 150, cost: 0.003})

      # Direct read
      Store.get("agent_abc")
      #=> %Telemetry{...}

      # Dashboard overview
      Store.all()
      #=> [%Telemetry{}, ...]
  """

  use GenServer

  require Logger

  alias Arbor.Common.AgentTelemetry
  alias Arbor.Contracts.Agent.Telemetry

  @table :arbor_agent_telemetry

  # ===========================================================================
  # Public API (direct ETS access — no GenServer calls)
  # ===========================================================================

  @doc """
  Get telemetry for an agent. Returns `%Telemetry{}` or `nil`.
  """
  @spec get(String.t()) :: Telemetry.t() | nil
  def get(agent_id) when is_binary(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, telemetry}] -> telemetry
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Write telemetry for an agent.
  """
  @spec put(String.t(), Telemetry.t()) :: :ok
  def put(agent_id, %Telemetry{} = telemetry) when is_binary(agent_id) do
    :ets.insert(@table, {agent_id, telemetry})
    :ok
  end

  @doc """
  Record a completed LLM turn. Auto-creates telemetry if agent is new.
  """
  @spec record_turn(String.t(), map()) :: :ok
  def record_turn(agent_id, usage) when is_binary(agent_id) and is_map(usage) do
    telemetry = get_or_create(agent_id)
    put(agent_id, AgentTelemetry.record_turn(telemetry, usage))
  end

  @doc """
  Record a tool call. Auto-creates telemetry if agent is new.
  """
  @spec record_tool(String.t(), String.t(), :ok | :error | :gated, non_neg_integer()) :: :ok
  def record_tool(agent_id, tool_name, result, duration_ms)
      when is_binary(agent_id) and is_binary(tool_name) do
    telemetry = get_or_create(agent_id)
    put(agent_id, AgentTelemetry.record_tool(telemetry, tool_name, result, duration_ms))
  end

  @doc """
  Record a sensitivity routing decision. Auto-creates telemetry if agent is new.
  """
  @spec record_routing(String.t(), :classified | :rerouted | :tokenized | :blocked) :: :ok
  def record_routing(agent_id, decision) when is_binary(agent_id) do
    telemetry = get_or_create(agent_id)
    put(agent_id, AgentTelemetry.record_routing(telemetry, decision))
  end

  @doc """
  Record a context compaction event. Auto-creates telemetry if agent is new.
  """
  @spec record_compaction(String.t(), float()) :: :ok
  def record_compaction(agent_id, utilization_pct) when is_binary(agent_id) do
    telemetry = get_or_create(agent_id)
    put(agent_id, AgentTelemetry.record_compaction(telemetry, utilization_pct))
  end

  @doc """
  Return telemetry for all tracked agents.
  """
  @spec all() :: [Telemetry.t()]
  def all do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, telemetry} -> telemetry end)
  rescue
    ArgumentError -> []
  end

  @doc """
  Delete telemetry for a destroyed agent.
  """
  @spec delete(String.t()) :: :ok
  def delete(agent_id) when is_binary(agent_id) do
    :ets.delete(@table, agent_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Reset session-scoped metrics for an agent.
  """
  @spec reset_session(String.t()) :: :ok
  def reset_session(agent_id) when is_binary(agent_id) do
    case get(agent_id) do
      nil -> :ok
      telemetry -> put(agent_id, AgentTelemetry.reset_session(telemetry))
    end
  end

  # ===========================================================================
  # GenServer (table ownership only)
  # ===========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true
      ])

    {:ok, %{table: table}}
  end

  # ===========================================================================
  # Private
  # ===========================================================================

  defp get_or_create(agent_id) do
    case get(agent_id) do
      nil -> AgentTelemetry.new(agent_id)
      telemetry -> telemetry
    end
  end
end
