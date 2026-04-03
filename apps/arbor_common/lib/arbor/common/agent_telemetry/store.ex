defmodule Arbor.Common.AgentTelemetry.Store do
  @moduledoc """
  ETS-backed store for agent telemetry metrics.

  The GenServer's only responsibility is to own the ETS table and manage its
  lifecycle. All reads and writes go directly through ETS (which is
  concurrent-safe for single-key operations), avoiding GenServer bottlenecks.

  Events are persisted asynchronously to Postgres for historical analysis.
  Lifetime metrics are restored from the database on first access.

  ## Usage

      # Atomic read-modify-write for a turn
      Store.record_turn("agent_abc", %{input_tokens: 150, cost: 0.003})

      # Direct read
      Store.get("agent_abc")
      #=> %Telemetry{...}

      # Dashboard overview
      Store.all()
      #=> [%Telemetry{}, ...]

      # Historical query
      Store.query_events("agent_abc", since: ~U[2026-04-01 00:00:00Z], limit: 50)
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
  Persists the event asynchronously to Postgres.
  """
  @spec record_turn(String.t(), map()) :: :ok
  def record_turn(agent_id, usage) when is_binary(agent_id) and is_map(usage) do
    telemetry = get_or_create(agent_id)
    put(agent_id, AgentTelemetry.record_turn(telemetry, usage))
    persist_event(agent_id, :turn_completed, usage)
  end

  @doc """
  Record a tool call. Auto-creates telemetry if agent is new.
  Persists the event asynchronously to Postgres.
  """
  @spec record_tool(String.t(), String.t(), :ok | :error | :gated, non_neg_integer()) :: :ok
  def record_tool(agent_id, tool_name, result, duration_ms)
      when is_binary(agent_id) and is_binary(tool_name) do
    telemetry = get_or_create(agent_id)
    put(agent_id, AgentTelemetry.record_tool(telemetry, tool_name, result, duration_ms))

    persist_event(agent_id, :tool_call, %{
      tool_name: tool_name,
      result: result,
      duration_ms: duration_ms
    })
  end

  @doc """
  Record a sensitivity routing decision. Auto-creates telemetry if agent is new.
  Persists the event asynchronously to Postgres.
  """
  @spec record_routing(String.t(), :classified | :rerouted | :tokenized | :blocked) :: :ok
  def record_routing(agent_id, decision) when is_binary(agent_id) do
    telemetry = get_or_create(agent_id)
    put(agent_id, AgentTelemetry.record_routing(telemetry, decision))
    persist_event(agent_id, :routing_decision, %{decision: decision})
  end

  @doc """
  Record a context compaction event. Auto-creates telemetry if agent is new.
  Persists the event asynchronously to Postgres.
  """
  @spec record_compaction(String.t(), float()) :: :ok
  def record_compaction(agent_id, utilization_pct) when is_binary(agent_id) do
    telemetry = get_or_create(agent_id)
    put(agent_id, AgentTelemetry.record_compaction(telemetry, utilization_pct))
    persist_event(agent_id, :compaction, %{utilization: utilization_pct})
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
  # Historical queries
  # ===========================================================================

  @doc """
  Load lifetime aggregate metrics from the database for an agent.

  Queries aggregate values (SUM tokens, SUM cost, COUNT turns, etc.) via
  raw SQL rather than replaying every event.

  Returns a map of lifetime metrics or `nil` if the database is unavailable.
  """
  @spec load_lifetime_from_db(String.t()) :: map() | nil
  def load_lifetime_from_db(agent_id) when is_binary(agent_id) do
    with {:ok, repo} <- get_repo() do
      sql = """
      SELECT
        COUNT(*) FILTER (WHERE event_type = 'turn_completed') AS turn_count,
        COALESCE(SUM((data->>'input_tokens')::bigint) FILTER (WHERE event_type = 'turn_completed'), 0) AS total_input,
        COALESCE(SUM((data->>'output_tokens')::bigint) FILTER (WHERE event_type = 'turn_completed'), 0) AS total_output,
        COALESCE(SUM((data->>'cached_tokens')::bigint) FILTER (WHERE event_type = 'turn_completed'), 0) AS total_cached,
        COALESCE(SUM((data->>'cost')::float) FILTER (WHERE event_type = 'turn_completed'), 0.0) AS total_cost,
        COUNT(*) FILTER (WHERE event_type = 'compaction') AS compaction_count
      FROM telemetry_events
      WHERE agent_id = $1
      """

      case apply(repo, :query, [sql, [agent_id]]) do
        {:ok, %{rows: [[tc, ti, to_, tca, tco, cc]]}} ->
          %{
            turn_count: tc,
            lifetime_input_tokens: ti,
            lifetime_output_tokens: to_,
            lifetime_cached_tokens: tca,
            lifetime_cost: tco,
            compaction_count: cc
          }

        _ ->
          nil
      end
    else
      _ -> nil
    end
  rescue
    e ->
      Logger.debug("[Telemetry.Store] Failed to load lifetime for #{agent_id}: #{Exception.message(e)}")
      nil
  end

  @doc """
  Query historical telemetry events for an agent.

  ## Options

  - `:event_type` - filter by event type atom (e.g. `:turn_completed`)
  - `:since` - only events after this `DateTime`
  - `:until` - only events before this `DateTime`
  - `:limit` - max number of events (default 100)
  - `:order` - `:asc` or `:desc` (default `:desc`)
  """
  @spec query_events(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def query_events(agent_id, opts \\ []) when is_binary(agent_id) do
    with {:ok, repo} <- get_repo() do
      limit_val = Keyword.get(opts, :limit, 100)
      order = if Keyword.get(opts, :order, :desc) == :asc, do: "ASC", else: "DESC"

      {where_clauses, params, _idx} = build_query_conditions(agent_id, opts)

      sql = """
      SELECT id, agent_id, event_type, timestamp, data
      FROM telemetry_events
      WHERE #{Enum.join(where_clauses, " AND ")}
      ORDER BY timestamp #{order}
      LIMIT #{limit_val}
      """

      case apply(repo, :query, [sql, params]) do
        {:ok, %{rows: rows}} ->
          events =
            Enum.map(rows, fn [id, aid, etype, ts, data] ->
              %{
                id: id,
                agent_id: aid,
                event_type: etype,
                timestamp: ts,
                data: data || %{}
              }
            end)

          {:ok, events}

        {:error, reason} ->
          {:error, reason}
      end
    else
      _ -> {:ok, []}
    end
  rescue
    e ->
      Logger.debug("[Telemetry.Store] Failed to query events: #{Exception.message(e)}")
      {:ok, []}
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
      nil ->
        # Try to restore lifetime metrics from DB on first access
        base = AgentTelemetry.new(agent_id)

        case load_lifetime_from_db(agent_id) do
          nil ->
            base

          lifetime ->
            %{base |
              lifetime_input_tokens: lifetime[:lifetime_input_tokens] || 0,
              lifetime_output_tokens: lifetime[:lifetime_output_tokens] || 0,
              lifetime_cached_tokens: lifetime[:lifetime_cached_tokens] || 0,
              lifetime_cost: lifetime[:lifetime_cost] || 0.0,
              turn_count: lifetime[:turn_count] || 0,
              compaction_count: lifetime[:compaction_count] || 0
            }
        end

      telemetry ->
        telemetry
    end
  end

  defp build_query_conditions(agent_id, opts) do
    clauses = ["agent_id = $1"]
    params = [agent_id]
    idx = 2

    {clauses, params, idx} =
      case Keyword.get(opts, :event_type) do
        nil -> {clauses, params, idx}
        type -> {clauses ++ ["event_type = $#{idx}"], params ++ [to_string(type)], idx + 1}
      end

    {clauses, params, idx} =
      case Keyword.get(opts, :since) do
        nil -> {clauses, params, idx}
        since -> {clauses ++ ["timestamp >= $#{idx}"], params ++ [since], idx + 1}
      end

    {clauses, params, _idx} =
      case Keyword.get(opts, :until) do
        nil -> {clauses, params, idx}
        until_dt -> {clauses ++ ["timestamp <= $#{idx}"], params ++ [until_dt], idx + 1}
      end

    {clauses, params, idx}
  end

  # Persist a telemetry event asynchronously to Postgres.
  # Errors are logged inside the task body (never swallowed silently).
  defp persist_event(agent_id, event_type, data) do
    Task.start(fn ->
      try do
        persist_event_sync(agent_id, event_type, data)
      rescue
        e ->
          Logger.debug(
            "[Telemetry.Store] Persist failed for #{agent_id}/#{event_type}: #{Exception.message(e)}"
          )
      catch
        kind, reason ->
          Logger.debug(
            "[Telemetry.Store] Persist failed for #{agent_id}/#{event_type}: #{inspect({kind, reason})}"
          )
      end
    end)
  end

  defp persist_event_sync(agent_id, event_type, data) do
    with {:ok, repo} <- get_repo(),
         {:ok, schema_mod} <- get_schema_mod(),
         {:ok, contract_mod} <- get_contract_mod() do
      event = apply(contract_mod, :new, [agent_id, event_type, data])
      attrs = apply(schema_mod, :from_contract, [event])
      changeset = apply(schema_mod, :changeset, [struct(schema_mod), attrs])
      apply(repo, :insert, [changeset])
    end
  end

  defp get_repo do
    mod = Arbor.Persistence.Repo

    if Code.ensure_loaded?(mod) and Process.whereis(mod) != nil do
      {:ok, mod}
    else
      {:error, :unavailable}
    end
  end

  defp get_schema_mod do
    mod = Arbor.Persistence.Schemas.TelemetryEvent
    if Code.ensure_loaded?(mod), do: {:ok, mod}, else: {:error, :unavailable}
  end

  defp get_contract_mod do
    mod = Arbor.Contracts.Agent.TelemetryEvent
    if Code.ensure_loaded?(mod), do: {:ok, mod}, else: {:error, :unavailable}
  end
end
