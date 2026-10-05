defmodule Arbor.Comms.ConversationActivity do
  @moduledoc """
  Rebuildable durable command discovery. The journal remains the authority.

  Client reads consult bounded indexed rows and source/index watermarks. They
  enqueue background catch-up, never reconstruct history in the caller. One
  supervised worker advances a durable watermark in contiguous 100-event pages.
  """
  use GenServer
  alias Arbor.Comms.{Config, ConversationJournal, ConversationJournalCore}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def enqueue(scope) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:project, scope})
    :ok
  end

  def read(scope, opts \\ []) do
    with :ok <- ConversationJournalCore.validate_scope(scope),
         {:ok, page} <-
           apply(port(), :read_conversation_commands, [
             ConversationJournal.index_scope(scope),
             opts
           ]),
         {:ok, source} <- ConversationJournal.source_head(scope),
         true <- page.watermark <= source do
      enqueue(scope)

      commands =
        Enum.map(page.commands, fn row ->
          cancellation = %{status: decode_cancel(row.cancellation_status)}

          cancellation =
            if row.cancellation_termination,
              do:
                Map.put(
                  cancellation,
                  :termination,
                  decode_termination(row.cancellation_termination)
                ),
              else: cancellation

          %{
            command_id: row.command_id,
            task_id: ConversationJournalCore.task_id(scope, row.command_id),
            delivery_status: decode_delivery(row.delivery_status),
            cancellation: cancellation,
            admitted_cursor: row.admitted_event_number,
            execution: :not_observed
          }
        end)

      {:ok,
       %{
         commands: commands,
         source_watermark: source,
         index_watermark: page.watermark,
         incomplete: page.watermark < source,
         has_more: page.has_more,
         next_cursor: page.next_cursor,
         engagement_id: scope.engagement_id
       }}
    else
      _ -> {:error, :conversation_unavailable}
    end
  rescue
    _ -> {:error, :conversation_unavailable}
  catch
    _, _ -> {:error, :conversation_unavailable}
  end

  defp port, do: Config.conversation_command_index_persistence_module()
  defp decode_cancel("none"), do: :none
  defp decode_cancel("requested"), do: :requested
  defp decode_cancel("confirmed"), do: :confirmed
  defp decode_delivery("admitted"), do: :admitted
  defp decode_delivery("dispatch_started"), do: :dispatch_started
  defp decode_delivery("completed"), do: :completed
  defp decode_delivery("uncertain"), do: :uncertain
  defp decode_termination("never_dispatched"), do: :never_dispatched
  defp decode_termination("queued_removed"), do: :queued_removed
  defp decode_termination("engine_terminated"), do: :engine_terminated

  @max_pending_scopes 1_024

  @impl true
  def init(_opts), do: {:ok, %{pending: %{}, order: [], scheduled: false}}

  @impl true
  def handle_cast({:project, scope}, state) do
    stream = ConversationJournalCore.stream_id(scope)

    if ConversationJournalCore.validate_scope(scope) == :ok and
         (Map.has_key?(state.pending, stream) or map_size(state.pending) < @max_pending_scopes) do
      new? = not Map.has_key?(state.pending, stream)

      pending =
        Map.put_new(state.pending, stream, %{
          scope: scope,
          retry_at: System.monotonic_time(:millisecond)
        })

      order = if new?, do: state.order ++ [stream], else: state.order
      unless state.scheduled, do: send(self(), :project)
      {:noreply, %{state | pending: pending, order: order, scheduled: true}}
    else
      # Discovery reports the durable lag; a later read can enqueue after the
      # bounded worker backlog drains. Journal admission is never refused here.
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:project, state) do
    now = System.monotonic_time(:millisecond)
    stream = Enum.find(state.order, &(state.pending[&1].retry_at <= now))

    next =
      if stream do
        entry = state.pending[stream]
        result = project(entry.scope)
        order = Enum.reject(state.order, &(&1 == stream))

        if result == :done do
          %{state | pending: Map.delete(state.pending, stream), order: order}
        else
          retry_at = if result == :retry, do: now + 5_000, else: now

          %{
            state
            | pending: Map.put(state.pending, stream, %{entry | retry_at: retry_at}),
              order: order ++ [stream]
          }
        end
      else
        state
      end

    if next.order == [] do
      {:noreply, %{next | scheduled: false}}
    else
      ready = Enum.min(Enum.map(next.order, &next.pending[&1].retry_at))
      Process.send_after(self(), :project, max(ready - System.monotonic_time(:millisecond), 0))
      {:noreply, %{next | scheduled: true}}
    end
  end

  defp project(scope) do
    index_scope = ConversationJournal.index_scope(scope)

    with {:ok, watermark} <- apply(port(), :conversation_command_index_watermark, [index_scope]),
         {:ok, page} <- ConversationJournal.projection_page(scope, watermark),
         :ok <- commit_page(index_scope, page) do
      if page.to < page.head, do: :more, else: :done
    else
      _ -> :retry
    end
  rescue
    _ -> :retry
  catch
    _, _ -> :retry
  end

  defp commit_page(_scope, %{from: same, to: same}), do: :ok

  defp commit_page(scope, page) do
    case apply(port(), :project_conversation_commands, [
           scope,
           page.rows,
           %{from: page.from, to: page.to}
         ]) do
      :ok -> :ok
      {:ok, _} -> :ok
      _ -> :error
    end
  end
end
