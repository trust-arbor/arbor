defmodule Arbor.Common.AgentTelemetry.Store do
  @moduledoc """
  ETS-backed store for agent telemetry metrics.

  The GenServer's only responsibility is to own the ETS table and manage its
  lifecycle. All reads and writes go directly through ETS (which is
  concurrent-safe for single-key operations), avoiding GenServer bottlenecks.

  In-memory updates always succeed. Durable writes go through the configured
  `Arbor.Common.AgentTelemetry.Persistence` provider asynchronously and cannot
  crash callers. Lifetime metrics are restored from that provider on first
  access when one is configured.

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
  alias Arbor.Common.Config
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
  Persists the event asynchronously through the configured provider.
  """
  @spec record_turn(String.t(), map()) :: :ok
  def record_turn(agent_id, usage) when is_binary(agent_id) and is_map(usage) do
    telemetry = get_or_create(agent_id)
    put(agent_id, AgentTelemetry.record_turn(telemetry, usage))
    persist_event(agent_id, :turn_completed, usage)
    :ok
  end

  @doc """
  Record a tool call. Auto-creates telemetry if agent is new.
  Persists the event asynchronously through the configured provider.
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

    :ok
  end

  @doc """
  Record a sensitivity routing decision. Auto-creates telemetry if agent is new.
  Persists the event asynchronously through the configured provider.
  """
  @spec record_routing(String.t(), :classified | :rerouted | :tokenized | :blocked) :: :ok
  def record_routing(agent_id, decision) when is_binary(agent_id) do
    telemetry = get_or_create(agent_id)
    put(agent_id, AgentTelemetry.record_routing(telemetry, decision))
    persist_event(agent_id, :routing_decision, %{decision: decision})
    :ok
  end

  @doc """
  Record a context compaction event. Auto-creates telemetry if agent is new.
  Persists the event asynchronously through the configured provider.
  """
  @spec record_compaction(String.t(), float()) :: :ok
  def record_compaction(agent_id, utilization_pct) when is_binary(agent_id) do
    telemetry = get_or_create(agent_id)
    put(agent_id, AgentTelemetry.record_compaction(telemetry, utilization_pct))
    persist_event(agent_id, :compaction, %{utilization: utilization_pct})
    :ok
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
  Load lifetime aggregate metrics from the configured provider for an agent.

  Returns a map of lifetime metrics or `nil` if no provider is configured or
  the durable store is unavailable.
  """
  @spec load_lifetime_from_db(String.t()) :: map() | nil
  def load_lifetime_from_db(agent_id) when is_binary(agent_id) do
    case persistence_module() do
      nil ->
        nil

      provider ->
        case provider.load_lifetime(agent_id) do
          map when is_map(map) -> map
          _ -> nil
        end
    end
  rescue
    e ->
      Logger.debug(
        "[Telemetry.Store] Failed to load lifetime for #{agent_id}: #{Exception.message(e)}"
      )

      nil
  catch
    kind, reason ->
      Logger.debug(
        "[Telemetry.Store] Failed to load lifetime for #{agent_id}: #{inspect({kind, reason})}"
      )

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

  Returns `{:error, :repo_unavailable}` when no provider is configured and
  `{:error, reason}` when the query itself fails. It deliberately does NOT
  report a failure as an empty result: "no events" and "the query broke" are
  different facts, and conflating them hid a total telemetry blackout on the
  default SQLite adapter for months.
  """
  @spec query_events(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def query_events(agent_id, opts \\ []) when is_binary(agent_id) do
    case persistence_module() do
      nil ->
        {:error, :repo_unavailable}

      provider ->
        case provider.query_events(agent_id, opts) do
          {:ok, events} when is_list(events) ->
            {:ok, events}

          {:error, :repo_unavailable} = err ->
            err

          {:error, reason} ->
            Logger.warning("[Telemetry.Store] Event query failed: #{inspect(reason)}")
            {:error, reason}

          other ->
            Logger.warning("[Telemetry.Store] Event query failed: #{inspect(other)}")
            {:error, other}
        end
    end
  rescue
    e ->
      Logger.warning("[Telemetry.Store] Failed to query events: #{Exception.message(e)}")
      {:error, e}
  catch
    kind, reason ->
      Logger.warning("[Telemetry.Store] Failed to query events: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
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
        # Try to restore lifetime metrics from the provider on first access
        base = AgentTelemetry.new(agent_id)

        case load_lifetime_from_db(agent_id) do
          nil ->
            base

          lifetime ->
            %{
              base
              | lifetime_input_tokens: lifetime[:lifetime_input_tokens] || 0,
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

  # Persist a telemetry event asynchronously through the configured provider.
  # Errors are logged inside the task body (never swallowed silently).
  defp persist_event(agent_id, event_type, data) do
    case persistence_module() do
      nil ->
        :ok

      provider ->
        Task.start(fn ->
          try do
            case provider.persist_event(agent_id, event_type, data) do
              :ok ->
                :ok

              {:error, reason} ->
                Logger.debug(
                  "[Telemetry.Store] Persist failed for #{agent_id}/#{event_type}: #{inspect(reason)}"
                )
            end
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

        :ok
    end
  end

  defp persistence_module do
    case Config.telemetry_persistence_module() do
      mod when is_atom(mod) and not is_nil(mod) -> mod
      _ -> nil
    end
  end
end
