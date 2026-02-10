defmodule Arbor.Persistence.EventLog.Snapshotter do
  @moduledoc """
  Periodic snapshotter for EventLog.ETS state.

  Takes snapshots of the EventLog.ETS state at configurable intervals
  or after a threshold number of events. Snapshots are stored in a
  pluggable Store backend, enabling crash recovery without full replay.

  ## Configuration

      config :arbor_persistence, :event_log_snapshot,
        enabled: true,
        event_log_name: :event_log,
        store: Arbor.Persistence.QueryableStore.ETS,
        store_opts: [name: :snapshot_store],
        interval_ms: 300_000,
        event_threshold: 1_000,
        retention: 5

  ## Snapshot Format

  Each snapshot is stored as a Record with key `"eventlog_snapshots:snapshot:<id>"`.
  A meta record at `"eventlog_snapshots:meta"` tracks the latest snapshot ID
  and the list of all snapshot IDs for pruning.
  """

  use GenServer

  require Logger

  @default_namespace "eventlog_snapshots"
  @default_interval_ms 300_000
  @default_event_threshold 1_000
  @default_retention 5

  # ============================================================================
  # Public API
  # ============================================================================

  @doc "Start the Snapshotter GenServer."
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Force an immediate snapshot. Returns `:ok` or `{:error, reason}`."
  @spec snapshot_now(GenServer.server()) :: :ok | {:error, term()}
  def snapshot_now(server \\ __MODULE__) do
    GenServer.call(server, :snapshot_now, 30_000)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl GenServer
  def init(opts) do
    event_log_name = Keyword.get(opts, :event_log_name, :event_log)
    store = Keyword.get(opts, :store)
    store_opts = Keyword.get(opts, :store_opts, [])
    namespace = Keyword.get(opts, :namespace, @default_namespace)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    event_threshold = Keyword.get(opts, :event_threshold, @default_event_threshold)
    retention = Keyword.get(opts, :retention, @default_retention)

    last_snapshot_id = load_last_snapshot_id(store, store_opts, namespace)

    state = %{
      event_log_name: event_log_name,
      store: store,
      store_opts: store_opts,
      namespace: namespace,
      interval_ms: interval_ms,
      event_threshold: event_threshold,
      retention: retention,
      events_since_snapshot: 0,
      last_snapshot_id: last_snapshot_id,
      timer_ref: nil,
      subscription_ref: nil
    }

    # Schedule timer and deferred subscription
    timer_ref = schedule_snapshot(interval_ms)
    send(self(), :subscribe_to_event_log)

    {:ok, %{state | timer_ref: timer_ref}}
  end

  @impl GenServer
  def handle_call(:snapshot_now, _from, state) do
    case do_snapshot(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info(:subscribe_to_event_log, state) do
    case subscribe_to_event_log(state.event_log_name) do
      {:ok, ref} ->
        {:noreply, %{state | subscription_ref: ref}}

      :error ->
        # Retry after 1 second
        Process.send_after(self(), :subscribe_to_event_log, 1_000)
        {:noreply, state}
    end
  end

  def handle_info({:event, %Arbor.Persistence.Event{}}, state) do
    new_count = state.events_since_snapshot + 1

    if new_count >= state.event_threshold do
      case do_snapshot(state) do
        {:ok, new_state} ->
          {:noreply, new_state}

        {:error, _reason} ->
          {:noreply, %{state | events_since_snapshot: new_count}}
      end
    else
      {:noreply, %{state | events_since_snapshot: new_count}}
    end
  end

  def handle_info(:take_snapshot, state) do
    state =
      case do_snapshot(state) do
        {:ok, new_state} -> new_state
        {:error, _reason} -> state
      end

    timer_ref = schedule_snapshot(state.interval_ms)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  # Ignore unknown messages
  def handle_info(_msg, state), do: {:noreply, state}

  # ============================================================================
  # Private — Snapshot Capture
  # ============================================================================

  defp do_snapshot(%{store: nil} = state), do: {:ok, state}

  defp do_snapshot(state) do
    case GenServer.call(state.event_log_name, :export_state, 30_000) do
      {:ok, exported} ->
        new_id = (state.last_snapshot_id || 0) + 1

        envelope = %{
          "snapshot_id" => new_id,
          "global_position" => exported.global_position,
          "stream_versions" => exported.stream_versions,
          "events" => exported.events,
          "captured_at" => DateTime.to_iso8601(DateTime.utc_now())
        }

        snapshot_key = "#{state.namespace}:snapshot:#{new_id}"
        record = Arbor.Persistence.Record.new(snapshot_key, envelope)

        case state.store.put(snapshot_key, record, state.store_opts) do
          :ok ->
            update_meta(state, new_id)
            prune_old_snapshots(state, new_id)

            Logger.debug(
              "EventLog snapshot #{new_id} captured (#{exported.global_position} events)"
            )

            {:ok,
             %{
               state
               | last_snapshot_id: new_id,
                 events_since_snapshot: 0
             }}

          {:error, reason} ->
            Logger.warning("EventLog snapshot save failed: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("EventLog export failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("EventLog snapshot failed: #{inspect(e)}")
      {:error, e}
  catch
    :exit, reason ->
      Logger.warning("EventLog snapshot failed (exit): #{inspect(reason)}")
      {:error, reason}
  end

  # ============================================================================
  # Private — Meta Management
  # ============================================================================

  defp load_last_snapshot_id(nil, _opts, _namespace), do: nil

  defp load_last_snapshot_id(store, opts, namespace) do
    meta_key = "#{namespace}:meta"

    case store.get(meta_key, opts) do
      {:ok, %{data: meta}} -> meta["latest_id"]
      {:ok, meta} when is_map(meta) -> meta["latest_id"]
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp update_meta(state, new_id) do
    meta_key = "#{state.namespace}:meta"

    # Read existing meta to get snapshot_ids list
    existing_ids =
      case state.store.get(meta_key, state.store_opts) do
        {:ok, %{data: meta}} -> meta["snapshot_ids"] || []
        {:ok, meta} when is_map(meta) -> meta["snapshot_ids"] || []
        _ -> []
      end

    meta = %{
      "latest_id" => new_id,
      "snapshot_ids" => existing_ids ++ [new_id],
      "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    record = Arbor.Persistence.Record.new(meta_key, meta)
    state.store.put(meta_key, record, state.store_opts)
  end

  defp prune_old_snapshots(state, current_id) do
    meta_key = "#{state.namespace}:meta"

    case state.store.get(meta_key, state.store_opts) do
      {:ok, %{data: meta}} -> do_prune(state, meta, current_id)
      {:ok, meta} when is_map(meta) -> do_prune(state, meta, current_id)
      _ -> :ok
    end
  end

  defp do_prune(state, meta, current_id) do
    all_ids = meta["snapshot_ids"] || []

    if length(all_ids) > state.retention do
      {to_delete, to_keep} = Enum.split(all_ids, length(all_ids) - state.retention)

      Enum.each(to_delete, fn id ->
        key = "#{state.namespace}:snapshot:#{id}"
        state.store.delete(key, state.store_opts)
      end)

      # Update meta with trimmed list
      updated_meta = %{
        "latest_id" => current_id,
        "snapshot_ids" => to_keep,
        "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      meta_key = "#{state.namespace}:meta"
      record = Arbor.Persistence.Record.new(meta_key, updated_meta)
      state.store.put(meta_key, record, state.store_opts)
    end
  end

  # ============================================================================
  # Private — Subscription & Scheduling
  # ============================================================================

  defp subscribe_to_event_log(event_log_name) do
    if Process.whereis(event_log_name) do
      case GenServer.call(event_log_name, {:subscribe, :all, self()}) do
        {:ok, ref} -> {:ok, ref}
        _ -> :error
      end
    else
      :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp schedule_snapshot(interval_ms) do
    Process.send_after(self(), :take_snapshot, interval_ms)
  end
end
