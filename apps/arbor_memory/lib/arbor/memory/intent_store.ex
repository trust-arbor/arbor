defmodule Arbor.Memory.IntentStore do
  @moduledoc """
  Ring buffer storage for agent intents and percepts.

  Maintains a bounded history of recent intents (what the Mind decided to do)
  and percepts (what the Body observed after execution). Uses ETS for fast
  access with a configurable ring buffer size.

  ## Ring Buffer

  Both intents and percepts are stored in bounded ring buffers (default: 100).
  When the buffer is full, the oldest entry is evicted. This keeps memory
  bounded while preserving recent history for context.

  ## Linking

  Percepts are linked to intents via the `intent_id` field on `Percept`.
  Use `get_percept_for_intent/2` to find the outcome of a specific intent.

  ## Signals

  - `{:agent, :intent_formed}` — intent recorded
  - `{:agent, :percept_received}` — percept recorded
  """

  use GenServer

  alias Arbor.Contracts.Memory.Intent
  alias Arbor.Contracts.Memory.Percept
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.Signals

  require Logger

  @ets_table :arbor_memory_intents
  @default_buffer_size 100

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the IntentStore GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Record an intent for an agent.

  The intent is added to the ring buffer. If the buffer is full,
  the oldest intent is evicted.

  ## Examples

      intent = Intent.action(:shell_execute, %{command: "mix test"})
      {:ok, intent} = IntentStore.record_intent("agent_001", intent)
  """
  @spec record_intent(String.t(), Intent.t()) :: {:ok, Intent.t()}
  def record_intent(agent_id, %Intent{} = intent) do
    GenServer.call(server_name(), {:record_intent, agent_id, intent})
  end

  @doc """
  Record a percept for an agent.

  The percept is added to the ring buffer. If it has an `intent_id`,
  it's also indexed for fast intent-to-percept lookup.

  ## Examples

      percept = Percept.success("int_abc", %{exit_code: 0})
      {:ok, percept} = IntentStore.record_percept("agent_001", percept)
  """
  @spec record_percept(String.t(), Percept.t()) :: {:ok, Percept.t()}
  def record_percept(agent_id, %Percept{} = percept) do
    GenServer.call(server_name(), {:record_percept, agent_id, percept})
  end

  @doc """
  Get recent intents for an agent.

  ## Options

  - `:limit` — max intents to return (default: 10)
  - `:type` — filter by intent type (e.g., `:act`, `:think`)
  - `:since` — only intents after this DateTime
  """
  @spec recent_intents(String.t(), keyword()) :: [Intent.t()]
  def recent_intents(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    type = Keyword.get(opts, :type)
    since = Keyword.get(opts, :since)

    get_agent_data(agent_id)
    |> Map.get(:intents, [])
    |> maybe_filter_type(type)
    |> maybe_filter_since(since)
    |> Enum.take(limit)
  end

  @doc """
  Get recent percepts for an agent.

  ## Options

  - `:limit` — max percepts to return (default: 10)
  - `:type` — filter by percept type
  - `:since` — only percepts after this DateTime
  """
  @spec recent_percepts(String.t(), keyword()) :: [Percept.t()]
  def recent_percepts(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    type = Keyword.get(opts, :type)
    since = Keyword.get(opts, :since)

    get_agent_data(agent_id)
    |> Map.get(:percepts, [])
    |> maybe_filter_type(type)
    |> maybe_filter_since(since)
    |> Enum.take(limit)
  end

  @doc """
  Get the percept (outcome) for a specific intent.

  Returns the most recent percept linked to the given intent_id.
  """
  @spec get_percept_for_intent(String.t(), String.t()) ::
          {:ok, Percept.t()} | {:error, :not_found}
  def get_percept_for_intent(agent_id, intent_id) do
    get_agent_data(agent_id)
    |> Map.get(:percepts, [])
    |> Enum.find(&(&1.intent_id == intent_id))
    |> case do
      nil -> {:error, :not_found}
      percept -> {:ok, percept}
    end
  end

  @doc """
  Get pending intents linked to a specific goal.

  Returns intents that have `goal_id` matching and are not completed or failed
  (based on metadata status). Used by the BDI loop to determine if a goal
  needs decomposition.

  ## Examples

      pending = IntentStore.pending_intents_for_goal("agent_001", "goal_abc")
  """
  @spec pending_intents_for_goal(String.t(), String.t()) :: [Intent.t()]
  def pending_intents_for_goal(agent_id, goal_id) do
    data = get_agent_data(agent_id)
    statuses = Map.get(data, :statuses, %{})

    data
    |> Map.get(:intents, [])
    |> Enum.filter(fn intent ->
      intent.goal_id == goal_id and
        not intent_terminal?(intent.id, statuses)
    end)
  end

  defp intent_terminal?(intent_id, statuses) do
    status_info = Map.get(statuses, intent_id, %{})
    Map.get(status_info, :status, :pending) == :completed
  end

  # ============================================================================
  # Peek-Lock-Ack API (BDI Intent Lifecycle)
  # ============================================================================

  @doc """
  Get a specific intent by ID.
  """
  @spec get_intent(String.t(), String.t()) :: {:ok, Intent.t(), map()} | {:error, :not_found}
  def get_intent(agent_id, intent_id) do
    data = get_agent_data(agent_id)

    case Enum.find(data.intents, &(&1.id == intent_id)) do
      nil ->
        {:error, :not_found}

      intent ->
        status_info = get_intent_status(data, intent_id)
        {:ok, intent, status_info}
    end
  end

  @doc """
  Get pending intents sorted by urgency (highest first).

  Returns intents with `:pending` status, optionally limited.
  """
  @spec pending_intentions(String.t(), keyword()) :: [{Intent.t(), map()}]
  def pending_intentions(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    data = get_agent_data(agent_id)
    statuses = Map.get(data, :statuses, %{})

    data.intents
    |> Enum.filter(fn intent ->
      status = Map.get(statuses, intent.id, %{})
      Map.get(status, :status, :pending) == :pending
    end)
    |> Enum.sort_by(& &1.urgency, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn intent ->
      {intent, get_intent_status(data, intent.id)}
    end)
  end

  @doc """
  Lock an intent for execution. Prevents other consumers from picking it up.

  Returns `{:ok, intent}` if successfully locked, `{:error, reason}` otherwise.
  """
  @spec lock_intent(String.t(), String.t()) :: {:ok, Intent.t()} | {:error, term()}
  def lock_intent(agent_id, intent_id) do
    GenServer.call(server_name(), {:lock_intent, agent_id, intent_id})
  end

  @doc """
  Mark an intent as completed. Terminal state.
  """
  @spec complete_intent(String.t(), String.t()) :: :ok | {:error, :not_found}
  def complete_intent(agent_id, intent_id) do
    GenServer.call(server_name(), {:complete_intent, agent_id, intent_id})
  end

  @doc """
  Mark an intent as failed. Increments retry_count.

  Returns the updated retry count.
  """
  @spec fail_intent(String.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, :not_found}
  def fail_intent(agent_id, intent_id, reason \\ "unknown") do
    GenServer.call(server_name(), {:fail_intent, agent_id, intent_id, reason})
  end

  @doc """
  Unlock intents that have been locked longer than `timeout_ms`.

  Returns the count of unlocked intents.
  """
  @spec unlock_stale_intents(String.t(), pos_integer()) :: non_neg_integer()
  def unlock_stale_intents(agent_id, timeout_ms \\ 60_000) do
    GenServer.call(server_name(), {:unlock_stale, agent_id, timeout_ms})
  end

  @doc """
  Export non-completed intents with their status info for Seed capture.

  Returns a list of maps suitable for serialization and later import.
  Each map includes the intent fields plus status/retry_count.

  ## Examples

      intents = IntentStore.export_pending_intents("agent_001")
  """
  @spec export_pending_intents(String.t()) :: [map()]
  def export_pending_intents(agent_id) do
    data = get_agent_data(agent_id)
    statuses = Map.get(data, :statuses, %{})

    data
    |> Map.get(:intents, [])
    |> Enum.reject(fn intent ->
      status_info = Map.get(statuses, intent.id, %{})
      Map.get(status_info, :status, :pending) == :completed
    end)
    |> Enum.map(fn intent ->
      status_info = Map.get(statuses, intent.id, %{status: :pending, retry_count: 0})

      serialize_intent(intent)
      |> Map.put("status", to_string(Map.get(status_info, :status, :pending)))
      |> Map.put("retry_count", Map.get(status_info, :retry_count, 0))
    end)
  end

  @doc """
  Import intents from a previous export, restoring them with their status.

  Used during Seed restore to recover pending work after a restart.
  Already-existing intents (by ID) are skipped.

  ## Examples

      :ok = IntentStore.import_intents("agent_001", exported_intents)
  """
  @spec import_intents(String.t(), [map()]) :: :ok
  def import_intents(agent_id, intent_maps) when is_list(intent_maps) do
    GenServer.call(server_name(), {:import_intents, agent_id, intent_maps})
  end

  @doc """
  Clear all intents and percepts for an agent.
  """
  @spec clear(String.t()) :: :ok
  def clear(agent_id) do
    :ets.delete(@ets_table, agent_id)
    MemoryStore.delete("intents", agent_id)
    :ok
  end

  @doc """
  Reload intents for a specific agent from Postgres into ETS.

  Ensures persisted intents are available after agent restart.
  """
  @spec reload_for_agent(String.t()) :: :ok
  def reload_for_agent(agent_id) do
    if MemoryStore.available?() do
      case MemoryStore.load_all("intents") do
        {:ok, pairs} ->
          pairs
          |> Enum.filter(fn {key, _} -> key == agent_id end)
          |> Enum.each(fn {_key, data} ->
            :ets.insert(@ets_table, {agent_id, deserialize_agent_data(data)})
          end)

        _ ->
          :ok
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    ensure_ets_table()
    buffer_size = Keyword.get(opts, :buffer_size, @default_buffer_size)
    load_from_postgres(buffer_size)
    {:ok, %{buffer_size: buffer_size}}
  end

  @impl true
  def handle_call({:record_intent, agent_id, intent}, _from, state) do
    data = get_agent_data(agent_id)
    intents = [intent | Map.get(data, :intents, [])]
    intents = Enum.take(intents, state.buffer_size)

    updated = Map.put(data, :intents, intents)
    :ets.insert(@ets_table, {agent_id, updated})
    persist_agent_data_async(agent_id, updated)

    MemoryStore.embed_async("intents", agent_id, intent_to_text(intent),
      agent_id: agent_id, type: :intent)

    Signals.emit_intent_formed(agent_id, intent)
    Logger.debug("Intent recorded for #{agent_id}: #{intent.id} (#{intent.type})")

    {:reply, {:ok, intent}, state}
  end

  @impl true
  def handle_call({:record_percept, agent_id, percept}, _from, state) do
    data = get_agent_data(agent_id)
    percepts = [percept | Map.get(data, :percepts, [])]
    percepts = Enum.take(percepts, state.buffer_size)

    updated = Map.put(data, :percepts, percepts)
    :ets.insert(@ets_table, {agent_id, updated})
    persist_agent_data_async(agent_id, updated)

    Signals.emit_percept_received(agent_id, percept)
    Logger.debug("Percept recorded for #{agent_id}: #{percept.id} (#{percept.outcome})")

    {:reply, {:ok, percept}, state}
  end

  @impl true
  def handle_call({:lock_intent, agent_id, intent_id}, _from, state) do
    data = get_agent_data(agent_id)
    statuses = Map.get(data, :statuses, %{})
    current = Map.get(statuses, intent_id, %{status: :pending})

    case current.status do
      :pending ->
        status_info = %{
          status: :locked,
          locked_at: DateTime.utc_now(),
          retry_count: Map.get(current, :retry_count, 0)
        }

        updated_statuses = Map.put(statuses, intent_id, status_info)
        updated = Map.put(data, :statuses, updated_statuses)
        :ets.insert(@ets_table, {agent_id, updated})
        persist_agent_data_async(agent_id, updated)

        intent = Enum.find(data.intents, &(&1.id == intent_id))
        {:reply, {:ok, intent}, state}

      other ->
        {:reply, {:error, {:not_lockable, other}}, state}
    end
  end

  @impl true
  def handle_call({:complete_intent, agent_id, intent_id}, _from, state) do
    data = get_agent_data(agent_id)
    statuses = Map.get(data, :statuses, %{})

    if Enum.any?(data.intents, &(&1.id == intent_id)) do
      status_info = %{
        status: :completed,
        completed_at: DateTime.utc_now(),
        retry_count: Map.get(Map.get(statuses, intent_id, %{}), :retry_count, 0)
      }

      updated_statuses = Map.put(statuses, intent_id, status_info)
      updated = Map.put(data, :statuses, updated_statuses)
      :ets.insert(@ets_table, {agent_id, updated})
      persist_agent_data_async(agent_id, updated)

      {:reply, :ok, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:fail_intent, agent_id, intent_id, reason}, _from, state) do
    data = get_agent_data(agent_id)
    statuses = Map.get(data, :statuses, %{})

    if Enum.any?(data.intents, &(&1.id == intent_id)) do
      current = Map.get(statuses, intent_id, %{})
      retry_count = Map.get(current, :retry_count, 0) + 1

      status_info = %{
        status: :pending,
        failed_at: DateTime.utc_now(),
        last_failure_reason: reason,
        retry_count: retry_count
      }

      updated_statuses = Map.put(statuses, intent_id, status_info)
      updated = Map.put(data, :statuses, updated_statuses)
      :ets.insert(@ets_table, {agent_id, updated})
      persist_agent_data_async(agent_id, updated)

      {:reply, {:ok, retry_count}, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:import_intents, agent_id, intent_maps}, _from, state) do
    data = get_agent_data(agent_id)
    existing_ids = MapSet.new(Enum.map(data.intents, & &1.id))
    statuses = Map.get(data, :statuses, %{})

    {new_intents, new_statuses} =
      Enum.reduce(intent_maps, {[], statuses}, fn intent_map, {intents_acc, statuses_acc} ->
        intent = deserialize_intent(intent_map)

        if MapSet.member?(existing_ids, intent.id) do
          {intents_acc, statuses_acc}
        else
          status = safe_atom(intent_map["status"]) || :pending
          retry_count = intent_map["retry_count"] || 0

          status_info = %{status: status, retry_count: retry_count}
          {[intent | intents_acc], Map.put(statuses_acc, intent.id, status_info)}
        end
      end)

    if new_intents != [] do
      all_intents = new_intents ++ data.intents
      trimmed = Enum.take(all_intents, state.buffer_size)
      updated = %{data | intents: trimmed, statuses: new_statuses}
      :ets.insert(@ets_table, {agent_id, updated})
      persist_agent_data_async(agent_id, updated)

      Logger.info("Imported #{length(new_intents)} intents for #{agent_id}")
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unlock_stale, agent_id, timeout_ms}, _from, state) do
    data = get_agent_data(agent_id)
    statuses = Map.get(data, :statuses, %{})
    now = DateTime.utc_now()

    {updated_statuses, count} =
      Enum.reduce(statuses, {statuses, 0}, fn {id, info}, {acc, n} ->
        if info[:status] == :locked and stale_lock?(info[:locked_at], now, timeout_ms) do
          unlocked = %{info | status: :pending}
          {Map.put(acc, id, Map.delete(unlocked, :locked_at)), n + 1}
        else
          {acc, n}
        end
      end)

    if count > 0 do
      updated = Map.put(data, :statuses, updated_statuses)
      :ets.insert(@ets_table, {agent_id, updated})
      persist_agent_data_async(agent_id, updated)
    end

    {:reply, count, state}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp server_name, do: __MODULE__

  defp ensure_ets_table do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:named_table, :public, :set])
    end
  rescue
    ArgumentError -> :ok
  end

  defp get_agent_data(agent_id) do
    case :ets.lookup(@ets_table, agent_id) do
      [{^agent_id, data}] -> Map.put_new(data, :statuses, %{})
      [] -> %{intents: [], percepts: [], statuses: %{}}
    end
  end

  defp get_intent_status(data, intent_id) do
    statuses = Map.get(data, :statuses, %{})
    Map.get(statuses, intent_id, %{status: :pending, retry_count: 0})
  end

  defp stale_lock?(nil, _now, _timeout_ms), do: true

  defp stale_lock?(locked_at, now, timeout_ms) do
    diff_ms = DateTime.diff(now, locked_at, :millisecond)
    diff_ms > timeout_ms
  end

  defp maybe_filter_type(items, nil), do: items
  defp maybe_filter_type(items, type), do: Enum.filter(items, &(&1.type == type))

  defp maybe_filter_since(items, nil), do: items

  defp maybe_filter_since(items, since) do
    Enum.filter(items, &(DateTime.compare(&1.created_at, since) in [:gt, :eq]))
  end

  # ============================================================================
  # Persistence Helpers
  # ============================================================================

  defp persist_agent_data_async(agent_id, data) do
    serialized = serialize_agent_data(data)
    MemoryStore.persist_async("intents", agent_id, serialized)
  end

  defp serialize_agent_data(data) do
    %{
      "intents" => Enum.map(Map.get(data, :intents, []), &serialize_intent/1),
      "percepts" => Enum.map(Map.get(data, :percepts, []), &serialize_percept/1),
      "statuses" => serialize_statuses(Map.get(data, :statuses, %{}))
    }
  end

  defp serialize_statuses(statuses) do
    Map.new(statuses, fn {id, info} ->
      serialized =
        info
        |> Map.new(fn
          {k, %DateTime{} = dt} -> {to_string(k), DateTime.to_iso8601(dt)}
          {k, v} -> {to_string(k), v}
        end)

      {id, serialized}
    end)
  end

  defp serialize_intent(%Intent{} = intent) do
    %{
      "id" => intent.id,
      "type" => to_string(intent.type),
      "action" => if(intent.action, do: to_string(intent.action)),
      "params" => intent.params,
      "reasoning" => intent.reasoning,
      "goal_id" => intent.goal_id,
      "confidence" => intent.confidence,
      "urgency" => intent.urgency,
      "created_at" => DateTime.to_iso8601(intent.created_at),
      "metadata" => intent.metadata
    }
  end

  defp serialize_percept(%Percept{} = percept) do
    %{
      "id" => percept.id,
      "type" => to_string(percept.type),
      "intent_id" => percept.intent_id,
      "outcome" => to_string(percept.outcome),
      "data" => percept.data,
      "error" => if(percept.error, do: inspect(percept.error)),
      "duration_ms" => percept.duration_ms,
      "created_at" => DateTime.to_iso8601(percept.created_at),
      "metadata" => percept.metadata
    }
  end

  defp deserialize_agent_data(data) when is_map(data) do
    %{
      intents: Enum.map(data["intents"] || [], &deserialize_intent/1),
      percepts: Enum.map(data["percepts"] || [], &deserialize_percept/1),
      statuses: deserialize_statuses(data["statuses"] || %{})
    }
  end

  defp deserialize_statuses(statuses) when is_map(statuses) do
    Map.new(statuses, fn {id, info} ->
      deserialized =
        Map.new(info, fn
          {"status", v} -> {:status, safe_atom(v) || :pending}
          {"locked_at", v} -> {:locked_at, parse_datetime(v)}
          {"completed_at", v} -> {:completed_at, parse_datetime(v)}
          {"failed_at", v} -> {:failed_at, parse_datetime(v)}
          {"retry_count", v} -> {:retry_count, v}
          {"last_failure_reason", v} -> {:last_failure_reason, v}
          {k, v} -> {safe_atom(k) || k, v}
        end)

      {id, deserialized}
    end)
  end

  defp deserialize_statuses(_), do: %{}

  defp deserialize_intent(map) do
    %Intent{
      id: map["id"],
      type: safe_atom(map["type"]) || :act,
      action: safe_atom(map["action"]),
      params: map["params"] || %{},
      reasoning: map["reasoning"],
      goal_id: map["goal_id"],
      confidence: map["confidence"] || 0.5,
      urgency: map["urgency"] || 50,
      created_at: parse_datetime(map["created_at"]),
      metadata: map["metadata"] || %{}
    }
  end

  defp deserialize_percept(map) do
    %Percept{
      id: map["id"],
      type: safe_atom(map["type"]) || :action_result,
      intent_id: map["intent_id"],
      outcome: safe_atom(map["outcome"]) || :unknown,
      data: map["data"] || %{},
      error: map["error"],
      duration_ms: map["duration_ms"],
      created_at: parse_datetime(map["created_at"]),
      metadata: map["metadata"] || %{}
    }
  end

  defp safe_atom(nil), do: nil
  defp safe_atom(val) when is_atom(val), do: val
  defp safe_atom(val) when is_binary(val) do
    String.to_existing_atom(val)
  rescue
    ArgumentError -> val
  end

  defp parse_datetime(nil), do: DateTime.utc_now()
  defp parse_datetime(%DateTime{} = dt), do: dt
  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp intent_to_text(%Intent{} = intent) do
    "Intent: #{intent.type} #{intent.action} #{inspect(intent.params)}"
  end

  defp load_from_postgres(buffer_size) do
    if MemoryStore.available?() do
      case MemoryStore.load_all("intents") do
        {:ok, pairs} ->
          Enum.each(pairs, fn {agent_id, data} ->
            agent_data = deserialize_agent_data(data)
            # Respect buffer size limits
            trimmed = %{
              intents: Enum.take(agent_data.intents, buffer_size),
              percepts: Enum.take(agent_data.percepts, buffer_size)
            }
            :ets.insert(@ets_table, {agent_id, trimmed})
          end)

          Logger.info("IntentStore: loaded #{length(pairs)} agent records from Postgres")

        _ ->
          :ok
      end
    end
  rescue
    e ->
      Logger.warning("IntentStore: failed to load from Postgres: #{inspect(e)}")
  end
end
