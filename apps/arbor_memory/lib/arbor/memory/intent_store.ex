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

  alias Arbor.Contracts.Memory.{Intent, Percept}
  alias Arbor.Contracts.Security.{Taint, TaintEnvelope, TaintedValue}
  alias Arbor.Memory.{MemoryStore, Provenance, Signals}

  require Logger

  @ets_table :arbor_memory_intents
  @default_buffer_size 100
  @aggregate_version 1
  @max_identifier_bytes 256
  @max_failure_reason_bytes 4_096
  @intent_types [:think, :act, :wait, :reflect, :internal]
  @percept_types [:action_result, :environment, :interrupt, :error, :timeout]
  @percept_outcomes [:success, :failure, :partial, :blocked, :interrupted]
  @intent_statuses [:pending, :locked, :completed]
  @aggregate_fields ~w(version intents percepts statuses)
  @item_fields ~w(payload provenance)
  @intent_payload_fields ~w(
    id type action params reasoning goal_id confidence urgency created_at metadata capability op target
  )
  @percept_payload_fields ~w(
    id type intent_id outcome data error duration_ms created_at metadata summary
  )
  @status_fields ~w(status locked_at completed_at failed_at retry_count last_failure_reason)
  @status_payload_fields ["intent_id" | @status_fields]
  @import_fields @intent_payload_fields ++ ~w(status retry_count)

  @type provenance_status :: :verified | :legacy_unlabeled | :invalid_durable_provenance
  @type tainted_item :: {TaintedValue.t(), provenance_status()}

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
  @spec record_intent(String.t(), Intent.t()) ::
          {:ok, Intent.t()} | {:error, :invalid_request | :invalid_payload | :store_unavailable}
  def record_intent(agent_id, %Intent{} = intent) do
    record_with_fallback(:intent, agent_id, intent)
  end

  def record_intent(_agent_id, _intent), do: {:error, :invalid_request}

  @doc "Records an intent with an exact caller-supplied taint label."
  @spec record_intent_tainted(String.t(), Intent.t(), Taint.t()) ::
          {:ok, Intent.t()}
          | {:error, :invalid_request | :invalid_provenance | :store_unavailable}
  def record_intent_tainted(agent_id, %Intent{} = intent, taint) do
    record_tainted(:intent, agent_id, intent, taint)
  end

  def record_intent_tainted(_agent_id, _intent, _taint), do: {:error, :invalid_request}

  @doc """
  Record a percept for an agent.

  The percept is added to the ring buffer. If it has an `intent_id`,
  it's also indexed for fast intent-to-percept lookup.

  ## Examples

      percept = Percept.success("int_abc", %{exit_code: 0})
      {:ok, percept} = IntentStore.record_percept("agent_001", percept)
  """
  @spec record_percept(String.t(), Percept.t()) ::
          {:ok, Percept.t()} | {:error, :invalid_request | :invalid_payload | :store_unavailable}
  def record_percept(agent_id, %Percept{} = percept) do
    record_with_fallback(:percept, agent_id, percept)
  end

  def record_percept(_agent_id, _percept), do: {:error, :invalid_request}

  @doc "Records a percept with an exact caller-supplied taint label."
  @spec record_percept_tainted(String.t(), Percept.t(), Taint.t()) ::
          {:ok, Percept.t()}
          | {:error, :invalid_request | :invalid_provenance | :store_unavailable}
  def record_percept_tainted(agent_id, %Percept{} = percept, taint) do
    record_tainted(:percept, agent_id, percept, taint)
  end

  def record_percept_tainted(_agent_id, _percept, _taint), do: {:error, :invalid_request}

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

  @doc "Returns recent intents with item-specific taint and provenance status."
  @spec recent_intents_tainted(String.t(), keyword()) ::
          {:ok, [tainted_item()]} | {:error, :invalid_request}
  def recent_intents_tainted(agent_id, opts \\ []) do
    with :ok <- validate_reader_request(agent_id, opts) do
      items =
        agent_id
        |> recent_intents(opts)
        |> Enum.map(&tainted_item(:intent, agent_id, &1))

      {:ok, items}
    end
  rescue
    _ -> {:error, :invalid_request}
  catch
    _, _ -> {:error, :invalid_request}
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

  @doc "Returns recent percepts with item-specific taint and provenance status."
  @spec recent_percepts_tainted(String.t(), keyword()) ::
          {:ok, [tainted_item()]} | {:error, :invalid_request}
  def recent_percepts_tainted(agent_id, opts \\ []) do
    with :ok <- validate_reader_request(agent_id, opts) do
      items =
        agent_id
        |> recent_percepts(opts)
        |> Enum.map(&tainted_item(:percept, agent_id, &1))

      {:ok, items}
    end
  rescue
    _ -> {:error, :invalid_request}
  catch
    _, _ -> {:error, :invalid_request}
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
    max_retries = Keyword.get(opts, :max_retries, 5)
    data = get_agent_data(agent_id)
    statuses = Map.get(data, :statuses, %{})

    data.intents
    |> Enum.filter(fn intent ->
      status = Map.get(statuses, intent.id, %{})

      Map.get(status, :status, :pending) == :pending and
        Map.get(status, :retry_count, 0) < max_retries
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
    with :ok <- validate_identifier(agent_id),
         :ok <- validate_identifier(intent_id) do
      safe_server_call({:lock_intent, agent_id, intent_id})
    else
      _ -> {:error, :invalid_request}
    end
  end

  @doc """
  Mark an intent as completed. Terminal state.
  """
  @spec complete_intent(String.t(), String.t()) ::
          :ok | {:error, :invalid_request | :not_found | :store_unavailable}
  def complete_intent(agent_id, intent_id) do
    with :ok <- validate_identifier(agent_id),
         :ok <- validate_identifier(intent_id) do
      safe_server_call({:complete_intent, agent_id, intent_id})
    else
      _ -> {:error, :invalid_request}
    end
  end

  @doc """
  Mark an intent as failed. Increments retry_count.

  Returns the updated retry count.
  """
  @spec fail_intent(String.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()}
          | {:error, :invalid_request | :not_found | :store_unavailable}
  def fail_intent(agent_id, intent_id, reason \\ "unknown")

  def fail_intent(agent_id, intent_id, reason)
      when is_binary(reason) and byte_size(reason) <= @max_failure_reason_bytes do
    fail_with_taint(agent_id, intent_id, reason, TaintEnvelope.missing_fallback(), :raw)
  end

  def fail_intent(_agent_id, _intent_id, _reason), do: {:error, :invalid_request}

  @doc "Marks an intent as failed with provenance for the exact failure reason."
  @spec fail_intent_tainted(String.t(), String.t(), String.t(), Taint.t()) ::
          {:ok, non_neg_integer()}
          | {:error, :invalid_request | :invalid_provenance | :not_found | :store_unavailable}
  def fail_intent_tainted(agent_id, intent_id, reason, taint)
      when is_binary(reason) and byte_size(reason) <= @max_failure_reason_bytes do
    fail_with_taint(agent_id, intent_id, reason, taint, :tainted)
  end

  def fail_intent_tainted(_agent_id, _intent_id, _reason, _taint),
    do: {:error, :invalid_request}

  @doc """
  Unlock intents that have been locked longer than `timeout_ms`.

  Returns the count of unlocked intents.
  """
  @spec unlock_stale_intents(String.t(), pos_integer()) ::
          non_neg_integer() | {:error, :invalid_request | :store_unavailable}
  def unlock_stale_intents(agent_id, timeout_ms \\ 60_000)

  def unlock_stale_intents(agent_id, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    with :ok <- validate_identifier(agent_id) do
      safe_server_call({:unlock_stale, agent_id, timeout_ms})
    else
      _ -> {:error, :invalid_request}
    end
  end

  def unlock_stale_intents(_agent_id, _timeout_ms), do: {:error, :invalid_request}

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
  @spec import_intents(String.t(), [map()]) :: :ok | {:error, atom()}
  def import_intents(agent_id, intent_maps) when is_list(intent_maps) do
    with :ok <- validate_identifier(agent_id),
         true <- proper_bounded_list?(intent_maps, Taint.max_join_inputs()),
         {:ok, prepared} <- prepare_imports(intent_maps) do
      safe_server_call({:import_intents, agent_id, prepared})
    else
      _ -> {:error, :invalid_request}
    end
  end

  def import_intents(_agent_id, _intent_maps), do: {:error, :invalid_request}

  @doc """
  Prune pending intents older than `max_age_ms` milliseconds.

  Removes intents (and their status entries) that are still in `:pending` state
  but were created longer ago than `max_age_ms`. Useful for clearing accumulated
  idle intents that were never executed.

  Returns the count of pruned intents.

  ## Examples

      count = IntentStore.prune_stale("agent_001", :timer.hours(1))
  """
  @spec prune_stale(String.t(), pos_integer()) ::
          non_neg_integer() | {:error, :invalid_request | :store_unavailable}
  def prune_stale(agent_id, max_age_ms) when is_integer(max_age_ms) and max_age_ms > 0 do
    with :ok <- validate_identifier(agent_id) do
      safe_server_call({:prune_stale, agent_id, max_age_ms})
    else
      _ -> {:error, :invalid_request}
    end
  end

  def prune_stale(_agent_id, _max_age_ms), do: {:error, :invalid_request}

  @doc """
  Clear all intents and percepts for an agent.
  """
  @spec clear(String.t()) :: :ok
  def clear(agent_id) do
    case safe_server_call({:clear, agent_id}) do
      :ok -> :ok
      _ -> :ok
    end
  end

  @doc """
  Reload intents for a specific agent from Postgres into ETS.

  Ensures persisted intents are available after agent restart.
  """
  @spec reload_for_agent(String.t()) :: :ok
  def reload_for_agent(agent_id) do
    case validate_identifier(agent_id) do
      :ok ->
        case safe_server_call({:reload, agent_id}) do
          :ok -> :ok
          _ -> :ok
        end

      {:error, _reason} ->
        :ok
    end
  rescue
    _ ->
      Logger.warning("IntentStore reload failed")
      :ok
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    ensure_ets_table()
    buffer_size = normalize_buffer_size(Keyword.get(opts, :buffer_size, @default_buffer_size))
    load_from_postgres(buffer_size)

    {:ok,
     %{
       buffer_size: buffer_size,
       embedding_fun: Keyword.get(opts, :embedding_fun, &MemoryStore.embed_async/4)
     }}
  end

  @impl true
  def handle_call({:record_prepared, domain, agent_id, prepared}, _from, state)
      when domain in [:intent, :percept] do
    original = get_agent_data(agent_id)
    candidate = put_prepared_item(original, domain, prepared.value, state.buffer_size)
    overrides = %{{domain, prepared.id} => prepared.taint}

    case commit_candidate_data(
           agent_id,
           original,
           candidate,
           overrides,
           Map.keys(overrides)
         ) do
      :ok ->
        emit_record_effects(state, domain, agent_id, prepared)
        {:reply, {:ok, prepared.value}, state}

      {:error, _reason} ->
        {:reply, {:error, :store_unavailable}, state}
    end
  rescue
    _ -> {:reply, {:error, :store_unavailable}, state}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, state}
  end

  @impl true
  def handle_call({:clear, agent_id}, _from, state) do
    data = get_agent_data(agent_id)
    true = :ets.delete(@ets_table, agent_id)
    delete_item_provenance(agent_id, data)
    MemoryStore.delete("intents", agent_id)
    {:reply, :ok, state}
  rescue
    _ -> {:reply, :ok, state}
  catch
    _, _ -> {:reply, :ok, state}
  end

  @impl true
  def handle_call({:reload, agent_id}, _from, state) do
    current = get_agent_data(agent_id)

    reply =
      case MemoryStore.load_tainted_with_status("intents", agent_id) do
        {:ok, %TaintedValue{value: persisted, taint: outer_taint}, outer_status} ->
          case decode_durable_aggregate(
                 persisted,
                 outer_taint,
                 outer_status,
                 state.buffer_size
               ) do
            {:ok, decoded, _status} ->
              restore_decoded_agent(agent_id, current, decoded)

            {:error, _reason} ->
              clear_live_agent(agent_id, current)
              Logger.warning("IntentStore rejected corrupt durable aggregate")
              :ok
          end

        {:error, :not_found} ->
          :ok

        {:error, _reason} ->
          Logger.warning("IntentStore durable reload failed")
          :ok

        _ ->
          Logger.warning("IntentStore durable reload failed")
          :ok
      end

    {:reply, reply, state}
  rescue
    _ ->
      Logger.warning("IntentStore durable reload failed")
      {:reply, :ok, state}
  catch
    _, _ ->
      Logger.warning("IntentStore durable reload failed")
      {:reply, :ok, state}
  end

  @impl true
  def handle_call({:lock_intent, agent_id, intent_id}, _from, state) do
    data = get_agent_data(agent_id)
    statuses = Map.get(data, :statuses, %{})
    current = Map.get(statuses, intent_id, %{status: :pending})
    intent = Enum.find(data.intents, &(&1.id == intent_id))

    case {intent, current.status} do
      {nil, _status} ->
        {:reply, {:error, :not_found}, state}

      {%Intent{} = intent, :pending} ->
        status_info = %{
          status: :locked,
          locked_at: DateTime.utc_now(),
          retry_count: Map.get(current, :retry_count, 0)
        }

        updated_statuses = Map.put(statuses, intent_id, status_info)
        updated = Map.put(data, :statuses, updated_statuses)

        case commit_status_data(agent_id, data, updated, [intent_id], %{
               {:status, intent_id} => :inherit_item
             }) do
          :ok -> {:reply, {:ok, intent}, state}
          {:error, _reason} -> {:reply, {:error, :store_unavailable}, state}
        end

      {_intent, _other} ->
        {:reply, {:error, :not_lockable}, state}
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

      case commit_status_data(agent_id, data, updated, [intent_id], %{
             {:status, intent_id} => :inherit_item
           }) do
        :ok -> {:reply, :ok, state}
        {:error, _reason} -> {:reply, {:error, :store_unavailable}, state}
      end
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:fail_intent, agent_id, intent_id, reason, reason_taint}, _from, state) do
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

      case commit_status_data(agent_id, data, updated, [intent_id], %{
             {:status, intent_id} => reason_taint
           }) do
        :ok -> {:reply, {:ok, retry_count}, state}
        {:error, _reason} -> {:reply, {:error, :store_unavailable}, state}
      end
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:import_intents, agent_id, prepared_items}, _from, state) do
    data = get_agent_data(agent_id)
    initial_ids = MapSet.new(Enum.map(data.intents, & &1.id))

    {new_items, new_statuses, _seen_ids} =
      Enum.reduce(prepared_items, {[], data.statuses, initial_ids}, fn prepared,
                                                                       {items, statuses, seen} ->
        if MapSet.member?(seen, prepared.id) do
          {items, statuses, seen}
        else
          {
            [prepared | items],
            Map.put(statuses, prepared.id, prepared.status),
            MapSet.put(seen, prepared.id)
          }
        end
      end)

    if new_items != [] do
      all_intents = Enum.map(new_items, & &1.value) ++ data.intents
      trimmed = Enum.take(all_intents, state.buffer_size)
      updated = %{data | intents: trimmed, statuses: new_statuses}
      retained_ids = MapSet.new(Enum.map(trimmed, & &1.id))

      overrides =
        new_items
        |> Enum.filter(&MapSet.member?(retained_ids, &1.id))
        |> Map.new(&{{:intent, &1.id}, &1.taint})

      status_overrides =
        new_items
        |> Enum.filter(&MapSet.member?(retained_ids, &1.id))
        |> Map.new(&{{:status, &1.id}, &1.taint})

      overrides = Map.merge(overrides, status_overrides)

      protected_keys = Enum.map(new_items, &{:intent, &1.id})

      case commit_candidate_data(agent_id, data, updated, overrides, protected_keys) do
        :ok ->
          Logger.info("IntentStore imported intents", count: length(new_items))
          {:reply, :ok, state}

        {:error, _reason} ->
          {:reply, {:error, :store_unavailable}, state}
      end
    else
      {:reply, :ok, state}
    end
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

      updated_ids =
        for {id, info} <- updated_statuses,
            Map.get(statuses, id) != info,
            do: id

      case commit_status_data(agent_id, data, updated, updated_ids, %{}) do
        :ok -> {:reply, count, state}
        {:error, _reason} -> {:reply, {:error, :store_unavailable}, state}
      end
    else
      {:reply, count, state}
    end
  end

  @impl true
  def handle_call({:prune_stale, agent_id, max_age_ms}, _from, state) do
    data = get_agent_data(agent_id)
    statuses = Map.get(data, :statuses, %{})
    now = DateTime.utc_now()

    {surviving_intents, pruned_ids} =
      Enum.reduce(data.intents, {[], []}, fn intent, {keep, pruned} ->
        age_ms = DateTime.diff(now, intent.created_at, :millisecond)
        status = Map.get(Map.get(statuses, intent.id, %{}), :status, :pending)

        if status == :pending and age_ms > max_age_ms do
          {keep, [intent.id | pruned]}
        else
          {[intent | keep], pruned}
        end
      end)

    count = length(pruned_ids)

    if count > 0 do
      cleaned_statuses = Map.drop(statuses, pruned_ids)
      updated = %{data | intents: Enum.reverse(surviving_intents), statuses: cleaned_statuses}

      case commit_current_data(agent_id, data, updated) do
        :ok ->
          Logger.info("IntentStore pruned stale intents", count: count)
          {:reply, count, state}

        {:error, _reason} ->
          {:reply, {:error, :store_unavailable}, state}
      end
    else
      {:reply, count, state}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp server_name, do: __MODULE__

  defp normalize_buffer_size(value) when is_integer(value) and value > 0,
    do: min(value, Taint.max_join_inputs())

  defp normalize_buffer_size(_value), do: @default_buffer_size

  defp record_with_fallback(domain, agent_id, item) do
    case prepare_record(domain, agent_id, item, TaintEnvelope.missing_fallback()) do
      {:ok, prepared} -> safe_server_call({:record_prepared, domain, agent_id, prepared})
      {:error, :invalid_request} -> {:error, :invalid_request}
      {:error, _reason} -> {:error, :invalid_payload}
    end
  end

  defp record_tainted(domain, agent_id, item, taint) do
    case prepare_record(domain, agent_id, item, taint) do
      {:ok, prepared} -> safe_server_call({:record_prepared, domain, agent_id, prepared})
      {:error, :invalid_request} -> {:error, :invalid_request}
      {:error, _reason} -> {:error, :invalid_provenance}
    end
  end

  defp prepare_record(domain, agent_id, item, taint) do
    with :ok <- validate_identifier(agent_id),
         :ok <- validate_identifier(item.id),
         {:ok, taint} <- Taint.canonicalize(taint),
         {:ok, encoded} <- encode_item(domain, item, taint) do
      {:ok, Map.put(encoded, :value, item)}
    else
      {:error, :invalid_identifier} -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  catch
    _, _ -> {:error, :invalid_request}
  end

  defp fail_with_taint(agent_id, intent_id, reason, taint, mode) do
    with :ok <- validate_identifier(agent_id),
         :ok <- validate_identifier(intent_id),
         true <- String.valid?(reason),
         {:ok, taint} <- Taint.canonicalize(taint),
         {:ok, _envelope} <- TaintEnvelope.new(reason, taint) do
      safe_server_call({:fail_intent, agent_id, intent_id, reason, taint})
    else
      {:error, :invalid_identifier} -> {:error, :invalid_request}
      false -> {:error, :invalid_request}
      {:error, _reason} when mode == :tainted -> {:error, :invalid_provenance}
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  catch
    _, _ -> {:error, :invalid_request}
  end

  defp prepare_imports(intent_maps) do
    Enum.reduce_while(intent_maps, {:ok, []}, fn intent_map, {:ok, acc} ->
      case prepare_import(intent_map) do
        {:ok, prepared} -> {:cont, {:ok, [prepared | acc]}}
        {:error, _reason} -> {:halt, {:error, :invalid_import}}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      {:error, _reason} = error -> error
    end
  rescue
    _ -> {:error, :invalid_import}
  catch
    _, _ -> {:error, :invalid_import}
  end

  defp prepare_import(intent_map) when is_map(intent_map) do
    intent_payload = Map.take(intent_map, @intent_payload_fields)

    with :ok <- exact_keys(intent_map, @import_fields),
         {:ok, intent} <- deserialize_intent_exact(intent_payload),
         {:ok, status} <- decode_enum(intent_map["status"], @intent_statuses),
         retry_count <- intent_map["retry_count"],
         true <- is_integer(retry_count) and retry_count >= 0,
         {:ok, encoded} <- encode_item(:intent, intent, TaintEnvelope.missing_fallback()) do
      {:ok,
       encoded
       |> Map.put(:value, intent)
       |> Map.put(:status, %{status: status, retry_count: retry_count})}
    else
      _ -> {:error, :invalid_import}
    end
  end

  defp prepare_import(_intent_map), do: {:error, :invalid_import}

  defp safe_server_call(message) do
    case Process.whereis(server_name()) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, message)
        catch
          :exit, _reason -> {:error, :store_unavailable}
        end

      nil ->
        {:error, :store_unavailable}
    end
  end

  defp validate_reader_request(agent_id, opts) do
    with :ok <- validate_identifier(agent_id),
         true <- is_list(opts) and Keyword.keyword?(opts),
         limit when is_integer(limit) and limit >= 0 <- Keyword.get(opts, :limit, 10),
         type <- Keyword.get(opts, :type),
         true <- is_nil(type) or is_atom(type),
         since <- Keyword.get(opts, :since),
         true <- is_nil(since) or match?(%DateTime{}, since) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  catch
    _, _ -> {:error, :invalid_request}
  end

  defp validate_identifier(value) when is_binary(value) do
    if byte_size(value) <= @max_identifier_bytes and String.valid?(value) and
         String.trim(value) != "" do
      :ok
    else
      {:error, :invalid_identifier}
    end
  end

  defp validate_identifier(_value), do: {:error, :invalid_identifier}

  defp tainted_item(domain, agent_id, item) do
    with {:ok, payload} <- item_payload(domain, item),
         {:ok, taint, status} <- Provenance.resolve(domain, agent_id, item.id, payload) do
      {TaintedValue.wrap(item, taint), normalize_provenance_status(taint, status)}
    else
      _ ->
        taint = TaintEnvelope.invalid_fallback()
        {TaintedValue.wrap(item, taint), :invalid_durable_provenance}
    end
  rescue
    _ ->
      taint = TaintEnvelope.invalid_fallback()
      {TaintedValue.wrap(item, taint), :invalid_durable_provenance}
  catch
    _, _ ->
      taint = TaintEnvelope.invalid_fallback()
      {TaintedValue.wrap(item, taint), :invalid_durable_provenance}
  end

  defp normalize_provenance_status(taint, status) do
    cond do
      taint == TaintEnvelope.invalid_fallback() ->
        :invalid_durable_provenance

      taint == TaintEnvelope.missing_fallback() ->
        :legacy_unlabeled

      status in [:verified, :legacy_unlabeled, :invalid_durable_provenance] ->
        status

      true ->
        :invalid_durable_provenance
    end
  end

  defp put_prepared_item(data, :intent, %Intent{} = intent, buffer_size) do
    intents = [intent | Enum.reject(data.intents, &(&1.id == intent.id))]
    intents = Enum.take(intents, buffer_size)

    retain_intent_state(%{data | intents: intents}, intents)
  end

  defp put_prepared_item(data, :percept, %Percept{} = percept, buffer_size) do
    percepts = [percept | Enum.reject(data.percepts, &(&1.id == percept.id))]
    %{data | percepts: Enum.take(percepts, buffer_size)}
  end

  defp commit_encoded_aggregate(agent_id, original, encoded) do
    with :ok <- put_item_provenance(agent_id, encoded.items),
         :ok <-
           MemoryStore.persist("intents", agent_id, encoded.persisted,
             taint: encoded.aggregate_taint
           ) do
      true = :ets.insert(@ets_table, {agent_id, encoded.data})
      delete_removed_provenance(agent_id, original, encoded.data)
      :ok
    else
      _ -> {:error, :commit_failed}
    end
  rescue
    _ -> {:error, :commit_failed}
  catch
    _, _ -> {:error, :commit_failed}
  end

  defp commit_current_data(agent_id, original, candidate) do
    commit_candidate_data(agent_id, original, candidate, %{}, [])
  end

  defp commit_status_data(agent_id, original, candidate, intent_ids, overrides) do
    protected_keys = Enum.map(intent_ids, &{:intent, &1})
    commit_candidate_data(agent_id, original, candidate, overrides, protected_keys)
  end

  defp commit_candidate_data(agent_id, original, candidate, overrides, protected_keys) do
    if candidate.intents == [] and candidate.percepts == [] do
      MemoryStore.delete("intents", agent_id)
      true = :ets.insert(@ets_table, {agent_id, empty_agent_data()})
      delete_removed_provenance(agent_id, original, empty_agent_data())
      :ok
    else
      with {:ok, encoded} <-
             encode_bounded_aggregate(
               agent_id,
               candidate,
               overrides,
               MapSet.new(protected_keys)
             ) do
        commit_encoded_aggregate(agent_id, original, encoded)
      end
    end
  rescue
    _ -> {:error, :commit_failed}
  catch
    _, _ -> {:error, :commit_failed}
  end

  defp encode_bounded_aggregate(agent_id, data, overrides, protected_keys) do
    case encode_aggregate(agent_id, data, overrides) do
      {:ok, encoded} ->
        {:ok, encoded}

      {:error, reason}
      when reason in [
             :live_provenance_missing,
             :invalid_live_provenance,
             :live_status_provenance_missing,
             :invalid_live_status_provenance
           ] ->
        {:error, :provenance_unavailable}

      {:error, _reason} ->
        case drop_oldest_unprotected(data, protected_keys) do
          {:ok, smaller} ->
            encode_bounded_aggregate(agent_id, smaller, overrides, protected_keys)

          {:error, _reason} ->
            {:error, :aggregate_limit_exceeded}
        end
    end
  end

  defp drop_oldest_unprotected(data, protected_keys) do
    candidates =
      []
      |> maybe_add_oldest_candidate(:intent, data.intents, protected_keys)
      |> maybe_add_oldest_candidate(:percept, data.percepts, protected_keys)

    case Enum.min_by(candidates, &candidate_time/1, fn -> nil end) do
      %{domain: :intent} ->
        intents = Enum.drop(data.intents, -1)
        {:ok, retain_intent_state(%{data | intents: intents}, intents)}

      %{domain: :percept} ->
        {:ok, %{data | percepts: Enum.drop(data.percepts, -1)}}

      nil ->
        {:error, :no_evictable_item}
    end
  rescue
    _ -> {:error, :no_evictable_item}
  catch
    _, _ -> {:error, :no_evictable_item}
  end

  defp maybe_add_oldest_candidate(candidates, _domain, [], _protected_keys), do: candidates

  defp maybe_add_oldest_candidate(candidates, domain, items, protected_keys) do
    item = List.last(items)

    if MapSet.member?(protected_keys, {domain, item.id}) do
      candidates
    else
      [%{domain: domain, item: item} | candidates]
    end
  end

  defp candidate_time(%{item: %{created_at: %DateTime{} = created_at}}),
    do: DateTime.to_unix(created_at, :microsecond)

  defp candidate_time(_candidate), do: 0

  defp restore_decoded_agent(agent_id, current, decoded) do
    true = :ets.delete(@ets_table, agent_id)
    delete_item_provenance(agent_id, current)

    with :ok <- put_item_provenance(agent_id, decoded.items) do
      true = :ets.insert(@ets_table, {agent_id, decoded.data})
      :ok
    else
      _ ->
        delete_item_provenance(agent_id, decoded.data)
        {:error, :provenance_unavailable}
    end
  end

  defp clear_live_agent(agent_id, current) do
    true = :ets.delete(@ets_table, agent_id)
    delete_item_provenance(agent_id, current)
    :ok
  end

  defp put_item_provenance(agent_id, items) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case Provenance.put(item.domain, agent_id, item.id, item.payload, item.taint) do
        :ok -> {:cont, :ok}
        _ -> {:halt, {:error, :provenance_unavailable}}
      end
    end)
  end

  defp delete_removed_provenance(agent_id, original, current) do
    delete_removed_domain_provenance(
      :intent,
      agent_id,
      original.intents,
      current.intents
    )

    delete_removed_domain_provenance(
      :percept,
      agent_id,
      original.percepts,
      current.percepts
    )
  end

  defp delete_removed_domain_provenance(domain, agent_id, old_items, current_items) do
    current_ids = MapSet.new(Enum.map(current_items, & &1.id))

    Enum.each(old_items, fn item ->
      if not MapSet.member?(current_ids, item.id) do
        Provenance.delete(domain, agent_id, item.id)
      end
    end)
  end

  defp delete_item_provenance(agent_id, data) do
    Enum.each(data.intents, &Provenance.delete(:intent, agent_id, &1.id))
    Enum.each(data.percepts, &Provenance.delete(:percept, agent_id, &1.id))
  end

  defp emit_record_effects(state, :intent, agent_id, prepared) do
    state.embedding_fun.(
      "intents",
      "#{agent_id}:#{prepared.id}",
      intent_to_text(prepared.value),
      agent_id: agent_id,
      type: :intent,
      taint: prepared.taint
    )

    Signals.emit_intent_formed(agent_id, prepared.value)
    Logger.debug("Intent recorded")
    state
  end

  defp emit_record_effects(state, :percept, agent_id, prepared) do
    Signals.emit_percept_received(agent_id, prepared.value)
    Logger.debug("Percept recorded")
    state
  end

  defp ensure_ets_table do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:named_table, :public, :set])
    end
  rescue
    ArgumentError -> :ok
  end

  defp get_agent_data(agent_id) do
    case :ets.lookup(@ets_table, agent_id) do
      [{^agent_id, data}] ->
        data
        |> Map.put_new(:statuses, %{})
        |> Map.put_new(:status_taints, %{})

      [] ->
        empty_agent_data()
    end
  end

  defp empty_agent_data,
    do: %{intents: [], percepts: [], statuses: %{}, status_taints: %{}}

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

  defp encode_item(domain, item, taint) when domain in [:intent, :percept] do
    with {:ok, payload} <- item_payload(domain, item),
         {:ok, envelope} <- TaintEnvelope.new(payload, taint),
         {:ok, provenance} <- TaintEnvelope.to_map(envelope) do
      {:ok,
       %{
         domain: domain,
         id: item.id,
         payload: payload,
         taint: envelope.taint,
         persisted: %{"payload" => payload, "provenance" => provenance}
       }}
    end
  end

  defp encode_item(_domain, _item, _taint), do: {:error, :invalid_item}

  defp item_payload(:intent, %Intent{} = intent) do
    intent
    |> serialize_intent()
    |> canonical_payload()
  end

  defp item_payload(:percept, %Percept{} = percept) do
    percept
    |> serialize_percept()
    |> canonical_payload()
  end

  defp item_payload(_domain, _item), do: {:error, :invalid_item}

  defp canonical_payload(payload) do
    with {:ok, json} <- TaintEnvelope.canonical_json(payload),
         {:ok, decoded} <- Jason.decode(json) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_payload}
    end
  rescue
    _ -> {:error, :invalid_payload}
  catch
    _, _ -> {:error, :invalid_payload}
  end

  defp encode_aggregate(agent_id, data, overrides) do
    with {:ok, intents} <- encode_live_items(:intent, agent_id, data.intents, overrides),
         {:ok, percepts} <- encode_live_items(:percept, agent_id, data.percepts, overrides),
         statuses <- retain_statuses(data.statuses, data.intents),
         {:ok, encoded_statuses} <-
           encode_live_statuses(statuses, data.status_taints, intents, overrides),
         labels when labels != [] <-
           Enum.map(intents ++ percepts ++ encoded_statuses, & &1.taint),
         {:ok, aggregate_taint} <- Taint.join_many(labels),
         persisted <- %{
           "version" => @aggregate_version,
           "intents" => Enum.map(intents, & &1.persisted),
           "percepts" => Enum.map(percepts, & &1.persisted),
           "statuses" => Map.new(encoded_statuses, &{&1.id, &1.persisted})
         },
         {:ok, persisted} <- canonical_payload(persisted),
         {:ok, _outer} <- TaintEnvelope.new(persisted, aggregate_taint) do
      {:ok,
       %{
         data: %{
           data
           | statuses: statuses,
             status_taints: Map.new(encoded_statuses, &{&1.id, &1.taint})
         },
         persisted: persisted,
         aggregate_taint: aggregate_taint,
         items: intents ++ percepts,
         status_items: encoded_statuses
       }}
    else
      [] -> {:error, :empty_aggregate}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_aggregate}
    end
  rescue
    _ -> {:error, :invalid_aggregate}
  catch
    _, _ -> {:error, :invalid_aggregate}
  end

  defp encode_live_items(domain, agent_id, items, overrides) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      with {:ok, payload} <- item_payload(domain, item),
           {:ok, taint} <- resolve_item_taint(domain, agent_id, item.id, payload, overrides),
           {:ok, encoded} <- encode_item(domain, item, taint) do
        {:cont, {:ok, [encoded | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        _ -> {:halt, {:error, :invalid_item}}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      {:error, _reason} = error -> error
    end
  end

  defp encode_live_statuses(statuses, status_taints, intents, overrides) do
    intent_taints = Map.new(intents, &{&1.id, &1.taint})

    statuses
    |> Enum.sort_by(fn {id, _info} -> id end)
    |> Enum.reduce_while({:ok, []}, fn {id, info}, {:ok, acc} ->
      with {:ok, payload} <- status_payload(id, info),
           {:ok, taint} <-
             resolve_status_taint(id, status_taints, intent_taints, overrides),
           {:ok, encoded} <- encode_status(id, payload, taint) do
        {:cont, {:ok, [encoded | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        _ -> {:halt, {:error, :invalid_status}}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      {:error, _reason} = error -> error
    end
  end

  defp encode_status(id, payload, taint) do
    with :ok <- validate_identifier(id),
         {:ok, envelope} <- TaintEnvelope.new(payload, taint),
         {:ok, provenance} <- TaintEnvelope.to_map(envelope) do
      {:ok,
       %{
         id: id,
         payload: payload,
         taint: envelope.taint,
         persisted: %{"payload" => payload, "provenance" => provenance}
       }}
    else
      _ -> {:error, :invalid_status}
    end
  end

  defp status_payload(id, info) do
    info
    |> serialize_status_info()
    |> Map.put("intent_id", id)
    |> canonical_payload()
  end

  defp resolve_status_taint(id, status_taints, intent_taints, overrides) do
    existing = Map.fetch(status_taints, id)
    incoming = Map.fetch(overrides, {:status, id})

    case {existing, incoming} do
      {{:ok, previous}, {:ok, :inherit_item}} ->
        canonicalize_status_taint(previous)

      {{:ok, previous}, {:ok, added}} ->
        join_status_taints(previous, added)

      {{:ok, previous}, :error} ->
        canonicalize_status_taint(previous)

      {:error, {:ok, :inherit_item}} ->
        fetch_intent_taint(intent_taints, id)

      {:error, {:ok, added}} ->
        canonicalize_status_taint(added)

      {:error, :error} ->
        {:error, :live_status_provenance_missing}
    end
  rescue
    _ -> {:error, :invalid_live_status_provenance}
  catch
    _, _ -> {:error, :invalid_live_status_provenance}
  end

  defp fetch_intent_taint(intent_taints, id) do
    case Map.fetch(intent_taints, id) do
      {:ok, taint} -> canonicalize_status_taint(taint)
      :error -> {:error, :invalid_live_status_provenance}
    end
  end

  defp canonicalize_status_taint(taint) do
    case Taint.canonicalize(taint) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, _reason} -> {:error, :invalid_live_status_provenance}
    end
  end

  defp join_status_taints(left, right) do
    case Taint.join(left, right) do
      {:ok, joined} -> {:ok, joined}
      {:error, _reason} -> {:error, :invalid_live_status_provenance}
    end
  end

  defp resolve_item_taint(domain, agent_id, item_id, payload, overrides) do
    case Map.fetch(overrides, {domain, item_id}) do
      {:ok, taint} ->
        Taint.canonicalize(taint)

      :error ->
        case Provenance.resolve(domain, agent_id, item_id, payload) do
          {:ok, _taint, :legacy_unlabeled} -> {:error, :live_provenance_missing}
          {:ok, taint, _status} -> Taint.canonicalize(taint)
          _ -> {:error, :invalid_live_provenance}
        end
    end
  end

  defp decode_verified_aggregate(persisted, outer_taint, buffer_size) do
    with :ok <- exact_keys(persisted, @aggregate_fields),
         true <- persisted["version"] == @aggregate_version,
         {:ok, intents} <- decode_items(:intent, persisted["intents"], buffer_size),
         {:ok, percepts} <- decode_items(:percept, persisted["percepts"], buffer_size),
         :ok <- unique_item_ids(intents, percepts),
         {:ok, statuses} <- decode_verified_statuses(persisted["statuses"], intents),
         labels when labels != [] <- Enum.map(intents ++ percepts ++ statuses, & &1.taint),
         {:ok, expected_taint} <- Taint.join_many(labels),
         true <- expected_taint == outer_taint do
      {:ok, decoded_aggregate(intents, percepts, statuses)}
    else
      _ -> {:error, :invalid_aggregate}
    end
  rescue
    _ -> {:error, :invalid_aggregate}
  catch
    _, _ -> {:error, :invalid_aggregate}
  end

  defp decode_items(domain, items, buffer_size)
       when is_list(items) and is_integer(buffer_size) and buffer_size > 0 do
    if proper_bounded_list?(items, buffer_size) do
      Enum.reduce_while(items, {:ok, []}, fn persisted, {:ok, acc} ->
        with :ok <- exact_keys(persisted, @item_fields),
             payload when is_map(payload) <- persisted["payload"],
             {:ok, canonical} <- canonical_payload(payload),
             true <- canonical == payload,
             {:ok, item} <- deserialize_item(domain, payload),
             {:ok, envelope} <- TaintEnvelope.verify(persisted["provenance"], payload) do
          decoded = %{
            domain: domain,
            id: item.id,
            value: item,
            payload: payload,
            taint: envelope.taint,
            persisted: persisted
          }

          {:cont, {:ok, [decoded | acc]}}
        else
          _ -> {:halt, {:error, :invalid_item}}
        end
      end)
      |> case do
        {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
        {:error, _reason} = error -> error
      end
    else
      {:error, :invalid_item_count}
    end
  end

  defp decode_items(_domain, _items, _buffer_size), do: {:error, :invalid_items}

  defp decode_verified_statuses(statuses, intents) when is_map(statuses) do
    intent_ids = MapSet.new(Enum.map(intents, & &1.id))

    if valid_status_ids?(statuses, intent_ids) do
      statuses
      |> Enum.sort_by(fn {id, _persisted} -> id end)
      |> Enum.reduce_while({:ok, []}, fn {id, persisted}, {:ok, acc} ->
        with :ok <- exact_keys(persisted, @item_fields),
             payload when is_map(payload) <- persisted["payload"],
             {:ok, canonical} <- canonical_payload(payload),
             true <- canonical == payload,
             {:ok, info} <- decode_status_payload(id, payload),
             {:ok, envelope} <- TaintEnvelope.verify(persisted["provenance"], payload) do
          decoded = %{
            id: id,
            value: info,
            payload: payload,
            taint: envelope.taint,
            persisted: persisted
          }

          {:cont, {:ok, [decoded | acc]}}
        else
          _ -> {:halt, {:error, :invalid_status}}
        end
      end)
      |> case do
        {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
        {:error, _reason} = error -> error
      end
    else
      {:error, :invalid_statuses}
    end
  end

  defp decode_verified_statuses(_statuses, _intents), do: {:error, :invalid_statuses}

  defp decoded_aggregate(intents, percepts, statuses) do
    %{
      data: %{
        intents: Enum.map(intents, & &1.value),
        percepts: Enum.map(percepts, & &1.value),
        statuses: Map.new(statuses, &{&1.id, &1.value}),
        status_taints: Map.new(statuses, &{&1.id, &1.taint})
      },
      items: intents ++ percepts,
      status_items: statuses
    }
  end

  defp exact_keys(map, fields) when is_map(map) do
    if map_size(map) == length(fields) and
         MapSet.equal?(MapSet.new(Map.keys(map)), MapSet.new(fields)),
       do: :ok,
       else: {:error, :invalid_shape}
  end

  defp exact_keys(_map, _fields), do: {:error, :invalid_shape}

  defp proper_bounded_list?(items, limit), do: proper_bounded_list?(items, limit, 0)
  defp proper_bounded_list?([], _limit, _count), do: true

  defp proper_bounded_list?([_item | rest], limit, count) when count < limit,
    do: proper_bounded_list?(rest, limit, count + 1)

  defp proper_bounded_list?(_items, _limit, _count), do: false

  defp unique_item_ids(intents, percepts) do
    intent_ids = Enum.map(intents, & &1.id)
    percept_ids = Enum.map(percepts, & &1.id)

    if MapSet.size(MapSet.new(intent_ids)) == length(intent_ids) and
         MapSet.size(MapSet.new(percept_ids)) == length(percept_ids),
       do: :ok,
       else: {:error, :duplicate_item_id}
  end

  defp retain_statuses(statuses, intents) do
    statuses
    |> Map.take(Enum.map(intents, & &1.id))
    |> Map.new(fn {id, info} -> {id, normalize_status_info(info)} end)
  end

  defp retain_intent_state(data, intents) do
    retained_ids = Enum.map(intents, & &1.id)

    %{
      data
      | statuses: retain_statuses(data.statuses, intents),
        status_taints: Map.take(data.status_taints, retained_ids)
    }
  end

  defp normalize_status_info(info) when is_map(info) do
    %{
      status: normalize_status(Map.get(info, :status, :pending)),
      retry_count: normalize_retry_count(Map.get(info, :retry_count, 0))
    }
    |> maybe_put_status_time(:locked_at, Map.get(info, :locked_at))
    |> maybe_put_status_time(:completed_at, Map.get(info, :completed_at))
    |> maybe_put_status_time(:failed_at, Map.get(info, :failed_at))
    |> maybe_put_failure_reason(Map.get(info, :last_failure_reason))
  end

  defp normalize_status_info(_info), do: %{status: :pending, retry_count: 0}

  defp normalize_status(status) when status in @intent_statuses, do: status
  defp normalize_status(_status), do: :pending

  defp normalize_retry_count(value) when is_integer(value) and value >= 0, do: value
  defp normalize_retry_count(_value), do: 0

  defp maybe_put_status_time(info, _key, nil), do: info

  defp maybe_put_status_time(info, key, %DateTime{} = value),
    do: Map.put(info, key, value)

  defp maybe_put_status_time(info, _key, _value), do: info

  defp maybe_put_failure_reason(info, value)
       when is_binary(value) and byte_size(value) <= @max_failure_reason_bytes,
       do: Map.put(info, :last_failure_reason, value)

  defp maybe_put_failure_reason(info, _value), do: info

  defp decode_durable_aggregate(persisted, outer_taint, outer_status, buffer_size) do
    case outer_status do
      :verified ->
        case decode_verified_aggregate(persisted, outer_taint, buffer_size) do
          {:ok, decoded} -> {:ok, decoded, :verified}
          {:error, _reason} -> recover_corrupt_aggregate(persisted, buffer_size)
        end

      :legacy_unlabeled ->
        decode_unlabeled_aggregate(persisted, buffer_size)

      :invalid_durable_provenance ->
        recover_corrupt_aggregate(persisted, buffer_size)

      _ ->
        recover_corrupt_aggregate(persisted, buffer_size)
    end
  rescue
    _ -> {:error, :invalid_aggregate}
  catch
    _, _ -> {:error, :invalid_aggregate}
  end

  defp decode_unlabeled_aggregate(persisted, buffer_size) do
    cond do
      legacy_aggregate?(persisted) ->
        with {:ok, decoded} <- decode_structural_aggregate(persisted, buffer_size, :legacy) do
          {:ok, relabel_decoded(decoded, TaintEnvelope.missing_fallback()), :legacy_unlabeled}
        end

      current_versioned_shape?(persisted) ->
        with {:ok, decoded} <- decode_structural_aggregate(persisted, buffer_size, :versioned) do
          {:ok, relabel_decoded(decoded, TaintEnvelope.missing_fallback()), :legacy_unlabeled}
        end

      true ->
        recover_corrupt_aggregate(persisted, buffer_size)
    end
  end

  defp recover_corrupt_aggregate(persisted, buffer_size) do
    mode = if legacy_aggregate?(persisted), do: :legacy, else: :versioned

    with {:ok, decoded} <- decode_structural_aggregate(persisted, buffer_size, mode) do
      hostile = relabel_decoded(decoded, TaintEnvelope.invalid_fallback())
      {:ok, %{hostile | data: hostile_status_data(hostile.data)}, :invalid_durable_provenance}
    else
      _ -> {:error, :invalid_aggregate}
    end
  end

  defp legacy_aggregate?(persisted) when is_map(persisted) do
    legacy_fields = @aggregate_fields -- ["version"]

    exact_keys(persisted, legacy_fields) == :ok and is_list(persisted["intents"]) and
      is_list(persisted["percepts"]) and
      Enum.all?(persisted["intents"] ++ persisted["percepts"], fn item ->
        is_map(item) and not Map.has_key?(item, "payload") and
          not Map.has_key?(item, "provenance")
      end)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp legacy_aggregate?(_persisted), do: false

  defp current_versioned_shape?(persisted) when is_map(persisted) do
    exact_keys(persisted, @aggregate_fields) == :ok and
      persisted["version"] == @aggregate_version
  end

  defp current_versioned_shape?(_persisted), do: false

  defp decode_structural_aggregate(persisted, buffer_size, mode) do
    with true <- is_map(persisted),
         intents when is_list(intents) <- Map.get(persisted, "intents"),
         percepts when is_list(percepts) <- Map.get(persisted, "percepts"),
         true <- proper_bounded_list?(intents, buffer_size),
         true <- proper_bounded_list?(percepts, buffer_size),
         {:ok, intents} <- decode_structural_items(:intent, intents, mode),
         {:ok, percepts} <- decode_structural_items(:percept, percepts, mode),
         :ok <- unique_item_ids(intents, percepts),
         {:ok, statuses} <-
           decode_structural_statuses(Map.get(persisted, "statuses", %{}), intents, mode) do
      {:ok, decoded_aggregate(intents, percepts, statuses)}
    else
      _ -> {:error, :invalid_aggregate}
    end
  end

  defp decode_structural_items(domain, items, mode) do
    Enum.reduce_while(items, {:ok, []}, fn persisted, {:ok, acc} ->
      payload = structural_payload(persisted, mode)

      with payload when is_map(payload) <- payload,
           {:ok, payload} <- canonical_structural_payload(payload, mode),
           {:ok, item} <- deserialize_item(domain, payload) do
        decoded = %{
          domain: domain,
          id: item.id,
          value: item,
          payload: payload,
          taint: TaintEnvelope.invalid_fallback(),
          persisted: persisted
        }

        {:cont, {:ok, [decoded | acc]}}
      else
        _ -> {:halt, {:error, :invalid_item}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _reason} = error -> error
    end
  end

  defp structural_payload(persisted, :legacy), do: persisted

  defp structural_payload(persisted, :versioned) when is_map(persisted),
    do: Map.get(persisted, "payload")

  defp structural_payload(_persisted, _mode), do: nil

  defp canonical_structural_payload(payload, :legacy), do: canonical_payload(payload)

  defp canonical_structural_payload(payload, :versioned) do
    with {:ok, canonical} <- canonical_payload(payload),
         true <- canonical == payload do
      {:ok, canonical}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp canonical_structural_payload(_payload, _mode), do: {:error, :invalid_payload}

  defp decode_structural_statuses(statuses, intents, mode) when is_map(statuses) do
    intent_ids = MapSet.new(Enum.map(intents, & &1.id))

    if valid_status_ids?(statuses, intent_ids) do
      statuses
      |> Enum.sort_by(fn {id, _persisted} -> id end)
      |> Enum.reduce_while({:ok, []}, fn {id, persisted}, {:ok, acc} ->
        payload = structural_status_payload(id, persisted, mode)

        with payload when is_map(payload) <- payload,
             {:ok, payload} <- canonical_structural_payload(payload, mode),
             {:ok, info} <- decode_status_payload(id, payload) do
          decoded = %{
            id: id,
            value: info,
            payload: payload,
            taint: TaintEnvelope.invalid_fallback(),
            persisted: persisted
          }

          {:cont, {:ok, [decoded | acc]}}
        else
          _ -> {:halt, {:error, :invalid_status}}
        end
      end)
      |> case do
        {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
        {:error, _reason} = error -> error
      end
    else
      {:error, :invalid_statuses}
    end
  end

  defp decode_structural_statuses(_statuses, _intents, _mode),
    do: {:error, :invalid_statuses}

  defp structural_status_payload(id, persisted, :legacy) when is_map(persisted),
    do: Map.put(persisted, "intent_id", id)

  defp structural_status_payload(_id, persisted, :versioned) when is_map(persisted),
    do: Map.get(persisted, "payload")

  defp structural_status_payload(_id, _persisted, _mode), do: nil

  defp relabel_decoded(decoded, taint) do
    items = Enum.map(decoded.items, &Map.put(&1, :taint, taint))
    status_items = Enum.map(decoded.status_items, &Map.put(&1, :taint, taint))

    %{
      decoded
      | items: items,
        status_items: status_items,
        data: %{
          decoded.data
          | status_taints: Map.new(status_items, &{&1.id, &1.taint})
        }
    }
  end

  defp hostile_status_data(data) do
    statuses =
      Map.new(data.intents, fn intent ->
        {intent.id, %{status: :completed, retry_count: 0}}
      end)

    status_taints = Map.new(data.intents, &{&1.id, TaintEnvelope.invalid_fallback()})
    %{data | statuses: statuses, status_taints: status_taints}
  end

  defp valid_status_ids?(statuses, intent_ids) do
    map_size(statuses) <= MapSet.size(intent_ids) and
      Enum.all?(Map.keys(statuses), fn id ->
        is_binary(id) and MapSet.member?(intent_ids, id)
      end)
  end

  defp decode_status_payload(id, payload) do
    with true <- is_map(payload),
         true <- MapSet.subset?(MapSet.new(Map.keys(payload)), MapSet.new(@status_payload_fields)),
         true <- payload["intent_id"] == id,
         {:ok, info} <- decode_status_info(Map.delete(payload, "intent_id")),
         {:ok, expected} <- status_payload(id, info),
         true <- expected == payload do
      {:ok, info}
    else
      _ -> {:error, :invalid_status}
    end
  end

  defp decode_status_info(persisted) when is_map(persisted) do
    keys = Map.keys(persisted)

    with true <- keys != [],
         true <- Enum.all?(keys, &(&1 in @status_fields)),
         {:ok, status} <- decode_enum(Map.get(persisted, "status", "pending"), @intent_statuses),
         retry_count when is_integer(retry_count) and retry_count >= 0 <-
           Map.get(persisted, "retry_count", 0),
         {:ok, info} <-
           decode_status_times(persisted, %{status: status, retry_count: retry_count}),
         {:ok, info} <- decode_failure_reason(persisted, info) do
      {:ok, info}
    else
      _ -> {:error, :invalid_status}
    end
  end

  defp decode_status_info(_persisted), do: {:error, :invalid_status}

  defp decode_status_times(persisted, info) do
    Enum.reduce_while(~w(locked_at completed_at failed_at), {:ok, info}, fn key, {:ok, acc} ->
      case Map.fetch(persisted, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case parse_datetime_exact(value) do
            {:ok, datetime} ->
              atom_key = String.to_existing_atom(key)
              {:cont, {:ok, Map.put(acc, atom_key, datetime)}}

            {:error, _reason} ->
              {:halt, {:error, :invalid_status_time}}
          end
      end
    end)
  end

  defp decode_failure_reason(persisted, info) do
    case Map.fetch(persisted, "last_failure_reason") do
      :error ->
        {:ok, info}

      {:ok, value} when is_binary(value) and byte_size(value) <= @max_failure_reason_bytes ->
        if String.valid?(value),
          do: {:ok, Map.put(info, :last_failure_reason, value)},
          else: {:error, :invalid_failure_reason}

      {:ok, _value} ->
        {:error, :invalid_failure_reason}
    end
  end

  defp deserialize_item(:intent, payload), do: deserialize_intent_exact(payload)
  defp deserialize_item(:percept, payload), do: deserialize_percept_exact(payload)
  defp deserialize_item(_domain, _payload), do: {:error, :invalid_item}

  defp deserialize_intent_exact(payload) do
    with :ok <- exact_keys(payload, @intent_payload_fields),
         :ok <- validate_identifier(payload["id"]),
         {:ok, type} <- decode_enum(payload["type"], @intent_types),
         {:ok, action} <- decode_optional_existing_atom(payload["action"]),
         true <- is_map(payload["params"]),
         true <- optional_binary?(payload["reasoning"]),
         true <- optional_binary?(payload["goal_id"]),
         true <- is_number(payload["confidence"]),
         true <- is_integer(payload["urgency"]),
         {:ok, created_at} <- parse_datetime_exact(payload["created_at"]),
         true <- is_map(payload["metadata"]),
         true <- optional_binary?(payload["capability"]),
         {:ok, op} <- decode_optional_existing_atom(payload["op"]),
         true <- optional_binary?(payload["target"]) do
      {:ok,
       %Intent{
         id: payload["id"],
         type: type,
         action: action,
         params: payload["params"],
         reasoning: payload["reasoning"],
         goal_id: payload["goal_id"],
         confidence: payload["confidence"] * 1.0,
         urgency: payload["urgency"],
         created_at: created_at,
         metadata: payload["metadata"],
         capability: payload["capability"],
         op: op,
         target: payload["target"]
       }}
    else
      _ -> {:error, :invalid_intent}
    end
  end

  defp deserialize_percept_exact(payload) do
    with :ok <- exact_keys(payload, @percept_payload_fields),
         :ok <- validate_identifier(payload["id"]),
         {:ok, type} <- decode_enum(payload["type"], @percept_types),
         true <- optional_binary?(payload["intent_id"]),
         {:ok, outcome} <- decode_enum(payload["outcome"], @percept_outcomes),
         true <- is_map(payload["data"]),
         true <- optional_binary?(payload["error"]),
         true <- is_nil(payload["duration_ms"]) or is_integer(payload["duration_ms"]),
         {:ok, created_at} <- parse_datetime_exact(payload["created_at"]),
         true <- is_map(payload["metadata"]),
         true <- optional_binary?(payload["summary"]) do
      {:ok,
       %Percept{
         id: payload["id"],
         type: type,
         intent_id: payload["intent_id"],
         outcome: outcome,
         data: payload["data"],
         error: payload["error"],
         duration_ms: payload["duration_ms"],
         created_at: created_at,
         metadata: payload["metadata"],
         summary: payload["summary"]
       }}
    else
      _ -> {:error, :invalid_percept}
    end
  end

  defp decode_enum(value, allowed) when is_atom(value) do
    if value in allowed, do: {:ok, value}, else: {:error, :invalid_enum}
  end

  defp decode_enum(value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_enum}
      atom -> {:ok, atom}
    end
  end

  defp decode_enum(_value, _allowed), do: {:error, :invalid_enum}

  defp decode_optional_existing_atom(nil), do: {:ok, nil}
  defp decode_optional_existing_atom(value) when is_atom(value), do: {:ok, value}

  defp decode_optional_existing_atom(value) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> {:error, :unknown_atom}
  end

  defp decode_optional_existing_atom(_value), do: {:error, :invalid_atom}

  defp optional_binary?(nil), do: true
  defp optional_binary?(value), do: is_binary(value) and String.valid?(value)

  defp parse_datetime_exact(%DateTime{} = datetime), do: {:ok, datetime}

  defp parse_datetime_exact(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime_exact(_value), do: {:error, :invalid_datetime}

  defp serialize_status_info(info) do
    Map.new(info, fn
      {k, %DateTime{} = dt} -> {to_string(k), DateTime.to_iso8601(dt)}
      {:status, status} when status in @intent_statuses -> {"status", Atom.to_string(status)}
      {k, v} -> {to_string(k), v}
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
      "metadata" => intent.metadata,
      "capability" => intent.capability,
      "op" => if(intent.op, do: to_string(intent.op)),
      "target" => intent.target
    }
  end

  defp serialize_percept(%Percept{} = percept) do
    %{
      "id" => percept.id,
      "type" => to_string(percept.type),
      "intent_id" => percept.intent_id,
      "outcome" => to_string(percept.outcome),
      "data" => percept.data,
      "error" => serialize_error(percept.error),
      "duration_ms" => percept.duration_ms,
      "created_at" => DateTime.to_iso8601(percept.created_at),
      "metadata" => percept.metadata,
      "summary" => percept.summary
    }
  end

  defp serialize_error(nil), do: nil
  defp serialize_error(error) when is_binary(error), do: error
  defp serialize_error(error) when is_atom(error), do: Atom.to_string(error)
  defp serialize_error(error), do: inspect(error, limit: 50, printable_limit: 1_024)

  defp intent_to_text(%Intent{} = intent) do
    "Intent: #{intent.type} #{intent.action} #{inspect(intent.params)}"
  end

  defp load_from_postgres(buffer_size) do
    if MemoryStore.available?() do
      case MemoryStore.load_all_tainted("intents") do
        {:ok, entries} ->
          loaded =
            Enum.count(entries, fn
              {agent_id, %TaintedValue{value: persisted, taint: outer_taint}, outer_status} ->
                with :ok <- validate_identifier(agent_id),
                     {:ok, decoded, _status} <-
                       decode_durable_aggregate(
                         persisted,
                         outer_taint,
                         outer_status,
                         buffer_size
                       ),
                     :ok <- restore_decoded_agent(agent_id, empty_agent_data(), decoded) do
                  true
                else
                  _ -> false
                end

              _ ->
                false
            end)

          Logger.info("IntentStore loaded durable aggregates", count: loaded)

        _ ->
          :ok
      end
    end
  rescue
    _ ->
      Logger.warning("IntentStore durable startup load failed")
  catch
    _, _ ->
      Logger.warning("IntentStore durable startup load failed")
  end
end
