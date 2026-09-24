defmodule Arbor.Historian.AuthorityAuditPuller do
  @moduledoc """
  Supervised pull delivery from Security's existing authority mutation journal.

  Every mutation uses one stable EventLog stream and one immutable event. Only
  a node-restart durable target qualifies. Actual committed content is reread
  and fingerprinted before acknowledging the exact source intent. Append ACK
  loss is harmless: retries reuse identity and content. Failure leaves the
  source journal pending; no hot projection or new store is audit authority.
  """
  use GenServer

  alias Arbor.Historian.Config
  alias Arbor.Persistence
  alias Arbor.Persistence.Event

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def flush, do: GenServer.call(__MODULE__, :flush, 30_000)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :poll_interval_ms, 250)

    if is_integer(interval) and interval in 25..60_000 do
      state = %{interval: interval, timer: nil}
      {:ok, schedule(state)}
    else
      {:stop, :invalid_poll_interval}
    end
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, deliver(), state}

  @impl true
  def handle_info(:poll, state) do
    _ = deliver()
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

  defp deliver do
    security = Config.security_module()

    # Journal-only restart must converge without restarting the live capability
    # owner. Its serialized, consumer-gated observation never replays effects.
    case security.reconcile_authority_audit() do
      :ok -> deliver_batch(security)
      _ -> {:error, :audit_source_unavailable}
    end
  rescue
    _ -> {:error, :audit_delivery_unavailable}
  catch
    _, _ -> {:error, :audit_delivery_unavailable}
  end

  defp deliver_batch(security) do
    case security.authority_audit_delivery_batch() do
      {:ok, batch} when is_list(batch) ->
        count = Enum.count(batch, &deliver_one(security, &1))
        {:ok, %{delivered: count, pending: length(batch) - count}}

      _ ->
        {:error, :audit_source_unavailable}
    end
  end

  defp deliver_one(security, item) do
    with {:ok, target} <- Config.durable_event_log_target(),
         {:ok, :node_restart} <-
           Persistence.durability_class(target.name, target.backend, target.opts),
         {:ok, event} <- event(item["event"]),
         :ok <- ensure_committed(target, event),
         {:ok, _} <-
           security.acknowledge_authority_audit(item["operation_id"], item["intent_sha256"]) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
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
