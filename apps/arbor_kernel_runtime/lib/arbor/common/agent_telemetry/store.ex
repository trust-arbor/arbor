defmodule Arbor.Common.AgentTelemetry.Store do
  @moduledoc """
  ETS-backed store for agent telemetry metrics.

  The GenServer owns the ETS table and serializes mutations. Reads use the
  protected table directly; callers cannot forge or erase telemetry rows.

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
  # Public API
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
    GenServer.call(__MODULE__, {:put, agent_id, telemetry})
  end

  @doc """
  Record a completed LLM turn. Auto-creates telemetry if agent is new.
  Persists the event asynchronously through the configured provider.
  """
  @spec record_turn(String.t(), map()) :: :ok | {:error, term()}
  def record_turn(agent_id, usage) when is_binary(agent_id) and is_map(usage) do
    case GenServer.call(__MODULE__, {:record_turn, agent_id, usage}) do
      :ok ->
        persist_event(agent_id, :turn_completed, usage)
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Record a tool call. Auto-creates telemetry if agent is new.
  Persists the event asynchronously through the configured provider.
  """
  @spec record_tool(String.t(), String.t(), :ok | :error | :gated, non_neg_integer()) ::
          :ok | {:error, term()}
  def record_tool(agent_id, tool_name, result, duration_ms)
      when is_binary(agent_id) and is_binary(tool_name) do
    case GenServer.call(__MODULE__, {:record_tool, agent_id, tool_name, result, duration_ms}) do
      :ok ->
        persist_event(agent_id, :tool_call, %{
          tool_name: tool_name,
          result: result,
          duration_ms: duration_ms
        })

        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Record a sensitivity routing decision. Auto-creates telemetry if agent is new.
  Persists the event asynchronously through the configured provider.
  """
  @spec record_routing(String.t(), :classified | :rerouted | :tokenized | :blocked) ::
          :ok | {:error, term()}
  def record_routing(agent_id, decision) when is_binary(agent_id) do
    case GenServer.call(__MODULE__, {:record_routing, agent_id, decision}) do
      :ok ->
        persist_event(agent_id, :routing_decision, %{decision: decision})
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Record a context compaction event. Auto-creates telemetry if agent is new.
  Persists the event asynchronously through the configured provider.
  """
  @spec record_compaction(String.t(), float()) :: :ok | {:error, term()}
  def record_compaction(agent_id, utilization_pct) when is_binary(agent_id) do
    case GenServer.call(__MODULE__, {:record_compaction, agent_id, utilization_pct}) do
      :ok ->
        persist_event(agent_id, :compaction, %{utilization: utilization_pct})
        :ok

      {:error, _reason} = error ->
        error
    end
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
    GenServer.call(__MODULE__, {:delete, agent_id})
  end

  @doc """
  Reset session-scoped metrics for an agent.
  """
  @spec reset_session(String.t()) :: :ok
  def reset_session(agent_id) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:reset_session, agent_id})
  end

  # ===========================================================================
  # Historical queries
  # ===========================================================================

  @doc """
  Load lifetime aggregate metrics from the configured provider for an agent.

  Returns:
  - `{:ok, map}` when the provider returns lifetime aggregates
  - `nil` when no provider is configured or the provider has no stored row
  - `{:error, reason}` when the provider or query fails

  A load failure is never reported as a missing/zero lifetime. Callers must
  handle `{:error, reason}` visibly instead of hydrating zeros.
  """
  @spec load_lifetime_from_db(String.t()) :: {:ok, map()} | nil | {:error, term()}
  def load_lifetime_from_db(agent_id) when is_binary(agent_id) do
    case persistence_module() do
      nil ->
        nil

      provider ->
        case provider.load_lifetime(agent_id) do
          map when is_map(map) -> {:ok, map}
          nil -> nil
          {:error, reason} -> {:error, reason}
          other -> {:error, other}
        end
    end
  rescue
    e ->
      Logger.warning(
        "[Telemetry.Store] Failed to load lifetime for #{agent_id}: #{Exception.message(e)}"
      )

      {:error, e}
  catch
    kind, reason ->
      Logger.warning(
        "[Telemetry.Store] Failed to load lifetime for #{agent_id}: #{inspect({kind, reason})}"
      )

      {:error, {kind, reason}}
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
  # GenServer
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
        :protected,
        read_concurrency: true
      ])

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, agent_id, telemetry}, _from, state) do
    put_owned(agent_id, telemetry)
    {:reply, :ok, state}
  end

  def handle_call({:record_turn, agent_id, usage}, _from, state) do
    reply_record(state, agent_id, &AgentTelemetry.record_turn(&1, usage))
  end

  def handle_call({:record_tool, agent_id, tool_name, result, duration_ms}, _from, state) do
    reply_record(state, agent_id, &AgentTelemetry.record_tool(&1, tool_name, result, duration_ms))
  end

  def handle_call({:record_routing, agent_id, decision}, _from, state) do
    reply_record(state, agent_id, &AgentTelemetry.record_routing(&1, decision))
  end

  def handle_call({:record_compaction, agent_id, utilization_pct}, _from, state) do
    reply_record(state, agent_id, &AgentTelemetry.record_compaction(&1, utilization_pct))
  end

  def handle_call({:delete, agent_id}, _from, state) do
    :ets.delete(@table, agent_id)
    {:reply, :ok, state}
  end

  def handle_call({:reset_session, agent_id}, _from, state) do
    case get(agent_id) do
      nil -> :ok
      telemetry -> put_owned(agent_id, AgentTelemetry.reset_session(telemetry))
    end

    {:reply, :ok, state}
  end

  # ===========================================================================
  # Private
  # ===========================================================================

  defp reply_record(state, agent_id, fun) when is_function(fun, 1) do
    case get_or_create(agent_id) do
      {:ok, telemetry} ->
        put_owned(agent_id, fun.(telemetry))
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.warning(
          "[Telemetry.Store] Refusing to create a zeroed lifetime for #{agent_id}: #{inspect(reason)}"
        )

        {:reply, {:error, {:lifetime_load_failed, reason}}, state}
    end
  end

  defp get_or_create(agent_id) do
    case get(agent_id) do
      nil ->
        # Try to restore lifetime metrics from the provider on first access
        base = AgentTelemetry.new(agent_id)

        case load_lifetime_from_db(agent_id) do
          nil ->
            {:ok, base}

          {:ok, lifetime} when is_map(lifetime) ->
            {:ok, hydrate_lifetime(base, lifetime)}

          {:error, reason} ->
            {:error, reason}
        end

      telemetry ->
        {:ok, telemetry}
    end
  end

  defp hydrate_lifetime(base, lifetime) when is_map(lifetime) do
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

  defp put_owned(agent_id, telemetry) do
    true = :ets.insert(@table, {agent_id, telemetry})
    :ok
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
