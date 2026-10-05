defmodule ArborBreeze.Controller do
  @moduledoc """
  Private owner connecting one native surface to ConversationKit. Target changes
  retire the previous owner before acquiring a fresh binding. Display snapshots
  never contain credentials, login handles or proof callbacks.
  """
  use GenServer
  alias Arbor.Client
  alias ArborBreeze.{Hints, Lease}
  alias ConversationKit.Arbor.{Connection, Gateway}

  @acquisition_cleanup_ms 45_000
  # One shared acquisition wait, pending login cancellation (5s), and at most
  # two resource sets (Connection 5s + DOWN 1s + Gateway 9s + DOWN 1s + lease 6s).
  # 45 + 5 + 2 * 22 = 94s; allow 6s for scheduling and the final owner DOWN.
  @close_timeout_ms 100_000

  @actions [
    :send,
    :retry,
    :refresh,
    :disconnect,
    :reconnect,
    :older,
    :newer,
    :latest,
    :cancel,
    :choose,
    :more_activity,
    :latest_activity,
    :older_notices,
    :latest_notices
  ]
  def start(options, owner \\ self()), do: GenServer.start(__MODULE__, {options, owner})
  def subscribe(pid), do: GenServer.call(pid, :subscribe)
  def act(pid, action, input \\ nil), do: GenServer.call(pid, {:act, action, input})

  def close(pid) do
    ref = Process.monitor(pid)

    try do
      result = GenServer.call(pid, :close, @close_timeout_ms)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} ->
          # The private owner also receives a termination receipt so a native
          # surface that exits first cannot hide failed cleanup from the CLI.
          take_closed_receipt(pid, result)
      after
        1_000 -> {:error, :cleanup_unconfirmed}
      end
    after
      Process.demonitor(ref, [:flush])
    end
  catch
    :exit, _ -> take_closed_receipt(pid, {:error, :cleanup_unconfirmed})
  end

  defp take_closed_receipt(pid, fallback) do
    receive do
      {:controller_closed, ^pid, :ok} -> :ok
      {:controller_closed, ^pid, {:error, :cleanup_unconfirmed} = result} -> result
    after
      0 -> fallback
    end
  end

  @impl true
  def init({options, owner}) do
    Process.flag(:sensitive, true)
    Process.flag(:trap_exit, true)

    if is_pid(owner) and Process.alive?(owner) do
      workspace =
        Keyword.get(
          options,
          :workspace_options,
          Keyword.get(options, :gateway_options, Keyword.get(options, :connection_options, []))
        )

      mode =
        cond do
          Keyword.has_key?(workspace, :identity) ->
            :signed

          Keyword.has_key?(options, :workspace_options) or Keyword.has_key?(workspace, :session) ->
            :human

          true ->
            :fixed
        end

      with {:ok, workspace} <- normalize_workspace(workspace, mode) do
        target = Keyword.get(workspace, :target)

        options =
          if mode == :fixed,
            do: options,
            else:
              Keyword.update(
                options,
                :gateway_options,
                workspace,
                &Keyword.put(&1, :gateway_url, workspace[:gateway_url])
              )

        {_lease, lease_cleanup} =
          if workspace[:session],
            do:
              Lease.own(
                self(),
                client_options(workspace),
                workspace[:gateway_url],
                workspace[:session]
              ),
            else: {nil, Keyword.get(options, :on_close)}

        state = %{
          owner: owner,
          owner_ref: Process.monitor(owner),
          surface: nil,
          surface_ref: nil,
          remote: nil,
          remote_ref: nil,
          connection: nil,
          connection_ref: nil,
          cleanup: lease_cleanup,
          options: options,
          workspace: workspace,
          mode: mode,
          target: target,
          principal: principal(workspace),
          job: nil,
          generation: 0,
          rows: [],
          truncated: false,
          directory: is_nil(target),
          notice: nil,
          login: nil,
          login_deadline: nil,
          login_timer: nil,
          snapshot: empty_snapshot(),
          display: nil,
          retiring: nil,
          handoffs: %{},
          closed: false,
          close_result: nil,
          cleanup_wait_ms: cleanup_wait(options)
        }

        if Keyword.has_key?(options, :workspace_options) and is_nil(target) do
          {:ok, publish(state)}
        else
          case open_binding(options, self()) do
            {:ok, remote, connection} -> {:ok, adopt(state, remote, connection, target)}
            _ -> {:stop, :conversation_unavailable}
          end
        end
      else
        _ -> {:stop, :invalid_gateway}
      end
    else
      {:stop, :conversation_unavailable}
    end
  end

  @impl true
  def handle_call(:close, _from, state) do
    result = cleanup(state)
    {:stop, :normal, result, %{state | closed: true, close_result: result}}
  end

  def handle_call(:subscribe, {caller, _}, %{surface: nil} = state),
    do:
      {:reply, {:ok, state.display},
       %{state | surface: caller, surface_ref: Process.monitor(caller)}}

  def handle_call(:subscribe, {caller, _}, %{surface: caller} = state),
    do: {:reply, {:ok, state.display}, state}

  def handle_call({:act, :directory, nil}, {caller, _}, %{surface: caller} = state) do
    cond do
      state.mode == :fixed ->
        {:reply, {:error, :navigation_unavailable}, state}

      state.job || state.login ->
        {:reply, {:error, :navigation_busy}, state}

      state.mode == :human ->
        {:reply, :ok,
         publish(%{state | directory: true, generation: state.generation + 1, notice: nil})}

      true ->
        client = client(state)
        identity = state.workspace[:identity]
        url = state.workspace[:gateway_url]

        state = %{
          state
          | directory: true,
            generation: state.generation + 1,
            rows: [],
            notice: nil
        }

        {:reply, :ok, start_job(state, :directory, fn -> client.list_agents(identity, url) end)}
    end
  end

  def handle_call({:act, :back, nil}, {caller, _}, %{surface: caller} = state) do
    if is_nil(state.job) and is_nil(state.login) and state.connection,
      do: {:reply, :ok, publish(%{state | directory: false, notice: nil})},
      else: {:reply, {:error, :navigation_busy}, state}
  end

  def handle_call(
        {:act, :attach, %{target: token, generation: generation} = input},
        {caller, _},
        %{surface: caller} = state
      )
      when map_size(input) == 2 do
    cond do
      not token?(token) or generation != state.generation ->
        {:reply, {:error, :stale_selection}, state}

      state.mode == :fixed ->
        {:reply, {:error, :navigation_unavailable}, state}

      blocked?(state) ->
        {:reply, {:error, :delivery_pending}, state}

      state.mode == :human and not target?(token) ->
        {:reply, {:error, :exact_target_required}, state}

      state.mode == :signed ->
        client = client(state)
        identity = state.workspace[:identity]
        url = state.workspace[:gateway_url]

        {:reply, :ok,
         start_job(state, :resolve, fn -> client.resolve_agent(identity, url, token) end)}

      true ->
        {:reply, :ok, begin_target(state, token)}
    end
  end

  def handle_call({:act, action, input}, {caller, _}, %{surface: caller} = state)
      when action in @actions do
    if (state.connection && (is_nil(state.job) or state.job.kind == :directory)) and
         is_nil(state.login) do
      Connection.act(state.connection, action, input)
      {:reply, :ok, state}
    else
      {:reply, {:error, :navigation_busy}, state}
    end
  end

  def handle_call(_, _from, state), do: {:reply, {:error, :not_surface_owner}, state}

  @impl true
  def handle_info(
        {:conversation_updated, connection, snapshot},
        %{connection: connection} = state
      ) do
    state =
      if snapshot.private_cleared and not state.snapshot.private_cleared,
        do: %{state | rows: [], generation: state.generation + 1},
        else: state

    if snapshot.connected and state.mode != :fixed,
      do: Hints.save(hint_path(state), state.workspace[:gateway_url], state.target)

    {:noreply, publish(%{state | snapshot: snapshot})}
  end

  def handle_info(
        {:workspace_result, pid, generation, result},
        %{job: %{pid: pid, generation: generation} = job} = state
      ) do
    Process.demonitor(job.ref, [:flush])
    state = %{state | job: nil}
    state = finish_job(job.kind, result, state)
    state = %{state | handoffs: Map.put(state.handoffs, pid, generation)}
    send(self(), {:workspace_ack, pid, generation})
    {:noreply, state}
  end

  def handle_info({:workspace_ack, pid, generation}, state) do
    if Map.has_key?(state.handoffs, pid), do: send(pid, {:workspace_adopted, generation})
    {:noreply, %{state | handoffs: Map.delete(state.handoffs, pid)}}
  end

  def handle_info(
        {:login_poll, generation},
        %{generation: generation, login: login, job: nil} = state
      )
      when not is_nil(login) do
    if System.monotonic_time(:millisecond) < state.login_deadline do
      client = client(state)
      url = state.workspace[:gateway_url]

      {:noreply,
       start_job(%{state | login_timer: nil}, :poll_login, fn ->
         client.poll_login(url, login.handle)
       end)}
    else
      {:noreply, login_failed(state)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{surface_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{connection_ref: ref} = state),
    do: {:stop, :conversation_unavailable, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{remote_ref: ref} = state),
    do: {:stop, :conversation_unavailable, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{job: %{ref: ref}} = state),
    do: {:noreply, publish(%{state | job: nil, notice: :navigation_failed})}

  def handle_info({:EXIT, remote, _reason}, %{remote: remote} = state),
    do: {:stop, :conversation_unavailable, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{closed: true} = state), do: report_closed(state, state.close_result)

  def terminate(_reason, state) do
    report_closed(state, cleanup(state))
  end

  defp report_closed(state, result) do
    send(state.owner, {:controller_closed, self(), result})
    :ok
  end

  defp cleanup(state) do
    if state.login_timer, do: Process.cancel_timer(state.login_timer)

    jobs =
      Enum.map(state.handoffs, fn {pid, generation} ->
        %{kind: :handoff, pid: pid, generation: generation}
      end) ++ if(state.job, do: [state.job], else: [])

    jobs_result = cancel_jobs(jobs, state.cleanup_wait_ms)

    login_result =
      if state.login do
        run_cleanup(fn ->
          client(state).cancel_login(state.workspace[:gateway_url], state.login.handle)
        end)
      else
        :ok
      end

    retiring_result =
      if state.retiring,
        do: retire(state.retiring.connection, state.retiring.remote, state.retiring.cleanup),
        else: :ok

    current_result = retire(state.connection, state.remote, state.cleanup)

    if Enum.all?([jobs_result, login_result, retiring_result, current_result], &(&1 == :ok)),
      do: :ok,
      else: {:error, :cleanup_unconfirmed}
  end

  @impl true
  def format_status(status), do: Map.put(status, :state, %{connection: :private})

  defp start_job(state, kind, fun) do
    owner = self()
    generation = state.generation

    client = client(state)
    url = state.workspace[:gateway_url]

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:sensitive, true)
        owner_ref = Process.monitor(owner)

        result =
          try do
            fun.()
          rescue
            _ -> {:error, :navigation_failed}
          catch
            _, _ -> {:error, :navigation_failed}
          end

        send(owner, {:workspace_result, self(), generation, result})
        # The receiver acknowledges after its new state is committed. If the
        # owner exits with the result still queued, retire any acquired resource.
        receive do
          {:workspace_adopted, ^generation} ->
            Process.demonitor(owner_ref, [:flush])

          {:workspace_cancel, ^generation} ->
            discard_owned_result(owner, generation, kind, result, client, url)

          {:DOWN, ^owner_ref, :process, ^owner, _} ->
            discard_owned_result(owner, generation, kind, result, client, url)
        after
          30_000 -> discard_owned_result(owner, generation, kind, result, client, url)
        end
      end)

    publish(%{state | job: %{pid: pid, ref: ref, kind: kind, generation: generation}})
  end

  defp cleanup_wait(options) do
    case Keyword.get(options, :cleanup_wait_ms, @acquisition_cleanup_ms) do
      wait when is_integer(wait) and wait in 10..@acquisition_cleanup_ms -> wait
      _ -> @acquisition_cleanup_ms
    end
  end

  defp cancel_jobs(jobs, wait) do
    deadline = System.monotonic_time(:millisecond) + wait

    pending =
      Map.new(jobs, fn job ->
        ref = Process.monitor(job.pid)
        receipt = job.kind in [:start_login, :poll_login, :open, :handoff]

        if receipt,
          do: send(job.pid, {:workspace_cancel, job.generation}),
          else: Process.exit(job.pid, :kill)

        {ref, %{pid: job.pid, generation: job.generation, receipt: receipt, result: nil}}
      end)

    await_cleanup(pending, deadline, :ok)
  end

  defp await_cleanup(pending, _deadline, result) when map_size(pending) == 0, do: result

  defp await_cleanup(pending, deadline, result) do
    receive do
      {:workspace_discarded, pid, generation, receipt} ->
        pending =
          Map.new(pending, fn
            {ref, %{pid: ^pid, generation: ^generation} = job} ->
              {ref, %{job | result: receipt}}

            entry ->
              entry
          end)

        await_cleanup(pending, deadline, result)

      {:DOWN, ref, :process, pid, _} when is_map_key(pending, ref) ->
        {job, pending} = Map.pop(pending, ref)

        result =
          if job.pid == pid and (not job.receipt or job.result == :ok),
            do: result,
            else: {:error, :cleanup_unconfirmed}

        await_cleanup(pending, deadline, result)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        # Do not kill the only owner of an acquired receipt. Owner DOWN will
        # still trigger best-effort discard if a trusted client exceeds its bound.
        Enum.each(pending, fn {ref, _job} -> Process.demonitor(ref, [:flush]) end)
        {:error, :cleanup_unconfirmed}
    end
  end

  defp discard_owned_result(owner, generation, kind, result, client, url) do
    receipt = run_cleanup(fn -> discard_result(kind, result, client, url) end)
    send(owner, {:workspace_discarded, self(), generation, receipt})
  end

  defp discard_result(:start_login, {:ok, pending}, client, url),
    do: client.cancel_login(url, pending.handle)

  defp discard_result(:poll_login, {:ok, %Arbor.Client.Login.Session{} = session}, client, url),
    do: client.logout(url, session)

  defp discard_result(:open, {:ok, remote, connection}, _, _), do: retire(connection, remote, nil)
  defp discard_result(_, _, _, _), do: :ok

  defp finish_job(:directory, {:ok, %{agents: rows, truncated: truncated}}, state)
       when is_list(rows) and is_boolean(truncated),
       do: publish(%{state | rows: rows, truncated: truncated})

  defp finish_job(:resolve, {:ok, target}, state) do
    if target?(target) and not blocked?(state),
      do: begin_target(state, target),
      else: publish(%{state | notice: :delivery_pending})
  end

  defp finish_job({:retire, target}, :ok, state), do: acquire(%{state | retiring: nil}, target)
  defp finish_job({:retire, _}, _, state), do: publish(%{state | notice: :cleanup_unconfirmed})

  defp finish_job(:start_login, {:ok, login}, state) do
    state = %{
      state
      | login: login,
        login_deadline: System.monotonic_time(:millisecond) + login.expires_in * 1_000
    }

    schedule_login(state)
  end

  defp finish_job(:poll_login, {:ok, :pending}, state), do: schedule_login(state)

  defp finish_job(:poll_login, {:ok, session}, state) do
    if session.target == state.target and session.principal != nil do
      {_lease, cleanup} = Lease.own(self(), client(state), state.workspace[:gateway_url], session)

      state = %{
        state
        | workspace: Keyword.put(state.workspace, :session, session),
          principal: session.principal,
          login: nil,
          login_deadline: nil,
          cleanup: cleanup
      }

      open_target(state)
    else
      client(state).logout(state.workspace[:gateway_url], session)
      login_failed(state)
    end
  end

  defp finish_job(:open, {:ok, remote, connection}, state),
    do: adopt(state, remote, connection, state.target)

  defp finish_job(kind, _, state) when kind in [:start_login, :poll_login],
    do: login_failed(state)

  defp finish_job(_, _, state), do: publish(%{state | notice: :navigation_failed})

  defp begin_target(%{target: target, connection: connection} = state, target)
       when not is_nil(connection) do
    Connection.act(connection, :refresh)
    publish(%{state | directory: false, notice: nil})
  end

  defp begin_target(state, target) do
    # Deliver the latest owned acknowledgement before the detach frame, so an
    # unchanged admitted draft cannot be parked as a new unsubmitted draft.
    state =
      if state.connection,
        do: publish(%{state | snapshot: Connection.snapshot(state.connection)}),
        else: state

    old_connection = state.connection
    old_remote = state.remote
    cleanup = state.cleanup

    for ref <- [state.connection_ref, state.remote_ref],
        is_reference(ref),
        do: Process.demonitor(ref, [:flush])

    if old_remote, do: Process.unlink(old_remote)

    state = %{
      state
      | connection: nil,
        connection_ref: nil,
        remote: nil,
        remote_ref: nil,
        cleanup: nil,
        retiring: %{connection: old_connection, remote: old_remote, cleanup: cleanup},
        snapshot: empty_snapshot(),
        target: target,
        generation: state.generation + 1,
        directory: true,
        notice: nil
    }

    start_job(state, {:retire, target}, fn -> retire(old_connection, old_remote, cleanup) end)
  end

  defp acquire(%{mode: :signed} = state, _target), do: open_target(state)

  defp acquire(state, target) do
    client = client(state)
    url = state.workspace[:gateway_url]
    start_job(state, :start_login, fn -> client.start_login(url, target) end)
  end

  defp open_target(state) do
    owner = self()
    auth = Keyword.take(state.workspace, [:identity, :session, :gateway_url])

    options =
      Keyword.put(state.options, :gateway_options, Keyword.put(auth, :target, state.target))

    start_job(state, :open, fn -> open_binding(options, owner) end)
  end

  defp adopt(state, remote, connection, target) do
    if remote, do: Process.link(remote)

    state = %{
      state
      | remote: remote,
        remote_ref: if(remote, do: Process.monitor(remote)),
        connection: connection,
        connection_ref: Process.monitor(connection),
        target: target,
        snapshot: Connection.snapshot(connection),
        directory: false,
        notice: nil
    }

    publish(state)
  end

  defp schedule_login(state) do
    timer =
      Process.send_after(self(), {:login_poll, state.generation}, state.login.interval * 1_000)

    publish(%{state | login_timer: timer})
  end

  defp login_failed(state) do
    if state.login,
      do:
        run_cleanup(fn ->
          client(state).cancel_login(state.workspace[:gateway_url], state.login.handle)
        end)

    publish(%{state | login: nil, login_deadline: nil, login_timer: nil, notice: :login_failed})
  end

  defp blocked?(state) do
    snapshot =
      if state.connection, do: Connection.snapshot(state.connection), else: state.snapshot

    state.job != nil or state.login != nil or snapshot.busy or snapshot.pending_id != nil or
      state.notice == :cleanup_unconfirmed
  end

  defp publish(state) do
    navigation = %{
      mode: state.mode,
      target: state.target,
      principal: state.principal,
      gateway: state.workspace[:gateway_url],
      bound: not is_nil(state.connection),
      directory: state.directory,
      generation: state.generation,
      rows: state.rows,
      truncated: state.truncated,
      busy: state.job != nil or state.login != nil,
      notice: state.notice,
      hint:
        if(is_nil(state.target) and state.mode != :fixed,
          do: Hints.load(hint_path(state), state.workspace[:gateway_url])
        ),
      sign_in:
        if(state.login,
          do: Map.take(Map.from_struct(state.login), [:verification_uri, :user_code, :expires_in])
        )
    }

    snapshot =
      state.snapshot
      |> Map.put(:review_path, if(target?(state.target), do: "/conversation/" <> state.target))
      |> Map.put(:navigation, navigation)

    snapshot =
      if (state.job != nil and state.job.kind != :directory) or not is_nil(state.login),
        do: Map.put(snapshot, :send_allowed, false),
        else: snapshot

    if state.surface, do: send(state.surface, {:arbor_breeze_updated, self(), snapshot})
    %{state | display: snapshot}
  end

  defp principal(workspace) do
    cond do
      workspace[:identity] -> workspace[:identity].agent_id
      workspace[:session] -> workspace[:session].principal
      true -> nil
    end
  end

  defp normalize_workspace(workspace, :fixed), do: {:ok, workspace}

  defp normalize_workspace(workspace, mode) do
    policy = if mode == :signed, do: :signed, else: :session

    with {:ok, origin} <- Client.gateway_origin(workspace[:gateway_url], policy),
         do: {:ok, Keyword.put(workspace, :gateway_url, origin)}
  end

  defp client_options(workspace), do: Keyword.get(workspace, :client, Client)
  defp client(state), do: Keyword.get(state.workspace, :client, Client)
  defp hint_path(state), do: Keyword.get(state.workspace, :hint_path, Hints.default_path())

  defp token?(text) when is_binary(text) and byte_size(text) in 1..256,
    do:
      String.valid?(text) and String.trim(text) != "" and
        not Regex.match?(~r/[\x00-\x1f\x7f-\x9f]/u, text)

  defp token?(_), do: false
  defp target?(text), do: token?(text) and Regex.match?(~r/\Aagent_[A-Za-z0-9_-]+\z/, text)

  defp empty_snapshot do
    %{
      projection: %{
        "messages" => [],
        "deliveries" => [],
        "notices" => [],
        "blocks" => [],
        "speech" => []
      },
      notices_status: :unavailable,
      notice_window: %{head: 0, through: 0, has_older: false, next_before: nil, complete: false},
      window: %{head: 0, first: 0, last: 0, has_older: false, has_newer: false},
      controls: %{"activities" => [], "interactions" => [], "blocks" => [], "speech" => []},
      controls_available: false,
      controls_discovery: %{has_more: false, incomplete: false, truncated: false},
      connected: false,
      busy: false,
      error: nil,
      private_cleared: false,
      pending_id: nil,
      receipt: nil,
      ack: nil,
      send_allowed: false,
      retry_allowed: false
    }
  end

  defp open_binding(options, owner) do
    result =
      case Keyword.get(options, :binding_factory) do
        factory when is_function(factory, 2) ->
          factory.(Keyword.get(options, :gateway_options, []), owner)

        _ ->
          case Keyword.fetch(options, :connection_options) do
            {:ok, opts} when is_list(opts) ->
              {:ok, nil, opts}

            :error ->
              with {:ok, remote} <-
                     Gateway.start_link(
                       Keyword.put(Keyword.fetch!(options, :gateway_options), :owner, owner)
                     ) do
                Process.unlink(remote)

                case Gateway.client_options(remote) do
                  {:ok, opts} ->
                    {:ok, remote, opts}

                  _ ->
                    Gateway.close(remote)
                    {:error, :conversation_unavailable}
                end
              end

            _ ->
              {:error, :invalid_options}
          end
      end

    with {:ok, remote, opts} <- result do
      limit = Keyword.get(options, :page_limit, 20)

      opts =
        Keyword.update(
          opts,
          :adapter_options,
          [page_limit: limit],
          &Keyword.put_new(&1, :page_limit, limit)
        )

      case Connection.start(opts, owner) do
        {:ok, connection} ->
          {:ok, remote, connection}

        error ->
          if(remote, do: Gateway.close(remote))
          error
      end
    end
  end

  defp retire(connection, remote, cleanup) do
    with :ok <- close_verified(connection, &Connection.close/1),
         :ok <- close_verified(remote, &Gateway.close/1),
         :ok <- run_cleanup(cleanup),
         do: :ok
  end

  defp close_verified(nil, _), do: :ok

  defp close_verified(pid, fun) do
    ref = Process.monitor(pid)

    result =
      try do
        fun.(pid)
      catch
        :exit, {:noproc, _} -> :ok
        :exit, {:normal, _} -> :ok
        _, _ -> {:error, :close_failed}
      end

    receive do
      {:DOWN, ^ref, :process, ^pid, _} ->
        if(result == :ok, do: :ok, else: {:error, :close_failed})
    after
      1_000 ->
        Process.demonitor(ref, [:flush])
        {:error, :close_failed}
    end
  end

  defp run_cleanup(nil), do: :ok

  defp run_cleanup(fun) do
    case fun.() do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, :unauthorized} -> :ok
      _ -> {:error, :cleanup_unconfirmed}
    end
  rescue
    _ -> {:error, :cleanup_unconfirmed}
  catch
    _, _ -> {:error, :cleanup_unconfirmed}
  end
end
