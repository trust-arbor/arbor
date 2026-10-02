defmodule ConversationDemo.ArborClient do
  @moduledoc """
  Per-surface server owner of the trusted Arbor binding and replay positions.

  Renderers receive only closed snapshots and this process's pid. Credentials,
  proof callbacks, destinations and adapter options stay in the owner. Every
  operation delegates proof acquisition to the adapter; no proof is cached here.
  """
  use GenServer
  alias ConversationKit.Arbor

  def start(opts, owner \\ self()), do: GenServer.start(__MODULE__, {opts, owner})
  def snapshot(pid), do: GenServer.call(pid, :snapshot)
  def act(pid, action, text \\ nil), do: GenServer.call(pid, {:act, action, text}, 60_000)

  @impl true
  def init({opts, owner}) do
    monitor = Process.monitor(owner)

    state = %{
      opts: opts,
      monitor: monitor,
      client: nil,
      attached: false,
      connected: false,
      error: nil,
      pending: nil,
      unresolved_id: nil,
      accepted_id: nil,
      private_cleared: false
    }

    {:ok, connect(state)}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, show(state), state}

  def handle_call({:act, :disconnect, _}, _from, state) do
    disconnect_transport(state)
    next = %{state | connected: false, error: nil}
    {:reply, {:ok, show(next)}, next}
  end

  def handle_call({:act, :reconnect, _}, _from, state) do
    next = if state.client, do: refresh(%{state | connected: true}), else: connect(state)
    {:reply, reply(next), next}
  end

  def handle_call({:act, _, _}, _from, %{connected: false} = state) do
    next = %{state | error: "Disconnected. Reconnect before sending or refreshing."}
    {:reply, {:error, show(next)}, next}
  end

  def handle_call({:act, :refresh, _}, _from, state) do
    next = refresh(state)
    {:reply, reply(next), next}
  end

  def handle_call({:act, :send, text}, _from, state) do
    next =
      cond do
        state.pending ->
          %{state | error: "An admission is unresolved. Check or retry the saved request first."}

        not is_binary(text) or String.trim(text) == "" ->
          %{state | error: "Enter a message."}

        true ->
          pending = %{
            id: "surface-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
            text: text,
            attempts: 0
          }

          submit(%{state | pending: pending})
      end

    result =
      if next.accepted_id != state.accepted_id and not next.private_cleared,
        do: {:ok, show(next), %{accepted_text: text}},
        else: reply(next)

    {:reply, result, next}
  end

  def handle_call({:act, :retry, _}, _from, %{pending: nil} = state) do
    next = %{state | error: "There is no unresolved admission to retry."}
    {:reply, {:error, show(next)}, next}
  end

  def handle_call({:act, :retry, _}, _from, state) do
    next =
      case Arbor.command(state.client, state.pending.id) do
        {:ok, client, %{"status" => "admitted"}} ->
          # Admission can survive a failed worker start. Repeating the same ID
          # lets the host claim it once; a new ID would risk a duplicate turn.
          submit(%{state | client: client})

        {:ok, client, _delivery} ->
          refresh(%{
            state
            | client: client,
              accepted_id: state.pending.id,
              pending: nil,
              error: nil
          })

        {:error, :not_found} ->
          submit(state)

        {:error, reason} ->
          failed(state, reason)
      end

    result =
      if next.accepted_id != state.accepted_id and not next.private_cleared,
        do: {:ok, show(next), %{accepted_text: state.pending.text}},
        else: reply(next)

    {:reply, result, next}
  end

  def handle_call({:act, _, _}, _from, state), do: {:reply, {:error, show(state)}, state}

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state),
    do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, state), do: disconnect_transport(state)

  @impl true
  def format_status(status), do: Map.put(status, :state, %{connection: :private})

  defp connect(state) do
    with {:ok, caller} <- Keyword.fetch(state.opts, :caller),
         {:ok, target} <- Keyword.fetch(state.opts, :target),
         {:ok, provider} <- Keyword.fetch(state.opts, :proof_provider),
         {:ok, client} <-
           Arbor.new(caller, target, provider, Keyword.get(state.opts, :adapter_options, [])) do
      next =
        refresh(%{
          state
          | client: client,
            attached: false,
            connected: true,
            error: nil,
            private_cleared: false
        })

      # A first connection has no ownership fence until sync succeeds. A
      # transient read failure must not enable an unfenced first submission.
      if is_nil(next.error), do: next, else: %{next | connected: false}
    else
      _ ->
        %{state | error: "A trusted Arbor connection has not been configured.", connected: false}
    end
  end

  defp submit(state) do
    state = put_in(state.pending.attempts, state.pending.attempts + 1)

    case Arbor.submit(state.client, state.pending.id, state.pending.text) do
      {:ok, client, _delivery} ->
        refresh(%{
          state
          | client: client,
            accepted_id: state.pending.id,
            pending: nil,
            error: nil
        })

      {:error, reason}
      when reason in [:invalid_command, :command_conflict, :unsupported_conversation_capability] ->
        if state.pending.attempts == 1 do
          %{
            state
            | pending: nil,
              error: "The request was rejected. Edit the message before sending again."
          }
        else
          %{state | error: "This retry was refused. Earlier delivery remains unresolved."}
        end

      {:error, reason} ->
        failed(state, reason)
    end
  end

  defp refresh(state) do
    case Arbor.sync(state.client) do
      {:ok, client} ->
        %{state | client: client, attached: true, error: nil, private_cleared: false}

      {:error, reason} ->
        next = failed(state, reason)
        # Repeated failed reconnects cannot advertise an unfenced first attach
        # as ready. Previously attached clients retain their scope and cache.
        if state.attached, do: next, else: %{next | connected: false}
    end
  end

  defp failed(state, :unauthorized) do
    disconnect_transport(state)

    # Keep only a non-authorizing reference when a submission may have taken
    # effect before access was lost. Never retain its text or replay it on
    # reconnect; this reference lasts only for this renderer owner's lifetime.
    unresolved_id =
      case state.pending do
        %{id: id, attempts: attempts} when attempts > 0 -> id
        _ -> state.unresolved_id
      end

    %{
      state
      | client: nil,
        pending: nil,
        unresolved_id: unresolved_id,
        accepted_id: nil,
        connected: false,
        private_cleared: true,
        error: "Access unavailable. Private conversation data has been cleared."
    }
  end

  defp failed(state, :conversation_scope_changed) do
    disconnect_transport(state)

    %{
      state
      | client: nil,
        pending: nil,
        accepted_id: nil,
        connected: false,
        private_cleared: true,
        error:
          "Conversation ownership changed. Private data and pending retry were cleared. Reconnect explicitly."
    }
  end

  defp failed(state, reason)
       when reason in [
              :scope_mismatch,
              :scope_or_command_mismatch,
              :conflicting_response,
              :invalid_history_page,
              :invalid_history_entry,
              :invalid_command_page,
              :invalid_page_bounds,
              :invalid_command_event,
              :invalid_command_transition,
              :invalid_command_response,
              :invalid_command_outcome,
              :unsupported_command_status,
              :unsupported_event_kind,
              :invalid_transport_response
            ] do
    disconnect_transport(state)

    %{
      state
      | client: nil,
        pending: nil,
        accepted_id: nil,
        connected: false,
        private_cleared: true,
        error: "The host response could not be verified. Reconnect before continuing."
    }
  end

  defp failed(state, :not_found), do: %{state | error: "The saved request was not found."}

  defp failed(state, :transport_not_attached) do
    %{state | connected: false, error: "Reconnect before checking the saved request."}
  end

  defp failed(state, _reason) do
    %{
      state
      | error: "The host could not confirm this operation. Refresh or check the saved request."
    }
  end

  defp reply(%{error: nil} = state), do: {:ok, show(state)}
  defp reply(state), do: {:error, show(state)}

  defp show(state) do
    %{
      projection: if(state.client, do: Arbor.projection(state.client), else: empty_projection()),
      position:
        if(state.client, do: Arbor.position(state.client), else: %{history: 0, commands: 0}),
      sync_status:
        if(state.client,
          do: Arbor.sync_status(state.client),
          else: %{history: %{has_more: false, head: 0}, commands: %{has_more: false, head: 0}}
        ),
      connected: state.connected,
      error: display_error(state),
      private_cleared: state.private_cleared,
      pending_id: if(state.pending, do: state.pending.id),
      send_allowed: state.connected and is_nil(state.pending),
      retry_allowed: state.connected and not is_nil(state.pending)
    }
  end

  defp empty_projection,
    do: %{"messages" => [], "deliveries" => [], "blocks" => [], "speech" => []}

  defp display_error(%{unresolved_id: nil} = state), do: state.error

  defp display_error(state) do
    reference = "Delivery unconfirmed. Reference: #{state.unresolved_id}."
    if state.error, do: reference <> " " <> state.error, else: reference
  end

  defp disconnect_transport(state) do
    case Keyword.get(state.opts, :disconnect) do
      fun when is_function(fun, 0) -> fun.()
      _ -> :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
