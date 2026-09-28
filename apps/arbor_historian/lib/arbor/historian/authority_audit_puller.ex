defmodule Arbor.Historian.AuthorityAuditPuller do
  @moduledoc """
  Supervised pull delivery from Security's existing authority mutation journal.

  Every mutation uses one stable EventLog stream and one immutable event. Only
  a node-restart durable target qualifies. Actual committed content is reread
  and fingerprinted before acknowledging the exact source intent. Append ACK
  loss is harmless: retries reuse identity and content. Failure leaves the
  source journal pending; no hot projection or new store is audit authority.

  An operation whose committed EventLog content conflicts with the journal
  intent (`:audit_content_conflict`, from the readback or from the journal's
  acknowledgement check) or whose stream cannot be read back exactly
  (`:audit_content_unavailable`) stays `effect_applied` in the journal: it is
  retried every poll, never acknowledged and therefore never retired. Such a
  stuck operation is reported once per stuck episode, not on every poll: when
  an operation first becomes stuck (or its reason changes) the puller emits
  `[:arbor, :historian, :authority_audit, :conflict]` telemetry
  (`%{count: 1}`, metadata `operation_id`, `reason`, `source`
  (`:event_log | :journal`)), and each delivery pass that finds newly stuck
  operations logs one warning naming them. An operation leaves the stuck set
  once it is no longer in the delivery batch (acknowledged, or no longer
  pending), so a recurrence is reported again. A same-UID authority-store
  rollback that re-presents a retired identity in a different second is the
  expected cause of a persistent conflict (see
  `docs/arbor/DURABLE_CAPABILITY_MUTATION_AUDIT.md`).
  """
  use GenServer

  require Logger

  alias Arbor.Historian.Config
  alias Arbor.Persistence
  alias Arbor.Persistence.Event

  @stuck_reasons [:audit_content_conflict, :audit_content_unavailable]
  @conflict_event [:arbor, :historian, :authority_audit, :conflict]
  @logged_ids 5

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def flush, do: GenServer.call(__MODULE__, :flush, 30_000)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :poll_interval_ms, 250)

    if is_integer(interval) and interval in 25..60_000 do
      state = %{interval: interval, timer: nil, stuck: %{}}
      {:ok, schedule(state)}
    else
      {:stop, :invalid_poll_interval}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {reply, state} = deliver(state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    {_reply, state} = deliver(state)
    {:noreply, schedule(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    :ok
  end

  @impl true
  def format_status(status),
    do: status |> Map.put(:message, :redacted) |> Map.put(:log, :redacted)

  defp schedule(state), do: %{state | timer: Process.send_after(self(), :poll, state.interval)}

  defp deliver(state) do
    security = Config.security_module()

    # Journal-only restart must converge without restarting the live capability
    # owner. Its serialized, consumer-gated observation never replays effects.
    case security.reconcile_authority_audit() do
      :ok -> deliver_batch(security, state)
      _ -> {{:error, :audit_source_unavailable}, state}
    end
  rescue
    _ -> {{:error, :audit_delivery_unavailable}, state}
  catch
    _, _ -> {{:error, :audit_delivery_unavailable}, state}
  end

  defp deliver_batch(security, state) do
    case security.authority_audit_delivery_batch() do
      {:ok, batch} when is_list(batch) ->
        outcomes = Enum.map(batch, &{&1["operation_id"], deliver_one(security, &1)})
        count = Enum.count(outcomes, fn {_id, outcome} -> outcome == :delivered end)
        state = note_stuck(state, outcomes)
        {{:ok, %{delivered: count, pending: length(batch) - count}}, state}

      _ ->
        {{:error, :audit_source_unavailable}, state}
    end
  end

  defp deliver_one(security, item) do
    with {:ok, target} <- Config.durable_event_log_target(),
         {:ok, :node_restart} <-
           Persistence.durability_class(target.name, target.backend, target.opts),
         {:ok, event} <- event(item["event"]),
         :ok <- stuck(:event_log, ensure_committed(target, event)),
         {:ok, _} <-
           stuck(
             :journal,
             security.acknowledge_authority_audit(item["operation_id"], item["intent_sha256"])
           ) do
      :delivered
    else
      {:stuck, _source, _reason} = stuck -> stuck
      _ -> :failed
    end
  rescue
    _ -> :failed
  catch
    _, _ -> :failed
  end

  defp stuck(source, {:error, reason}) when reason in @stuck_reasons,
    do: {:stuck, source, reason}

  defp stuck(_source, result), do: result

  # Report each stuck operation once per stuck episode: the stuck set is
  # exactly the stuck operations of the latest batch, so an acknowledged or
  # no-longer-pending operation is forgotten and a recurrence reports again.
  # Bounded by the journal's pending set.
  defp note_stuck(state, outcomes) do
    current =
      for {id, {:stuck, source, reason}} <- outcomes, is_binary(id), into: %{} do
        {id, {reason, source}}
      end

    fresh = Enum.reject(current, fn {id, value} -> Map.get(state.stuck, id) == value end)

    Enum.each(fresh, fn {id, {reason, source}} ->
      :telemetry.execute(@conflict_event, %{count: 1}, %{
        operation_id: id,
        reason: reason,
        source: source
      })
    end)

    if fresh != [], do: log_stuck(fresh, map_size(current))
    %{state | stuck: current}
  end

  defp log_stuck(fresh, stuck_total) do
    shown =
      fresh
      |> Enum.sort()
      |> Enum.take(@logged_ids)
      |> Enum.map_join(", ", fn {id, {reason, source}} -> "#{id} (#{reason}, #{source})" end)

    more =
      if length(fresh) > @logged_ids, do: " and #{length(fresh) - @logged_ids} more", else: ""

    Logger.warning(
      "Historian authority audit delivery is stuck for #{length(fresh)} newly affected " <>
        "operation(s) (#{stuck_total} stuck in total): #{shown}#{more}. The journal keeps " <>
        "them effect_applied; they are retried, never acknowledged and never retired. " <>
        "A persistent audit_content_conflict usually means the durable EventLog already " <>
        "holds different content for the same operation id (for example after an " <>
        "authority-store rollback)."
    )
  end

  defp event(raw) do
    with {:ok, timestamp, 0} <- DateTime.from_iso8601(raw["timestamp"]) do
      {:ok,
       Event.new(raw["stream_id"], raw["type"], raw["data"],
         id: raw["id"],
         timestamp: timestamp,
         metadata: raw["metadata"],
         agent_id: raw["agent_id"],
         correlation_id: raw["correlation_id"],
         causation_id: raw["causation_id"]
       )}
    end
  end

  defp ensure_committed(target, event) do
    case read_exact(target, event) do
      :ok ->
        :ok

      :absent ->
        # The return may be ambiguous. Ordered backend reread below is the
        # acknowledgement boundary; errors never justify a fresh identity.
        _ = append(target, event)
        read_exact(target, event)

      error ->
        error
    end
  end

  defp append(target, event) do
    Persistence.append(target.name, target.backend, event.stream_id, event, target.opts)
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
  end

  defp read_exact(target, event) do
    opts = Keyword.put(target.opts, :limit, 2)

    case Persistence.read_stream(target.name, target.backend, event.stream_id, opts) do
      {:ok, []} ->
        :absent

      {:ok, [committed]} ->
        if Persistence.committed_event_matches_submission?(event.stream_id, event, committed),
          do: :ok,
          else: {:error, :audit_content_conflict}

      _ ->
        {:error, :audit_content_unavailable}
    end
  end
end
