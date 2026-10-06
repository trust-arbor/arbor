defmodule ConversationKit.Arbor.Connection do
  @moduledoc """
  Private connection owner for native conversation surfaces.

  Credentials and transport callbacks stay here. A surface receives only a
  bounded display snapshot via `{:conversation_updated, pid, snapshot}`. Host
  calls run in a monitored worker, keeping input and owner cleanup responsive.
  Polling authenticates every read; submissions are never retried automatically.
  """
  use GenServer
  alias ConversationKit.Arbor
  alias ConversationKit.Controls

  @invalidating [
    :unauthorized,
    :conversation_scope_changed,
    :scope_mismatch,
    :conflicting_response,
    :invalid_history_page,
    :invalid_history_entry,
    :invalid_command_response,
    :invalid_command_outcome,
    :unsupported_command_status,
    :invalid_transport_response,
    :invalid_control_response
  ]

  def start(opts, owner \\ self()), do: GenServer.start(__MODULE__, {opts, owner})
  def snapshot(pid), do: GenServer.call(pid, :snapshot)
  def act(pid, action, input \\ nil), do: GenServer.cast(pid, {:act, action, input})

  def close(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
  end

  @impl true
  def init({opts, owner}) do
    Process.flag(:sensitive, true)
    interval = Keyword.get(opts, :poll_interval_ms, 1_000)
    timeout = Keyword.get(opts, :operation_timeout_ms, 10_000)
    notice_limit = Keyword.get(opts, :notice_page_limit, 8)

    with true <- is_pid(owner) and Process.alive?(owner),
         true <- is_integer(interval) and interval in 100..60_000,
         true <- is_integer(timeout) and timeout in 100..60_000,
         true <- is_integer(notice_limit) and notice_limit in 1..50,
         true <- is_boolean(Keyword.get(opts, :approval_answer_allowed, false)),
         {:ok, client} <- new_client(opts) do
      state = %{
        opts: opts,
        owner: owner,
        monitor: Process.monitor(owner),
        client: client,
        interval: interval,
        timeout: timeout,
        timer: nil,
        job: nil,
        queued: nil,
        connected: true,
        attached: false,
        browsing: false,
        window: empty_window(),
        pending: nil,
        receipt: nil,
        ack: nil,
        error: nil,
        private_cleared: false,
        controls_available: false,
        control_cursor: nil,
        notice_limit: notice_limit,
        notice_anchor: [],
        notice_window: empty_notice_window(),
        notice_supported: nil,
        notices_status: :unavailable,
        approval_answer_allowed: Keyword.get(opts, :approval_answer_allowed, false)
      }

      {:ok, state, {:continue, :connect}}
    else
      _ -> {:stop, :invalid_options}
    end
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, begin_window(state, [])}

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, show(state), state}

  @impl true
  def handle_cast({:act, :disconnect, _}, state) do
    next =
      state
      |> stop_job()
      |> disconnect()
      |> clear_controls()
      |> clear_notices()
      |> Map.put(:connected, false)

    {:noreply, publish(next)}
  end

  def handle_cast({:act, :reconnect, _}, state) do
    next = stop_job(state)

    case if(next.client, do: {:ok, next.client}, else: new_client(next.opts)) do
      {:ok, client} ->
        # Retain an unresolved request's identity/text only in the same binding;
        # reconnect establishes the scope before an explicit retry is allowed.
        next = %{
          next
          | client: Arbor.clear_notices(client),
            connected: true,
            attached: false,
            error: nil,
            private_cleared: false,
            notice_supported: nil,
            notices_status: :unavailable,
            notice_window: empty_notice_window()
        }

        {:noreply, begin_window(next, current_window_options(next))}

      {:error, reason} ->
        {:noreply, publish(failed(next, reason))}
    end
  end

  def handle_cast({:act, action, input}, %{job: %{kind: kind}, queued: nil} = state)
      when kind in [:window, :notices] and
             action in [
               :send,
               :retry,
               :restore,
               :older,
               :newer,
               :latest,
               :refresh,
               :cancel,
               :choose,
               :approve,
               :more_activity,
               :latest_activity,
               :older_notices,
               :latest_notices
             ] do
    {:noreply, publish(%{state | queued: {action, input}})}
  end

  def handle_cast({:act, _, _}, %{job: job} = state) when not is_nil(job) do
    {:noreply, publish(%{state | error: "An operation is still pending."})}
  end

  def handle_cast({:act, _, _}, %{connected: false} = state),
    do: {:noreply, publish(%{state | error: "Reconnect to continue."})}

  def handle_cast({:act, :send, %{id: id, text: text} = input}, state)
      when map_size(input) == 2 do
    if state.attached and is_nil(state.pending) and Arbor.validate_command(id, text) == :ok do
      next = %{state | pending: %{id: id, text: text, attempts: 1}, error: nil}
      {:noreply, begin_job(next, :submit, fn -> Arbor.submit(state.client, id, text) end)}
    else
      {:noreply, publish(%{state | error: "Check the previous delivery before sending."})}
    end
  end

  def handle_cast({:act, :retry, _}, %{pending: pending, attached: true} = state)
      when not is_nil(pending) do
    client = state.client
    next = %{state | pending: %{pending | attempts: pending.attempts + 1}}

    {:noreply,
     begin_job(next, :retry, fn ->
       case Arbor.command(client, pending.id) do
         {:ok, next, %{"status" => "admitted"}} -> Arbor.submit(next, pending.id, pending.text)
         {:error, :not_found} -> Arbor.submit(client, pending.id, pending.text)
         other -> other
       end
     end)}
  end

  def handle_cast({:act, :restore, %{id: id, text: text}}, %{attached: true} = state) do
    if Arbor.validate_command(id, text) == :ok and
         (is_nil(state.pending) or (state.pending.id == id and state.pending.text == text)) do
      next = %{state | pending: %{id: id, text: text, attempts: 2}}
      {:noreply, begin_job(next, :restore, fn -> Arbor.command(state.client, id) end)}
    else
      {:noreply,
       publish(%{
         state
         | error: "Check the existing unresolved delivery before restoring another request."
       })}
    end
  end

  def handle_cast({:act, action, input}, state) when action in [:cancel, :choose, :approve] do
    with true <- state.attached and state.controls_available,
         true <- action != :approve or state.approval_answer_allowed,
         {:ok, intent} <- control_intent(state.client.controls, action, input) do
      client = state.client
      cursor = state.control_cursor

      {:noreply,
       begin_job(state, :control, fn ->
         case execute_intent(client, intent) do
           {:ok, client, _answer} ->
             case Arbor.controls(client, control_options(cursor)) do
               {:ok, client} -> {:ok, client, true}
               {:error, reason} when reason in @invalidating -> {:error, reason}
               {:error, _} -> {:ok, Arbor.clear_controls(client), false}
             end

           error ->
             error
         end
       end)}
    else
      _ ->
        {:noreply,
         publish(%{
           state
           | error:
               if(action == :approve and not state.approval_answer_allowed,
                 do: "This approval needs browser review.",
                 else: "Refresh controls before trying this action again."
               )
         })}
    end
  end

  def handle_cast({:act, :more_activity, _}, %{controls_available: true} = state) do
    case state.client.controls_discovery.next_cursor do
      nil ->
        {:noreply, state}

      cursor ->
        {:noreply, begin_window(%{state | control_cursor: cursor}, current_window_options(state))}
    end
  end

  def handle_cast({:act, :latest_activity, _}, state),
    do: {:noreply, begin_window(%{state | control_cursor: nil}, current_window_options(state))}

  def handle_cast(
        {:act, :older_notices, _},
        %{notice_window: %{has_older: true, next_before: before, through: through}} = state
      ) do
    anchor = [before: before, through: through]
    {:noreply, begin_window(%{state | notice_anchor: anchor}, current_window_options(state))}
  end

  def handle_cast({:act, :latest_notices, _}, state),
    do: {:noreply, begin_window(%{state | notice_anchor: []}, current_window_options(state))}

  def handle_cast({:act, :older, _}, %{window: %{has_older: true, first: first}} = state) do
    {:noreply, begin_window(%{state | browsing: true}, before: first, through: state.window.head)}
  end

  def handle_cast({:act, :newer, _}, %{window: %{has_newer: true, last: last}} = state) do
    {:noreply, begin_window(state, after: last, through: state.window.head)}
  end

  def handle_cast({:act, :latest, _}, state),
    do: {:noreply, begin_window(%{state | browsing: false}, [])}

  def handle_cast({:act, :refresh, _}, state),
    do: {:noreply, begin_window(state, current_window_options(state))}

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info(:poll, state) do
    state = %{state | timer: nil}

    if state.connected and is_nil(state.job) do
      {:noreply, begin_window(state, current_window_options(state))}
    else
      {:noreply, schedule(state)}
    end
  end

  def handle_info({:operation_result, tag, result}, %{job: %{tag: tag} = job} = state) do
    Process.demonitor(job.ref, [:flush])
    Process.cancel_timer(job.timer)
    state = %{state | job: nil}
    next = apply_result(state, job.kind, result) |> publish()

    case next.queued do
      {action, input} when next.connected ->
        handle_cast({:act, action, input}, %{next | queued: nil})

      _
      when job.kind == :window and next.connected and next.attached and
             next.notice_supported != false ->
        if match?({:ok, _, _, _, _}, result),
          do: {:noreply, begin_notices(%{next | queued: nil})},
          else: {:noreply, next |> Map.put(:queued, nil) |> schedule()}

      _ ->
        {:noreply, next |> Map.put(:queued, nil) |> schedule()}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{job: %{ref: ref, kind: :notices}} = state
      ),
      do: state |> stop_notice_job() |> clear_notices() |> publish() |> resume_queued()

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{job: %{ref: ref}} = state),
    do:
      {:noreply,
       state |> stop_job() |> failed(:conversation_unavailable) |> publish() |> schedule()}

  def handle_info({:operation_timeout, tag}, %{job: %{tag: tag, kind: :notices}} = state),
    do: state |> stop_notice_job() |> clear_notices() |> publish() |> resume_queued()

  def handle_info({:operation_timeout, tag}, %{job: %{tag: tag}} = state),
    do: {:noreply, state |> stop_job() |> failed(:transport_timeout) |> publish() |> schedule()}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state |> stop_job() |> disconnect()
    :ok
  end

  @impl true
  def format_status(status), do: Map.put(status, :state, %{connection: :private})

  defp begin_window(state, opts) do
    client = state.client

    begin_job(state, :window, fn ->
      with {:ok, client, window} <- Arbor.window(client, opts),
           {:ok, client, receipt} <- read_receipt(client, state.receipt) do
        case Arbor.controls(client, control_options(state.control_cursor)) do
          {:ok, next} -> {:ok, next, window, receipt, true}
          {:error, reason} when reason in @invalidating -> {:error, reason}
          {:error, _} -> {:ok, Arbor.clear_controls(client), window, receipt, false}
        end
      end
    end)
  end

  defp read_receipt(client, %{"id" => id, "status" => status})
       when status in ["admitted", "dispatch_started"], do: Arbor.command(client, id)

  defp read_receipt(client, receipt), do: {:ok, client, receipt}

  defp begin_notices(state) do
    client = state.client
    opts = Keyword.put(state.notice_anchor, :limit, state.notice_limit)

    begin_job(%{state | notices_status: :checking}, :notices, fn ->
      Arbor.notices(client, opts)
    end)
  end

  defp control_options(nil), do: []
  defp control_options(cursor), do: [cursor: cursor]

  defp control_intent(snapshot, action, input) when is_map(input) and not is_struct(input) do
    keys =
      case action do
        :cancel -> [:command_id]
        :choose -> [:command_id, :request_id, :operation_id, :revision, :choice_id]
        :approve -> [:command_id, :request_id, :operation_id, :revision, :decision, :note]
      end

    if Enum.sort(Map.keys(input)) == Enum.sort(keys) do
      value = Map.new(input, fn {key, value} -> {Atom.to_string(key), value} end)
      Controls.intent(snapshot, Map.put(value, "kind", Atom.to_string(action)))
    else
      {:error, :invalid_action}
    end
  end

  defp control_intent(_, _, _), do: {:error, :invalid_action}

  defp execute_intent(client, %{"name" => "conversation.cancel", "input" => input}),
    do: Arbor.cancel(client, input["command_id"])

  defp execute_intent(client, %{"name" => "interaction.choose", "input" => input}) do
    Arbor.answer_choice(client, %{
      command_id: input["command_id"],
      request_id: input["request_id"],
      operation_id: input["operation_id"],
      revision: input["revision"],
      choice_id: input["choice_id"]
    })
  end

  defp execute_intent(client, %{"name" => "approval.answer", "input" => input}) do
    Arbor.answer_approval(client, %{
      command_id: input["command_id"],
      request_id: input["request_id"],
      operation_id: input["operation_id"],
      revision: input["revision"],
      decision:
        case input["decision"] do
          "approved" -> :approve
          "denied" -> :deny
          "rework" -> :rework
        end,
      note: input["note"]
    })
  end

  defp begin_job(state, kind, fun) do
    if state.timer, do: Process.cancel_timer(state.timer)
    owner = self()
    tag = make_ref()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:sensitive, true)
        send(owner, {:operation_result, tag, fun.()})
      end)

    timer = Process.send_after(self(), {:operation_timeout, tag}, state.timeout)
    publish(%{state | timer: nil, job: %{pid: pid, ref: ref, tag: tag, kind: kind, timer: timer}})
  end

  defp apply_result(state, :window, {:ok, client, window, receipt, available}) do
    %{
      state
      | client: client,
        window: window,
        receipt: receipt,
        attached: true,
        controls_available: available,
        error: nil,
        private_cleared: false
    }
  end

  defp apply_result(state, :control, {:ok, client, available}),
    do: %{
      state
      | client: client,
        controls_available: available,
        error:
          if(available, do: nil, else: "Controls are unavailable. Refresh before another action.")
    }

  defp apply_result(state, :notices, {:ok, client, window}),
    do: %{
      state
      | client: client,
        notice_window: window,
        notice_supported: true,
        notices_status: :available
    }

  defp apply_result(state, :notices, {:error, :notice_subject_required}),
    do: %{clear_notices(state) | notice_supported: false, notices_status: :unsupported}

  defp apply_result(state, :notices, {:error, reason}) when reason not in @invalidating,
    do: clear_notices(state)

  defp apply_result(state, :control, {:error, reason}) when reason not in @invalidating,
    do: %{
      clear_controls(state)
      | error:
          if(reason == :approval_answer_required,
            do: "This approval needs browser review.",
            else: "The action was not confirmed. Refresh before an explicit retry."
          )
    }

  defp apply_result(state, kind, {:ok, client, receipt})
       when kind in [:submit, :retry, :restore] do
    if state.pending.text == receipt["input_text"] do
      ack = Map.take(state.pending, [:id, :text])
      %{state | client: client, receipt: receipt, pending: nil, ack: ack, error: nil}
    else
      failed(state, :conflicting_response)
    end
  end

  defp apply_result(%{pending: %{attempts: 1}} = state, :submit, {:error, reason})
       when reason in [:invalid_command, :command_conflict],
       do: %{
         state
         | pending: nil,
           error: "The request was rejected. Edit the message before sending again."
       }

  defp apply_result(%{pending: %{attempts: 1}} = state, :submit, {:error, :agent_not_running}),
    do: %{
      state
      | pending: nil,
        receipt: nil,
        ack: nil,
        error: "This agent is not running. Resume it in Console, then send again."
    }

  defp apply_result(state, _kind, {:error, reason}), do: failed(state, reason)
  defp apply_result(state, _, _), do: failed(state, :invalid_transport_response)

  defp failed(state, reason) when reason in @invalidating do
    disconnect(state)

    %{
      state
      | client: nil,
        connected: false,
        attached: false,
        pending: nil,
        receipt: nil,
        queued: nil,
        window: empty_window(),
        ack: nil,
        private_cleared: true,
        controls_available: false,
        control_cursor: nil,
        notice_anchor: [],
        notice_window: empty_notice_window(),
        notice_supported: nil,
        notices_status: :unavailable,
        error:
          "Conversation access or ownership changed. Private data was cleared. Reconnect to continue."
    }
  end

  defp failed(state, reason) when reason in [:invalid_command, :command_conflict],
    do: %{state | error: "This attempt was refused. Earlier delivery remains unconfirmed."}

  defp failed(state, :agent_not_running),
    do: %{
      state
      | error:
          "This agent is not running. Earlier delivery remains unconfirmed. Resume it in Console, then check the saved request ID."
    }

  defp failed(state, :not_found),
    do: %{
      clear_controls(state)
      | error: "Delivery is unconfirmed. Retry checks the saved request ID."
    }

  defp failed(state, _),
    do: %{
      (state
       |> clear_controls()
       |> clear_notices())
      | error: "The host could not confirm this operation. Retry preserves the saved request ID."
    }

  defp new_client(opts) do
    with {:ok, caller} <- Keyword.fetch(opts, :caller),
         {:ok, target} <- Keyword.fetch(opts, :target),
         {:ok, proof} <- Keyword.fetch(opts, :proof_provider) do
      adapter_opts = opts |> Keyword.get(:adapter_options, []) |> Keyword.put_new(:page_limit, 20)
      Arbor.new(caller, target, proof, adapter_opts)
    else
      _ -> {:error, :invalid_options}
    end
  end

  defp publish(state) do
    send(state.owner, {:conversation_updated, self(), show(state)})
    %{state | ack: nil}
  end

  defp show(state) do
    %{
      projection: if(state.client, do: Arbor.projection(state.client), else: empty_projection()),
      engagement_id: if(state.client, do: state.client.engagement),
      controls:
        if(state.client, do: Arbor.controls_projection(state.client), else: empty_controls()),
      controls_available: state.controls_available and state.connected and state.attached,
      notices_status: state.notices_status,
      notice_window: state.notice_window,
      controls_discovery:
        if(state.client,
          do: Map.take(state.client.controls_discovery, [:has_more, :incomplete, :truncated]),
          else: %{has_more: false, incomplete: false, truncated: false}
        ),
      approval_answer_allowed: state.approval_answer_allowed,
      control_action_allowed:
        state.connected and state.attached and state.controls_available and is_nil(state.queued) and
          (is_nil(state.job) or state.job.kind in [:window, :notices]),
      window: state.window,
      connected: state.connected and state.attached,
      busy: not is_nil(state.job),
      error: state.error,
      private_cleared: state.private_cleared,
      pending_id: if(state.pending, do: state.pending.id),
      receipt: safe_receipt(state.receipt),
      ack: state.ack,
      send_allowed:
        state.connected and state.attached and is_nil(state.pending) and is_nil(state.queued) and
          (is_nil(state.job) or state.job.kind in [:window, :notices]),
      retry_allowed:
        state.connected and state.attached and not is_nil(state.pending) and is_nil(state.job)
    }
  end

  defp schedule(%{connected: true, timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :poll, state.interval)}

  defp schedule(state), do: state

  # Refresh authenticates the current browsing page without moving its anchor.
  # Following newly appended messages is an explicit :latest action.
  defp current_window_options(%{browsing: true} = state),
    do: [after: max(state.window.first - 1, 0), through: state.window.head]

  defp current_window_options(_state), do: []

  defp stop_job(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    if state.job do
      Process.exit(state.job.pid, :kill)
      Process.demonitor(state.job.ref, [:flush])
      Process.cancel_timer(state.job.timer)
    end

    %{state | timer: nil, job: nil, queued: nil}
  end

  defp stop_notice_job(state) do
    queued = state.queued
    %{stop_job(state) | queued: queued}
  end

  defp resume_queued(%{queued: {action, input}, connected: true} = state),
    do: handle_cast({:act, action, input}, %{state | queued: nil})

  defp resume_queued(state), do: {:noreply, %{state | queued: nil} |> schedule()}

  defp disconnect(state) do
    case Keyword.get(state.opts, :disconnect) do
      fun when is_function(fun, 0) -> fun.()
      _ -> :ok
    end

    state
  rescue
    _ -> state
  catch
    _, _ -> state
  end

  defp clear_controls(state),
    do: %{
      state
      | client: if(state.client, do: Arbor.clear_controls(state.client)),
        controls_available: false
    }

  defp clear_notices(state),
    do: %{
      state
      | client: if(state.client, do: Arbor.clear_notices(state.client)),
        notice_window: empty_notice_window(),
        notices_status: if(state.notice_supported == false, do: :unsupported, else: :unavailable)
    }

  defp safe_receipt(nil), do: nil

  defp safe_receipt(receipt),
    do:
      Map.take(
        receipt,
        ~w(id status input_text result_text reason admitted_cursor updated_cursor)
      )

  defp empty_controls do
    {:ok, projection} = Controls.project(Controls.new())
    projection
  end

  defp empty_window, do: %{head: 0, first: 0, last: 0, has_older: false, has_newer: false}

  defp empty_notice_window,
    do: %{head: 0, through: 0, has_older: false, next_before: nil, complete: false}

  defp empty_projection,
    do: %{"messages" => [], "deliveries" => [], "notices" => [], "blocks" => [], "speech" => []}
end
