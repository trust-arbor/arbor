defmodule Arbor.AI.ProviderRouteEvidence do
  @moduledoc """
  Durable provider-route evidence authority for exact OAuth routes.

  This is a supervised imperative shell around `ProviderRouteEvidenceCore`.
  Accepted writes are durable-first: the EventLog append is acknowledged (or
  reconciled by exact operation identity) before the in-memory projection is
  replaced. Legacy stores are compatibility mirrors only.
  """

  use GenServer

  alias Arbor.AI.Config
  alias Arbor.AI.ProviderRouteEvidenceCore
  alias Arbor.Persistence
  alias Arbor.Persistence.Event

  @name __MODULE__
  @task_supervisor Arbor.AI.ProviderRouteEvidence.TaskSupervisor
  @stream_prefix "provider_route_evidence:v1:"
  @schema_version 1
  # A daily stream is intentionally capped. More than 512 events in one day
  # blocks replay fail-closed rather than admitting an unbounded evidence read.
  @max_events 512

  @type target :: %{name: atom(), backend: module(), opts: keyword()}

  defstruct target: nil, status: :blocked, state: nil, replay_ref: nil

  def start_link(opts \\ [])

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: @name)

  def record_failure(attrs, opts \\ [])

  @spec record_failure(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def record_failure(attrs, opts) when is_map(attrs), do: record(:failure, attrs, opts)

  def record_failure(_, _), do: {:error, :malformed}

  def record_quota(attrs, opts \\ [])

  @spec record_quota(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def record_quota(attrs, opts) when is_map(attrs), do: record(:quota, attrs, opts)

  def record_quota(_, _), do: {:error, :malformed}

  def snapshot_status(opts \\ [])

  @spec snapshot_status(keyword()) ::
          {:ok, map()} | {:error, :unavailable | :malformed | :invalid_options}
  def snapshot_status(opts) do
    with {:ok, opts} <- validate_snapshot_opts(opts) do
      case call({:snapshot, :all, opts}, 5_000) do
        {:error, :provider_route_evidence_unavailable} -> {:error, :unavailable}
        result -> result
      end
    end
  end

  def route_failure_snapshot(opts \\ [])

  @spec route_failure_snapshot(keyword()) ::
          {:ok, map()} | {:error, :unavailable | :malformed | :invalid_options}
  def route_failure_snapshot(opts), do: snapshot_part(:route_failure, opts)

  def quota_snapshot(opts \\ [])

  @spec quota_snapshot(keyword()) ::
          {:ok, map()} | {:error, :unavailable | :malformed | :invalid_options}
  def quota_snapshot(opts), do: snapshot_part(:quota, opts)

  @spec status() :: map()
  def status do
    case Process.whereis(@name) do
      pid when is_pid(pid) -> GenServer.call(pid, :status, 1_000)
      _ -> %{available: false, reason: :unavailable}
    end
  catch
    :exit, _ -> %{available: false, reason: :unavailable}
  end

  @impl true
  def init(opts) do
    target = Keyword.get(opts, :target) || configured_target()

    case validate_target(target) do
      {:ok, target} ->
        state = %__MODULE__{target: target, status: :replaying, state: nil}
        send(self(), :start_replay)
        {:ok, state}

      {:error, reason} ->
        {:ok, %__MODULE__{target: target, status: {:blocked, reason}, state: nil}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_view(state), state}
  end

  def handle_call({:snapshot, kind, opts}, _from, state) do
    case validate_snapshot_opts(opts) do
      {:ok, opts} ->
        case {state.status, snapshot_now(opts)} do
          {:ready, {:ok, now}} ->
            case snapshot_part(kind, state.state.core, now) do
              {:ok, snapshot} -> {:reply, {:ok, snapshot}, state}
              {:error, :malformed} -> {:reply, {:error, :malformed}, state}
            end

          {:replaying, _} ->
            {:reply, {:error, :unavailable}, state}

          {{:blocked, _}, _} ->
            {:reply, {:error, :unavailable}, state}

          _ ->
            {:reply, {:error, :malformed}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:record, kind, attrs, opts}, _from, state) do
    case validate_record_opts(opts) do
      {:ok, opts} -> handle_record(kind, attrs, opts, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_record(kind, attrs, opts, state) do
    now = DateTime.utc_now()

    case state.status do
      :ready ->
        case durable_record(kind, attrs, opts, state.target, now) do
          {:ok, next_state, receipt} ->
            {:reply, {:ok, receipt}, %{state | state: next_state}}

          {:error, {:provider_route_evidence_replay_failed, _} = reason} ->
            block_after_commit(state, reason)

          {:error, {:provider_route_evidence_commit_uncertain, _} = reason} ->
            block_after_commit(state, reason)

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      _ ->
        {:reply, {:error, :provider_route_evidence_unavailable}, state}
    end
  end

  @impl true
  def handle_info(:start_replay, %{status: :replaying, replay_ref: nil} = state) do
    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        replay(state.target, DateTime.utc_now())
      end)

    {:noreply, %{state | replay_ref: task.ref}}
  rescue
    _ -> {:noreply, %{state | status: {:blocked, :replay_unavailable}}}
  end

  def handle_info({ref, result}, %{replay_ref: ref} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, replayed_state} ->
        {:noreply, %{state | status: :ready, state: replayed_state, replay_ref: nil}}

      {:error, reason} ->
        {:noreply, %{state | status: {:blocked, reason}, state: nil, replay_ref: nil}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{replay_ref: ref} = state) do
    {:noreply,
     %{state | status: {:blocked, {:replay_task_failed, reason}}, state: nil, replay_ref: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp call(message, timeout) do
    case Process.whereis(@name) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, message, timeout)
        catch
          :exit, _ -> {:error, :provider_route_evidence_unavailable}
        end

      _ ->
        {:error, :provider_route_evidence_unavailable}
    end
  end

  defp status_view(%{status: :replaying}), do: %{available: false, status: :replaying}
  defp status_view(%{status: :ready}), do: %{available: true, status: :ready}

  defp status_view(%{status: {:blocked, reason}}) do
    %{available: false, status: blocked_status(reason), reason: bounded_reason(reason)}
  end

  defp blocked_status(reason) when reason in [:replay_malformed, :malformed], do: :malformed
  defp blocked_status(:replay_incomplete), do: :incomplete

  defp blocked_status({:provider_route_evidence_replay_failed, reason}),
    do: blocked_status(reason)

  defp blocked_status(_reason), do: :unavailable

  defp bounded_reason(reason) when is_atom(reason), do: reason
  defp bounded_reason({tag, reason}) when is_atom(tag) and is_atom(reason), do: {tag, reason}
  defp bounded_reason(_), do: :backend_unavailable

  defp configured_target do
    Application.get_env(:arbor_ai, :provider_route_evidence_target) ||
      Application.get_env(:arbor_ai, :provider_usage_ledger_target)
  end

  defp validate_target(nil), do: {:error, :target_unset}

  defp validate_target(target) do
    with {:ok, normalized} <- Config.normalize_provider_usage_ledger_target(target),
         normalized = %{
           normalized
           | opts: Keyword.drop(normalized.opts, [:durability_class, :durability])
         },
         {:ok, :node_restart} <-
           Persistence.durability_class(normalized.name, normalized.backend, normalized.opts) do
      {:ok, normalized}
    else
      {:error, :provider_usage_ledger_target_unset} -> {:error, :target_unset}
      {:error, _} -> {:error, :target_not_node_restart}
    end
  rescue
    _ -> {:error, :target_not_node_restart}
  end

  defp durable_record(kind, attrs, opts, target, now) do
    with {:ok, data} <- prepare(kind, attrs, now),
         {:ok, type, data} <- ProviderRouteEvidenceCore.event_data(kind, data),
         {:ok, date} <- utc_date(now),
         stream_id = @stream_prefix <> date,
         {:ok, event} <- build_event(stream_id, type, data, now),
         :ok <- append_exact(target, stream_id, event, opts) do
      case replay(target, now) do
        {:ok, next_state} ->
          {:ok, next_state, %{"event_id" => event.id, "stream_id" => stream_id, "type" => type}}

        {:error, reason} ->
          {:error, {:provider_route_evidence_replay_failed, reason}}
      end
    end
  end

  defp prepare(:failure, attrs, now), do: ProviderRouteEvidenceCore.prepare_failure(attrs, now)
  defp prepare(:quota, attrs, now), do: ProviderRouteEvidenceCore.prepare_quota(attrs, now)
  defp prepare(_, _, _), do: {:error, :malformed}

  defp build_event(stream_id, type, data, now) do
    with {:ok, id} <- ProviderRouteEvidenceCore.event_id(stream_id, type, data) do
      {:ok,
       Event.new(stream_id, type, data,
         id: id,
         timestamp: now,
         metadata: %{"schema_version" => @schema_version}
       )}
    end
  end

  defp append_exact(target, stream_id, event, opts) do
    append_opts = Keyword.merge(target.opts, append_timeout(opts))

    case Persistence.append(target.name, target.backend, stream_id, event, append_opts) do
      {:ok, [persisted]} ->
        if exact_event?(persisted, event),
          do: :ok,
          else: {:error, {:provider_route_evidence_commit_uncertain, :event_mismatch}}

      {:error, {:append_indeterminate, operation}} ->
        reconcile(target, stream_id, event, operation, append_opts)

      {:error, reason} ->
        {:error, {:provider_route_evidence_write_failed, reason}}

      _ ->
        {:error, :provider_route_evidence_write_failed}
    end
  end

  defp reconcile(target, stream_id, event, operation, opts) do
    case Persistence.reconcile_append(target.name, target.backend, operation, opts) do
      {:ok, {:committed, [persisted]}} ->
        if exact_event?(persisted, event),
          do: :ok,
          else: {:error, {:provider_route_evidence_commit_uncertain, :event_mismatch}}

      {:ok, :absent} ->
        case Persistence.append(target.name, target.backend, stream_id, event, opts) do
          {:ok, [persisted]} ->
            if exact_event?(persisted, event),
              do: :ok,
              else: {:error, {:provider_route_evidence_commit_uncertain, :event_mismatch}}

          {:error, {:append_indeterminate, operation}} ->
            {:error, {:provider_route_evidence_commit_uncertain, operation}}

          {:error, reason} ->
            {:error, {:provider_route_evidence_write_failed, reason}}

          _ ->
            {:error, :provider_route_evidence_write_failed}
        end

      {:error, reason} ->
        {:error, {:provider_route_evidence_commit_uncertain, reason}}

      _ ->
        {:error, {:provider_route_evidence_commit_uncertain, :reconciliation_unknown}}
    end
  end

  defp exact_event?(
         %Event{id: id, stream_id: stream_id, type: type, data: data, metadata: metadata},
         %Event{id: id, stream_id: stream_id, type: type, data: data, metadata: metadata}
       ),
       do: true

  defp exact_event?(_, _), do: false

  defp replay(target, now) do
    with {:ok, today} <- utc_date(now),
         {:ok, yesterday} <- Date.add(Date.from_iso8601!(today), -1) |> Date.to_iso8601() |> ok(),
         {:ok, core} <-
           replay_stream(
             target,
             @stream_prefix <> yesterday,
             ProviderRouteEvidenceCore.new(),
             now
           ),
         {:ok, core} <- replay_stream(target, @stream_prefix <> today, core, now) do
      {:ok, %{core: core, replayed_at: now}}
    end
  rescue
    _ -> {:error, :replay_malformed}
  end

  defp snapshot_part(:all, core, now) do
    with {:ok, snapshot} <- ProviderRouteEvidenceCore.snapshot(core, now) do
      {:ok, project_snapshot(snapshot)}
    end
  end

  defp snapshot_part(:route_failure, core, now) do
    with {:ok, failures} <- ProviderRouteEvidenceCore.snapshot_failures(core, now) do
      {:ok, project_failures(failures)}
    end
  end

  defp snapshot_part(:quota, core, now) do
    with {:ok, quotas} <- ProviderRouteEvidenceCore.snapshot_quotas(core, now) do
      {:ok, project_quotas(quotas)}
    end
  end

  defp snapshot_part(_, _, _), do: {:error, :malformed}

  defp block_after_commit(state, reason) do
    {:reply, {:error, reason}, %{state | status: {:blocked, reason}, state: nil}}
  end

  defp replay_stream(target, stream_id, core, now) do
    with {:ok, events} <- bounded_events(target, stream_id),
         {:ok, next} <-
           Enum.reduce_while(events, {:ok, core}, fn event, {:ok, acc} ->
             case event_to_map(event, stream_id) do
               {:ok, event_map} ->
                 case ProviderRouteEvidenceCore.reduce(acc, event_map, now) do
                   {:ok, value} -> {:cont, {:ok, value}}
                   {:error, reason} -> {:halt, {:error, reason}}
                 end

               :error ->
                 {:halt, {:error, :malformed}}
             end
           end) do
      {:ok, next}
    end
  end

  defp bounded_events(target, stream_id) do
    replay_until_quiet(target, stream_id, 0, [], 0)
  end

  # Ecto has no subscription API. Capture a head, read through it, and then
  # recheck the head; any concurrent append is read as a bounded delta before
  # the projection is admitted. A moving head after the fixed pass budget is
  # incomplete evidence and therefore fails closed.
  defp replay_until_quiet(_target, _stream_id, _head, _events, pass) when pass >= 3,
    do: {:error, :replay_incomplete}

  defp replay_until_quiet(target, stream_id, previous_head, events, pass) do
    head_opts = Keyword.merge(target.opts, direction: :forward)

    with {:ok, head} <-
           Persistence.stream_version(target.name, target.backend, stream_id, head_opts),
         true <- is_integer(head) and head >= previous_head and head <= @max_events,
         count = head - previous_head,
         {:ok, page} <- read_replay_page(target, stream_id, previous_head, head, count),
         {:ok, events} <- append_replay_page(events, page, previous_head, head),
         {:ok, latest} <-
           Persistence.stream_version(target.name, target.backend, stream_id, head_opts) do
      cond do
        latest == head ->
          if contiguous_events?(events, latest),
            do: {:ok, events},
            else: {:error, :replay_incomplete}

        latest > head and latest <= @max_events ->
          replay_until_quiet(target, stream_id, head, events, pass + 1)

        true ->
          {:error, :replay_incomplete}
      end
    else
      false -> {:error, :replay_incomplete}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :replay_incomplete}
    end
  end

  defp read_replay_page(_target, _stream_id, _previous_head, _head, 0), do: {:ok, []}

  defp read_replay_page(target, stream_id, previous_head, _head, count) do
    opts =
      Keyword.merge(target.opts,
        from: previous_head + 1,
        limit: count,
        direction: :forward
      )

    Persistence.read_stream(target.name, target.backend, stream_id, opts)
  end

  defp append_replay_page(events, page, previous_head, head)
       when is_list(events) and is_list(page) do
    expected = if head == previous_head, do: [], else: Enum.to_list((previous_head + 1)..head)

    if length(page) != length(expected) or
         Enum.any?(page, fn
           %Event{event_number: number} -> number <= previous_head or number > head
           _ -> true
         end) or
         Enum.map(page, & &1.event_number) != expected do
      {:error, :replay_incomplete}
    else
      merged = events ++ page
      if length(merged) <= @max_events, do: {:ok, merged}, else: {:error, :replay_incomplete}
    end
  end

  defp append_replay_page(_, _, _, _), do: {:error, :replay_incomplete}

  defp contiguous_events?(events, head) when is_list(events) do
    expected = if head == 0, do: [], else: Enum.to_list(1..head)
    length(events) == head and Enum.map(events, & &1.event_number) == expected
  end

  defp contiguous_events?(_, _), do: false

  defp event_to_map(%Event{stream_id: stream_id} = event, stream_id) do
    with {:ok, expected_id} <-
           ProviderRouteEvidenceCore.event_id(stream_id, event.type, event.data),
         true <- event.id == expected_id do
      {:ok,
       %{
         "id" => event.id,
         "stream_id" => event.stream_id,
         "event_number" => event.event_number,
         "type" => event.type,
         "data" => event.data,
         "metadata" => event.metadata
       }}
    else
      _ -> :error
    end
  end

  defp event_to_map(_, _), do: :error

  defp append_timeout([]), do: []
  defp append_timeout([{:append_timeout_ms, timeout}]), do: [append_timeout_ms: timeout]

  defp record(kind, attrs, opts) do
    case validate_record_opts(opts) do
      {:ok, opts} -> call({:record, kind, attrs, opts}, :infinity)
      {:error, reason} -> {:error, reason}
    end
  end

  defp snapshot_part(kind, opts) do
    with {:ok, opts} <- validate_snapshot_opts(opts) do
      case call({:snapshot, kind, opts}, 5_000) do
        {:error, :provider_route_evidence_unavailable} -> {:error, :unavailable}
        result -> result
      end
    end
  end

  defp validate_record_opts([]), do: {:ok, []}

  defp validate_record_opts([{:append_timeout_ms, timeout} = option])
       when is_integer(timeout) and timeout > 0 and timeout <= 60_000,
       do: {:ok, [option]}

  defp validate_record_opts(_), do: {:error, :invalid_options}

  defp validate_snapshot_opts([]), do: {:ok, []}

  defp validate_snapshot_opts([{:now, %DateTime{} = now} = option]) do
    if valid_datetime?(now), do: {:ok, [option]}, else: {:error, :invalid_options}
  end

  defp validate_snapshot_opts(_), do: {:error, :invalid_options}

  defp snapshot_now([]), do: {:ok, DateTime.utc_now()}
  defp snapshot_now([{:now, now}]), do: {:ok, now}

  defp valid_datetime?(%DateTime{} = value) do
    is_binary(DateTime.to_iso8601(value))
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp utc_date(%DateTime{} = now), do: {:ok, Date.to_iso8601(DateTime.to_date(now))}
  defp ok(value), do: {:ok, value}

  defp project_snapshot(%{failures: failures, quotas: quotas}) do
    %{
      "route_failures" => project_failures(failures),
      "quota_status" => project_quotas(quotas)
    }
  end

  defp project_failures(failures) do
    Map.new(failures, fn {route, entry} ->
      {route, Map.update!(entry, "class", &String.to_existing_atom/1)}
    end)
  end

  defp project_quotas(quotas) do
    Map.new(quotas, fn {route, entry} ->
      {route, %{"available" => false, "available_at" => entry["available_at"]}}
    end)
  end
end
