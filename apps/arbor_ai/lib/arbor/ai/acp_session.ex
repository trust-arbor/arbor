defmodule Arbor.AI.AcpSession do
  @moduledoc """
  Arbor-specific wrapper around `ExMCP.ACP.Client` for coding agent sessions.

  Provides a uniform interface for communicating with any ACP-compatible coding
  agent (Gemini, OpenCode, Goose, etc.) or adapted agents (Claude, Codex) that
  speak ACP through an adapter shim.

  ## Usage

      # Start a session with a native ACP agent
      {:ok, session} = AcpSession.start_link(provider: :gemini)
      {:ok, _info} = AcpSession.create_session(session)
      {:ok, result} = AcpSession.send_message(session, "Implement auth module")
      :ok = AcpSession.close(session)

      # Start a session with an adapted agent
      {:ok, session} = AcpSession.start_link(provider: :claude, model: "opus")
      {:ok, _info} = AcpSession.create_session(session, cwd: "/path/to/project")
      {:ok, result} = AcpSession.send_message(session, "Fix the auth bug")

  ## Streaming

  Pass `:stream_callback` to receive streaming updates:

      {:ok, session} = AcpSession.start_link(
        provider: :claude,
        stream_callback: fn update -> IO.inspect(update) end
      )

  ## Signals

  When `arbor_signals` is available, emits lifecycle signals:
  - `{:agent, :acp_session_started}` — session created
  - `{:agent, :acp_session_completed}` — prompt response received
  - `{:agent, :acp_session_error}` — error during session
  - `{:agent, :acp_session_closed}` — session terminated
  """

  use GenServer

  require Logger

  alias Arbor.AI.AcpSession.Config
  alias Arbor.AI.AcpSession.GrokSandbox
  alias Arbor.AI.AcpSession.RuntimeHome
  alias Arbor.AI.AcpTranscript
  alias Arbor.AI.OwnedOperation

  @default_acp_client ExMCP.ACP.Client
  @default_inactivity_timeout_ms 300_000
  @default_operation_timeout_ms 120_000
  @default_close_timeout_ms 5_000
  @stream_callback_timeout_ms 5_000
  @default_transcript_sink_timeout_ms 5_000
  @max_transcript_sink_timeout_ms 30_000
  @task_control_timeout_ms 5_000
  @max_task_control_message_bytes 16_384
  @max_task_control_id_bytes 256
  @max_task_id_bytes 512
  @max_task_control_reason_bytes 200
  @max_task_control_history 256
  @max_queued_task_controls 64
  @callback_cleanup_timeout_ms 250
  @task_control_stream_id "agent:task_steering"
  @terminal_task_control_statuses [
    :delivered,
    :not_delivered,
    :delivery_unknown,
    :cancelled
  ]

  defstruct [
    :client,
    :client_monitor,
    :session_id,
    :last_session_id,
    :provider,
    :model,
    :owner,
    :owner_monitor,
    :stream_callback,
    :opts,
    :workspace,
    :runtime_home_cleanup,
    :mcp_servers,
    :startup_error,
    status: :starting,
    accumulated_text: "",
    stream_tail: nil,
    context_tokens: 0,
    reconnect_attempted: false,
    usage: %{input_tokens: 0, output_tokens: 0},
    task_controls: %{},
    task_control_sequence: [],
    task_control_history_order: [],
    pending_settlements: %{},
    pending_settlement_order: []
  ]

  # -- Public API --

  @doc """
  Start a new AcpSession GenServer.

  ## Options

  - `:provider` — provider atom (required): `:claude`, `:codex`, `:gemini`, etc.
  - `:model` — model string override (optional)
  - `:system_prompt` — system prompt for the agent (optional)
  - `:cwd` — working directory for the session (optional)
  - `:workspace` — workspace plan; a directory workspace supplies the session
    cwd when no explicit `:cwd` is provided
  - `:stream_callback` — `fn(update) -> any()` for streaming events (optional)
  - `:timeout` — timeout for ACP operations in ms (default: 120_000)
  - `:name` — GenServer name registration (optional)
  - `:agent_id` — Arbor agent ID for security integration (optional)
  - `:adapter_opts` — additional adapter-specific options (optional)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    with {:ok, opts, _timeout} <-
           Arbor.AI.Timeout.start_deadline(opts, @default_operation_timeout_ms) do
      {gen_opts, init_opts} = Keyword.split(opts, [:name])
      # Capture the starter as the session owner so we can monitor it even when
      # the session is start_link'd (linked) and later :kill'd — trap_exit +
      # monitor lets us abort prompts and disconnect the ACP client orderly.
      init_opts = Keyword.put_new(init_opts, :owner, self())
      GenServer.start_link(__MODULE__, init_opts, gen_opts)
    end
  end

  @doc """
  Create a new ACP session with the connected agent.

  Must be called after `start_link/1` before sending messages.
  Returns session metadata from the agent.

  ## Options

  - `:cwd` — working directory for the session (overrides init cwd and the
    initialized directory workspace)
  - `:workspace` — directory workspace used when no explicit `:cwd` is
    provided
  """
  @spec create_session(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_session(session, opts \\ []) do
    with {:ok, opts, _timeout} <-
           Arbor.AI.Timeout.start_deadline(opts, @default_operation_timeout_ms),
         {:ok, opts, remaining} <- Arbor.AI.Timeout.remaining(opts) do
      safe_lifecycle_call(session, {:create_session, opts}, remaining)
    end
  end

  @doc false
  @spec await_ready(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def await_ready(session, opts \\ []) do
    with {:ok, opts, _timeout} <-
           Arbor.AI.Timeout.start_deadline(opts, @default_operation_timeout_ms),
         {:ok, opts, remaining} <- Arbor.AI.Timeout.remaining(opts) do
      safe_lifecycle_call(session, {:await_ready, opts}, remaining)
    end
  end

  @doc """
  Send a message/prompt to the ACP session.

  Blocks until the agent returns a response. Streaming updates are
  delivered to the `:stream_callback` if configured.

  ## Options

  - `:timeout` — optional hard wall-clock timeout for this request
  - `:inactivity_timeout_ms` — silence window before aborting an in-flight request
  """
  @spec send_message(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_message(session, content, opts \\ []) do
    with {:ok, opts} <- normalize_prompt_timeouts(opts),
         {:ok, opts, remaining} <- Arbor.AI.Timeout.remaining(opts) do
      safe_prompt_call(session, content, opts, remaining)
    end
  end

  @doc """
  Deliver an opaque task control without exposing session internals.

  This intentionally uses the session mailbox instead of `GenServer.call/3`:
  an active prompt owns the GenServer process in `await_prompt_result/3` and
  can acknowledge a queued control immediately.

  Control state is session-local and is not restored after a restart. If a
  follow-up has started when the provider fails or cancellation begins, its
  terminal state is `:delivery_unknown`; replaying it could duplicate an
  instruction the provider already applied. Controls that have not started are
  terminally cancelled or marked not delivered.
  """
  @spec deliver_task_control(GenServer.server(), map(), keyword()) ::
          {:ok, :queued | :delivered | :deferred, :same_session_follow_up} | {:error, term()}
  def deliver_task_control(session, control, opts \\ []) when is_map(control) and is_list(opts) do
    with {:ok, opts, _timeout} <-
           Arbor.AI.Timeout.start_deadline(opts, @task_control_timeout_ms),
         {:ok, _opts, timeout} <- Arbor.AI.Timeout.remaining(opts) do
      ref = make_ref()
      send(session, {:acp_task_control, ref, self(), control})

      receive do
        {:acp_task_control_result, ^ref, result} -> result
      after
        timeout -> {:error, :control_delivery_timeout}
      end
    end
  end

  @doc "Provider-declared task-control capabilities."
  @spec task_control_capabilities(GenServer.server()) :: map()
  def task_control_capabilities(session), do: GenServer.call(session, :task_control_capabilities)

  @doc """
  Get the current status of this session.
  """
  @spec status(GenServer.server()) :: map()
  def status(session) do
    GenServer.call(session, :status)
  end

  @doc """
  Resume an existing ACP session by ID.

  Reconnects to the agent and loads the previous session state.
  Useful for crash recovery or session migration.
  """
  @spec resume_session(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resume_session(session, session_id, opts \\ []) do
    with {:ok, opts, _timeout} <-
           Arbor.AI.Timeout.start_deadline(opts, @default_operation_timeout_ms),
         {:ok, opts, remaining} <- Arbor.AI.Timeout.remaining(opts) do
      safe_lifecycle_call(session, {:resume_session, session_id, opts}, remaining)
    end
  end

  @doc """
  Check if the session's context window is under pressure.

  Returns true when the latest input token count exceeds 75% of a
  typical 200K context window. The pool can use this to prefer fresh
  sessions over context-heavy ones.
  """
  @spec context_pressure?(GenServer.server()) :: boolean()
  def context_pressure?(session) do
    info = status(session)
    info.context_tokens > 150_000
  end

  @doc """
  Close the ACP session and disconnect from the agent.
  """
  @spec close(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def close(session, opts \\ []) do
    with {:ok, opts, _timeout} <-
           Arbor.AI.Timeout.start_deadline(opts, @default_close_timeout_ms),
         {:ok, opts, remaining} <- Arbor.AI.Timeout.remaining(opts) do
      case safe_lifecycle_call(session, {:close, opts}, remaining) do
        {:error, :timeout} = error ->
          terminate_server(session)
          error

        result ->
          result
      end
    end
  end

  # -- GenServer Callbacks --

  @impl true
  def init(opts) do
    # Survive linked owner :kill so we can cancel the ACP prompt and disconnect
    # the client instead of vanishing without terminate/2.
    Process.flag(:trap_exit, true)

    with {:ok, mcp_servers} <- normalize_bound_mcp_servers(Keyword.get(opts, :mcp_servers)) do
      provider = Keyword.fetch!(opts, :provider)
      {owner, owner_monitor} = monitor_owner(Keyword.get(opts, :owner))

      state = %__MODULE__{
        provider: provider,
        model: Keyword.get(opts, :model),
        owner: owner,
        owner_monitor: owner_monitor,
        stream_callback: Keyword.get(opts, :stream_callback),
        mcp_servers: mcp_servers,
        workspace: workspace_plan(opts),
        status: :starting,
        opts: opts
      }

      {:ok, state, {:continue, :start_client}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:start_client, state) do
    result = start_client_owned(state)

    case result do
      {:ok, client, client_monitor, workspace, runtime_home_cleanup} ->
        with :ok <- Arbor.AI.Timeout.ensure_active(state.opts),
             true <- owner_alive?(state.owner) or {:error, :owner_dead} do
          new_state = %{
            state
            | client: client,
              client_monitor: client_monitor,
              workspace: workspace,
              runtime_home_cleanup: runtime_home_cleanup,
              status: :ready,
              startup_error: nil
          }

          emit_signal(:acp_session_started, new_state)
          {:noreply, new_state}
        else
          {:error, reason} ->
            startup_failed(
              %{state | runtime_home_cleanup: runtime_home_cleanup},
              client,
              workspace,
              reason
            )

          false ->
            startup_failed(
              %{state | runtime_home_cleanup: runtime_home_cleanup},
              client,
              workspace,
              :owner_dead
            )
        end

      {:error, reason} ->
        startup_failed(state, nil, state.workspace, reason)

      other ->
        startup_failed(
          state,
          nil,
          state.workspace,
          {:invalid_startup_result, Arbor.LLM.sanitize_external_reason(other)}
        )
    end
  end

  def handle_continue({:emit_timeout_settlement, settlement}, state) do
    emit_pending_timeout_settlement(state, settlement)
    {:noreply, state}
  end

  @impl true
  def handle_call({:await_ready, opts}, _from, state) do
    case {Arbor.AI.Timeout.ensure_active(opts), state.status} do
      {:ok, :ready} -> {:reply, :ok, state}
      {{:error, reason}, _status} -> {:reply, {:error, reason}, state}
      {:ok, :error} -> {:reply, {:error, state.startup_error || :startup_failed}, state}
      {:ok, status} -> {:reply, {:error, {:not_ready, status}}, state}
    end
  end

  def handle_call({:create_session, _opts}, _from, %{status: :error} = state) do
    reason = state.startup_error || {:not_available, "ACP client not initialized"}
    {:reply, {:error, reason}, state}
  end

  def handle_call({:create_session, _opts}, _from, %{status: :recovery_required} = state) do
    {:reply, {:error, {:not_ready, :recovery_required}}, state}
  end

  def handle_call({:create_session, opts}, _from, state) do
    with :ok <- Arbor.AI.Timeout.ensure_active(opts) do
      do_create_session(opts, state)
    else
      {:error, :timeout} -> {:reply, {:error, :timeout}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resume_session, _session_id, _opts}, _from, %{status: :error} = state) do
    reason = state.startup_error || {:not_available, "ACP client not initialized"}
    {:reply, {:error, reason}, state}
  end

  def handle_call(
        {:resume_session, _session_id, _opts},
        _from,
        %{status: :recovery_required} = state
      ) do
    {:reply, {:error, {:not_ready, :recovery_required}}, state}
  end

  def handle_call({:resume_session, session_id, opts}, _from, state) do
    with :ok <- Arbor.AI.Timeout.ensure_active(opts) do
      do_resume_session(session_id, opts, state)
    else
      {:error, :timeout} -> {:reply, {:error, :timeout}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_message, _content, _opts}, _from, %{status: status} = state)
      when status not in [:ready] do
    {:reply, {:error, {:not_ready, status}}, state}
  end

  def handle_call({:send_message, content, opts}, from, state) do
    with true <- prompt_caller_alive?(from),
         :ok <- Arbor.AI.Timeout.ensure_active(opts),
         {:ok, state} <- ensure_session(state, opts),
         :ok <- Arbor.AI.Timeout.ensure_active(opts),
         true <- prompt_caller_alive?(from) do
      acknowledge_prompt_call(from)
      do_send_message(content, opts, from, state)
    else
      {:error, :timeout} ->
        operation_timed_out(:create, state)

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | status: :error}}

      false ->
        {:reply, {:error, :caller_unavailable}, state}
    end
  end

  def handle_call(:status, _from, state) do
    info = %{
      provider: state.provider,
      model: state.model,
      session_id: state.session_id,
      status: state.status,
      usage: state.usage,
      context_tokens: state.context_tokens
    }

    {:reply, info, state}
  end

  def handle_call(:task_control_capabilities, _from, state) do
    {:reply, task_control_capabilities_for(state), state}
  end

  def handle_call({:close, opts}, _from, state) do
    state =
      state
      |> flush_pending_settlements()
      |> settle_pending_task_controls(:cancelled, :session_closed)

    result = disconnect_client_owned(state, opts)
    emit_signal(:acp_session_closed, state)
    {:stop, :normal, result, %{state | status: :closed, client: nil, client_monitor: nil}}
  end

  defp do_create_session(opts, state) do
    cwd = resolve_cwd(opts, state.opts, state.workspace)
    opts = bind_mcp_servers(opts, state.mcp_servers)

    result =
      OwnedOperation.run(
        fn -> new_acp_session(state.client, cwd, opts) end,
        opts,
        :timeout
      )

    case result do
      {:ok, session_info} ->
        case Arbor.AI.Timeout.ensure_active(opts) do
          :ok ->
            session_id = Map.get(session_info, "sessionId") || Map.get(session_info, :session_id)

            new_state = %{
              state
              | session_id: session_id,
                last_session_id: session_id,
                status: :ready
            }

            {:reply, {:ok, session_info}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, :timeout} ->
        operation_timed_out(:create, state)

      {:error, reason} = error ->
        Logger.warning(
          "AcpSession create_session failed: " <> Arbor.LLM.inspect_external_reason(reason)
        )

        new_state = %{state | status: :error}
        emit_signal(:acp_session_error, new_state, %{error: reason, phase: :create})
        {:reply, error, new_state}
    end
  end

  defp do_resume_session(session_id, opts, state) do
    cwd = resolve_cwd(opts, state.opts, state.workspace)
    opts = bind_mcp_servers(opts, state.mcp_servers)

    result =
      OwnedOperation.run(
        fn ->
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          apply(acp_client_module(), :load_session, [state.client, session_id, cwd, opts])
        end,
        opts,
        :timeout
      )

    case result do
      {:ok, session_info} ->
        case {validate_acp_result(session_info, :session), Arbor.AI.Timeout.ensure_active(opts)} do
          {:ok, :ok} ->
            new_state = %{
              state
              | session_id: session_id,
                last_session_id: session_id,
                status: :ready
            }

            emit_signal(:acp_session_started, new_state, %{resumed: true})
            {:reply, {:ok, session_info}, new_state}

          {_validation, {:error, reason}} ->
            {:reply, {:error, reason}, state}

          {{:error, reason}, _deadline} ->
            {:reply, {:error, reason}, state}
        end

      {:error, :timeout} ->
        operation_timed_out(:resume, state)

      {:error, reason} ->
        reason = Arbor.LLM.sanitize_external_reason(reason)

        Logger.warning(
          "AcpSession resume_session failed: " <> Arbor.LLM.inspect_external_reason(reason)
        )

        emit_signal(:acp_session_error, state, %{error: reason, phase: :resume})
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(
        {:acp_session_update, _session_id, _update},
        %{status: :recovery_required} = state
      ) do
    # The provider session ID remains queryable for operator recovery, so it
    # cannot distinguish late updates from the cancelled request. Drop every
    # update until this local session is explicitly closed and reopened.
    {:noreply, state}
  end

  def handle_info({:acp_session_update, session_id, update}, state) do
    with {:ok, opts, _timeout} <-
           Arbor.AI.Timeout.start_deadline([], @stream_callback_timeout_ms) do
      case process_session_update(state, session_id, update, opts) do
        {:ok, new_state} ->
          {:noreply, new_state}

        {:error, :stream_callback_timeout, new_state} ->
          emit_signal(:acp_session_error, new_state, %{
            error: :stream_callback_timeout,
            phase: :stream_callback
          })

          {:stop, :normal, %{new_state | status: :error}}
      end
    else
      {:error, _reason} -> {:stop, :normal, %{state | status: :error}}
    end
  end

  # No prompt is active. The control is retained for idempotency but there is
  # no in-flight ACP request to steer, so never claim it was delivered.
  def handle_info(
        {:acp_task_control, ref, reply_to, _control},
        %{status: :recovery_required} = state
      )
      when is_reference(ref) and is_pid(reply_to) do
    send(reply_to, {
      :acp_task_control_result,
      ref,
      {:error, {:not_ready, :recovery_required}}
    })

    {:noreply, state}
  end

  def handle_info({:acp_task_control, ref, reply_to, control}, state)
      when is_reference(ref) and is_pid(reply_to) do
    {result, state} = accept_deferred_task_control(control, state)
    send(reply_to, {:acp_task_control_result, ref, result})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{owner_monitor: ref} = state) do
    Logger.info(
      "AcpSession owner gone (#{Arbor.LLM.inspect_external_reason(reason)}); aborting session #{Arbor.LLM.inspect_external_reason(state.session_id)}"
    )

    state =
      state
      |> flush_pending_settlements()
      |> settle_pending_task_controls(:cancelled, :owner_cancelled)

    _ = disconnect_client_owned(state, internal_cleanup_opts())
    emit_signal(:acp_session_closed, state, %{reason: :owner_cancelled})

    {:stop, :normal,
     %{state | status: :closed, owner_monitor: nil, client: nil, client_monitor: nil}}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{client: pid} = state)
      when ref == state.client_monitor and state.status == :recovery_required do
    state = flush_pending_settlements(state)
    bounded_reason = Arbor.LLM.sanitize_external_reason(reason)

    Logger.warning(
      "ACP client process died while recovery was required: #{Arbor.LLM.inspect_external_reason(bounded_reason)}"
    )

    new_state = %{state | client: nil, client_monitor: nil}
    emit_signal(:acp_session_error, new_state, %{error: :client_down, reason: bounded_reason})
    {:noreply, new_state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{client: pid} = state)
      when ref == state.client_monitor do
    state = flush_pending_settlements(state)
    bounded_reason = Arbor.LLM.sanitize_external_reason(reason)

    Logger.warning(
      "ACP client process died: #{Arbor.LLM.inspect_external_reason(bounded_reason)}"
    )

    emit_signal(:acp_session_error, state, %{error: :client_down, reason: bounded_reason})

    # Attempt auto-reconnect if we have a session to resume (max 1 try)
    case maybe_reconnect(state) do
      {:ok, new_state} ->
        Logger.info("ACP client reconnected for session #{state.last_session_id}")
        {:noreply, new_state}

      :error ->
        new_state =
          state
          |> settle_pending_task_controls(:not_delivered, :provider_client_lost)
          |> Map.merge(%{status: :error, client: nil, client_monitor: nil})

        {:noreply, new_state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    # trap_exit keeps us alive when a linked owner/client dies with :kill so the
    # matching Process.monitor DOWN path can cancel/disconnect orderly. Do not
    # handle owner/client cleanup here — that would race/double-run with DOWN.
    {:noreply, state}
  end

  def handle_info({:acp_timeout_settlement, ref}, state) when is_reference(ref) do
    case take_pending_settlement(state, ref) do
      {:ok, settlement, new_state} ->
        {:noreply, new_state, {:continue, {:emit_timeout_settlement, settlement}}}

      :not_found ->
        {:noreply, state}
    end
  end

  def handle_info(message, state)
      when is_tuple(message) and tuple_size(message) > 0 and
             elem(message, 0) == :acp_timeout_settlement do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("AcpSession unexpected message: #{Arbor.LLM.inspect_external_reason(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    _state =
      state
      |> flush_pending_settlements()
      |> settle_pending_task_controls(:not_delivered, :session_terminated)

    demonitor_owner(state.owner_monitor)
    demonitor_owner(state.client_monitor)
    terminate_client(state.client)
    cleanup_workspace_owned(state.workspace)
    cleanup_runtime_home(state.runtime_home_cleanup)
    :ok
  end

  # -- Private --

  defp acp_client_module do
    Application.get_env(:arbor_ai, :acp_client_module, @default_acp_client)
  end

  defp acp_available? do
    Code.ensure_loaded?(acp_client_module())
  end

  defp normalize_bound_mcp_servers(nil), do: {:ok, []}

  defp normalize_bound_mcp_servers(servers) when is_list(servers) do
    if Enum.all?(servers, &is_map/1),
      do: {:ok, servers},
      else: {:error, :invalid_acp_mcp_servers}
  end

  defp normalize_bound_mcp_servers(_servers), do: {:error, :invalid_acp_mcp_servers}

  defp bind_mcp_servers(opts, servers) do
    opts
    |> Keyword.delete(:mcp_servers)
    |> Keyword.put(:mcp_servers, servers)
  end

  defp resolve_client_opts(provider, opts) do
    case Keyword.get(opts, :client_opts) do
      nil -> Config.resolve(provider, opts)
      raw when is_list(raw) -> {:ok, raw}
      _other -> {:error, :invalid_acp_client_options}
    end
  end

  defp configure_client_opts(client_opts, session_pid, opts, cwd) do
    handler_opts =
      client_opts
      |> Keyword.get(:handler_opts, [])
      |> normalize_handler_opts()
      |> Keyword.put(:session_pid, session_pid)
      |> Keyword.put(:agent_id, Keyword.get(opts, :agent_id))
      |> Keyword.put(:cwd, cwd)

    client_opts
    |> Keyword.put(:event_listener, session_pid)
    |> Keyword.put_new(:handler, Arbor.AI.AcpSession.Handler)
    |> Keyword.put(:handler_opts, handler_opts)
    |> maybe_put_kw(:capabilities, Keyword.get(opts, :capabilities))
    |> inject_os_cwd(cwd)
  end

  defp normalize_handler_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: opts, else: []
  end

  defp normalize_handler_opts(_opts), do: []

  defp unwrap_grok_launch({:ok, result}), do: result

  defp unwrap_grok_launch(
         {:error, {:grok_sandbox_cleanup_failed, reason},
          {:ok, client, client_monitor, workspace}}
       ) do
    demonitor_owner(client_monitor)
    terminate_client(client)
    cleanup_workspace(workspace)
    {:error, {:grok_sandbox_cleanup_failed, reason}}
  end

  defp unwrap_grok_launch(
         {:error, {:grok_sandbox_cleanup_failed, reason}, {:ok, client, workspace}}
       ) do
    terminate_client(client)
    cleanup_workspace(workspace)
    {:error, {:grok_sandbox_cleanup_failed, reason}}
  end

  defp unwrap_grok_launch({:error, {:grok_sandbox_cleanup_failed, reason}, {:ok, client}}) do
    terminate_client(client)
    {:error, {:grok_sandbox_cleanup_failed, reason}}
  end

  defp unwrap_grok_launch({:error, {:grok_sandbox_cleanup_failed, reason}, _result}),
    do: {:error, {:grok_sandbox_cleanup_failed, reason}}

  defp unwrap_grok_launch({:error, _reason} = error), do: error

  defp initialize_client(session_pid, _provider, opts, workspace_plan, client_opts) do
    if acp_available?() do
      workspace = materialize_workspace(workspace_plan)
      cwd = workspace_cwd(workspace, opts)

      with {:ok, client} <-
             client_opts
             |> configure_client_opts(session_pid, opts, cwd)
             |> start_acp_client() do
        {:ok, client, workspace}
      else
        {:error, reason} ->
          cleanup_workspace(workspace)
          {:error, reason}
      end
    else
      {:error, :acp_client_not_available}
    end
  end

  defp start_client_owned(state) do
    with {:ok, runtime_home_cleanup} <- RuntimeHome.create() do
      result =
        with {:ok, client_opts} <- resolve_client_opts(state.provider, state.opts),
             {:ok, client_opts} <-
               RuntimeHome.inject(client_opts, runtime_home_cleanup, state.provider) do
          GrokSandbox.with_launch(
            state.provider,
            client_opts,
            workspace_cwd(state.workspace, state.opts),
            Keyword.get(state.opts, :grok_sandbox_authority),
            state.owner,
            state.mcp_servers,
            fn prepared_opts -> do_start_client_owned(state, prepared_opts) end
          )
          |> unwrap_grok_launch()
        end

      case result do
        {:ok, client, client_monitor, workspace} ->
          {:ok, client, client_monitor, workspace, runtime_home_cleanup}

        error ->
          cleanup_runtime_home(runtime_home_cleanup)
          error
      end
    end
  end

  defp do_start_client_owned(state, client_opts) do
    with {:ok, _opts, requested_remaining} <- Arbor.AI.Timeout.remaining(state.opts),
         {:ok, requested_deadline} <- Arbor.AI.Timeout.deadline(state.opts) do
      {remaining, deadline} = finite_start_deadline(requested_remaining, requested_deadline)
      caller = self()
      reply_alias = :erlang.alias()
      operation_ref = make_ref()

      {worker, monitor} =
        :erlang.spawn_opt(
          fn ->
            result =
              initialize_client(
                caller,
                state.provider,
                state.opts,
                state.workspace,
                client_opts
              )

            completed_at = System.monotonic_time(:millisecond)
            send(reply_alias, {operation_ref, result, completed_at, self()})

            case result do
              {:ok, client, _workspace} ->
                receive do
                  {^operation_ref, :adopted, ^caller} -> Process.unlink(client)
                  {^operation_ref, :cancel, ^caller} -> terminate_client(client)
                after
                  max(deadline - System.monotonic_time(:millisecond), 0) ->
                    terminate_client(client)
                end

              _error ->
                :ok
            end
          end,
          [:link, :monitor]
        )

      await_client_start(
        worker,
        monitor,
        reply_alias,
        operation_ref,
        deadline,
        remaining
      )
    end
  end

  defp finite_start_deadline(:infinity, :infinity) do
    now = System.monotonic_time(:millisecond)
    {@default_operation_timeout_ms, now + @default_operation_timeout_ms}
  end

  defp finite_start_deadline(remaining, deadline), do: {remaining, deadline}

  defp await_client_start(worker, monitor, reply_alias, operation_ref, deadline, remaining) do
    receive do
      {^operation_ref, {:ok, client, workspace}, completed_at, ^worker}
      when completed_at <= deadline ->
        case attach_client(client) do
          {:ok, client_monitor} ->
            send(worker, {operation_ref, :adopted, self()})
            await_start_worker_down(worker, monitor)
            :erlang.unalias(reply_alias)
            {:ok, client, client_monitor, workspace}

          {:error, reason} ->
            send(worker, {operation_ref, :cancel, self()})
            await_start_worker_down(worker, monitor)
            :erlang.unalias(reply_alias)
            {:error, reason}
        end

      {^operation_ref, {:ok, _client, _workspace}, _completed_at, ^worker} ->
        :erlang.unalias(reply_alias)
        Process.exit(worker, :kill)
        await_start_worker_down(worker, monitor)
        {:error, :timeout}

      {^operation_ref, result, completed_at, ^worker} ->
        :erlang.unalias(reply_alias)
        await_start_worker_down(worker, monitor)

        if completed_at <= deadline,
          do: result,
          else: {:error, :timeout}

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        :erlang.unalias(reply_alias)
        {:error, {:startup_worker_exit, Arbor.LLM.sanitize_external_reason(reason)}}
    after
      remaining ->
        :erlang.unalias(reply_alias)
        Process.exit(worker, :kill)
        await_start_worker_down(worker, monitor)
        {:error, :timeout}
    end
  end

  defp await_start_worker_down(worker, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    after
      @callback_cleanup_timeout_ms -> Process.demonitor(monitor, [:flush])
    end
  end

  defp start_acp_client(opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    result = apply(acp_client_module(), :start_link, [opts])

    case result do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, Arbor.LLM.sanitize_external_reason(reason)}

      other ->
        {:error, {:invalid_acp_client_start, Arbor.LLM.sanitize_external_reason(other)}}
    end
  rescue
    exception ->
      {:error, {:start_failed, Arbor.LLM.external_exception_message(exception)}}
  catch
    :exit, reason ->
      {:error, {:start_exit, Arbor.LLM.sanitize_external_reason(reason)}}

    kind, reason ->
      {:error, {:start_failure, kind, Arbor.LLM.sanitize_external_reason(reason)}}
  end

  defp attach_client(client) when is_pid(client) do
    if Process.alive?(client) do
      monitor = Process.monitor(client)
      Process.link(client)

      if Process.alive?(client) do
        {:ok, monitor}
      else
        Process.demonitor(monitor, [:flush])
        {:error, :client_died_during_startup}
      end
    else
      {:error, :client_died_during_startup}
    end
  end

  defp attach_client(_client), do: {:error, :invalid_client_pid}

  defp startup_failed(state, client, workspace, reason) do
    reason = Arbor.LLM.sanitize_external_reason(reason)
    terminate_client(client)
    cleanup_workspace_owned(workspace)
    cleanup_runtime_home(state.runtime_home_cleanup)

    Logger.error(
      "Failed to start ACP client for #{state.provider}: " <>
        Arbor.LLM.inspect_external_reason(reason)
    )

    new_state = %{
      state
      | client: nil,
        client_monitor: nil,
        workspace: nil,
        runtime_home_cleanup: nil,
        status: :error,
        startup_error: reason
    }

    emit_signal(:acp_session_error, new_state, %{error: reason, phase: :startup})
    {:noreply, new_state}
  end

  defp owner_alive?(nil), do: true
  defp owner_alive?(owner) when is_pid(owner), do: Process.alive?(owner)
  defp owner_alive?(_owner), do: false

  defp disconnect_client_owned(%{client: nil}, _opts), do: :ok

  defp disconnect_client_owned(%{client: client}, opts) do
    if Process.alive?(client) do
      result =
        OwnedOperation.run(
          fn ->
            # credo:disable-for-next-line Credo.Check.Refactor.Apply
            apply(acp_client_module(), :disconnect, [client])
          end,
          opts,
          :timeout
        )

      case result do
        {:error, reason} ->
          terminate_client(client)
          {:error, Arbor.LLM.sanitize_external_reason(reason)}

        _result ->
          terminate_client(client)
          :ok
      end
    else
      :ok
    end
  end

  defp terminate_client(client) when is_pid(client) do
    if Process.alive?(client), do: Process.exit(client, :kill)
    :ok
  end

  defp terminate_client(_client), do: :ok

  defp terminate_server(server) when is_pid(server) do
    if Process.alive?(server) do
      Process.unlink(server)
      Process.exit(server, :kill)
    end

    :ok
  end

  defp terminate_server(server) when is_atom(server) do
    case Process.whereis(server) do
      pid when is_pid(pid) -> terminate_server(pid)
      nil -> :ok
    end
  end

  defp terminate_server(_server), do: :ok

  defp internal_cleanup_opts do
    {:ok, opts, _timeout} = Arbor.AI.Timeout.start_deadline([], @callback_cleanup_timeout_ms)
    opts
  end

  defp emit_signal(event, state, metadata \\ %{}) do
    # arbor_signals is a direct dep — emit directly.
    signal_data =
      %{
        provider: state.provider,
        session_id: state.session_id,
        model: state.model,
        status: state.status
      }
      |> Map.merge(metadata)

    Arbor.Signals.emit(:agent, event, signal_data)
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end

  # -- Session Updates --

  @progress_update_types [
    "agent_message_chunk",
    "agent_thought_chunk",
    "tool_call",
    "tool_call_update",
    "plan",
    "text"
  ]

  defp process_session_update(state, session_id, update, opts) do
    callback_result =
      case stream_callback_opts(opts) do
        {:ok, callback_opts} -> run_stream_callback(state.stream_callback, update, callback_opts)
        {:error, _reason} -> {:error, :stream_callback_timeout}
      end

    # Accumulate streaming text chunks (Gemini/adapter sessions can deliver text
    # via session/update instead of the prompt result) and a bounded stream tail
    # for task transcript artifacts.
    state =
      state
      |> then(&accumulate_text(update, &1))
      |> accumulate_stream_tail(update)

    Logger.debug(
      "ACP session #{Arbor.LLM.inspect_external_reason(session_id)} update: " <>
        Arbor.LLM.inspect_external_reason(update_type(update))
    )

    case callback_result do
      :ok ->
        {:ok, state}

      {:error, :stream_callback_timeout} ->
        {:error, :stream_callback_timeout, state}

      {:error, reason} ->
        Logger.warning(
          "AcpSession stream_callback failed: " <>
            Arbor.LLM.inspect_external_reason(reason)
        )

        {:ok, state}
    end
  end

  defp run_stream_callback(nil, _update, _opts), do: :ok

  defp run_stream_callback(callback, update, opts) when is_function(callback, 1) do
    case OwnedOperation.run(
           fn -> {:stream_callback_returned, callback.(update)} end,
           opts,
           :stream_callback_timeout
         ) do
      {:stream_callback_returned, _result} -> :ok
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_stream_callback_result}
    end
  end

  defp run_stream_callback(_callback, _update, _opts),
    do: {:error, :invalid_stream_callback}

  defp stream_callback_opts(opts) do
    with {:ok, _opts, remaining} <- Arbor.AI.Timeout.remaining(opts) do
      timeout =
        case remaining do
          :infinity -> @stream_callback_timeout_ms
          value -> min(value, @stream_callback_timeout_ms)
        end

      case Arbor.AI.Timeout.start_deadline([], timeout) do
        {:ok, callback_opts, _timeout} -> {:ok, callback_opts}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp progress_update?(update), do: update_type(update) in @progress_update_types

  defp update_type(update) when is_map(update) do
    Map.get(update, "sessionUpdate") ||
      Map.get(update, :sessionUpdate) ||
      Map.get(update, "kind") ||
      Map.get(update, :kind) ||
      "unknown"
  end

  defp update_type(_), do: "unknown"

  # -- Streaming Text Accumulation --

  # Legacy format (ExMCP < 0.9)
  defp accumulate_text(%{"kind" => "text", "content" => content}, state)
       when is_binary(content) do
    %{state | accumulated_text: state.accumulated_text <> content}
  end

  # New ACP spec format (ExMCP >= 0.9)
  defp accumulate_text(
         %{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => text}},
         state
       )
       when is_binary(text) do
    %{state | accumulated_text: state.accumulated_text <> text}
  end

  defp accumulate_text(_, state), do: state

  # A nil accumulator means this standalone call has no trusted durability sink.
  defp accumulate_stream_tail(%{stream_tail: tail} = state, update) when is_map(tail) do
    %{state | stream_tail: AcpTranscript.append_stream_event(tail, update)}
  end

  defp accumulate_stream_tail(state, _update), do: state

  defp prepare_prompt_capture(state, nil),
    do: %{state | accumulated_text: "", stream_tail: nil}

  defp prepare_prompt_capture(state, _capture),
    do: %{state | accumulated_text: "", stream_tail: AcpTranscript.empty_stream_tail()}

  defp clear_prompt_capture(state), do: %{state | accumulated_text: "", stream_tail: nil}

  @doc false
  def merge_accumulated_text(result, "") when is_map(result), do: result

  def merge_accumulated_text(result, accumulated)
      when is_map(result) and is_binary(accumulated) do
    existing = Map.get(result, "text") || Map.get(result, :text)

    if is_nil(existing) or existing == "" do
      Map.put(result, "text", accumulated)
    else
      result
    end
  end

  def merge_accumulated_text(result, _), do: result

  # -- Usage & Context Tracking --

  # Extract bounded input/output token counts from an ACP prompt result.
  # Precedence: top-level string/atom "usage", then "_meta"/:_meta -> "usage"/:usage.
  # Token aliases are first-PRESENT: an invalid preferred key yields 0 and does
  # not fall through to a later alias. Only non-negative finite integers count.
  # Never copies arbitrary _meta into session state.
  defp extract_prompt_usage(result) when is_map(result) do
    usage = prompt_usage_map(result)

    %{
      input_tokens: usage_token(usage, ["input_tokens", :input_tokens, "inputTokens"]),
      output_tokens: usage_token(usage, ["output_tokens", :output_tokens, "outputTokens"])
    }
  end

  defp extract_prompt_usage(_), do: %{input_tokens: 0, output_tokens: 0}

  defp prompt_usage_map(result) do
    cond do
      is_map(Map.get(result, "usage")) ->
        Map.get(result, "usage")

      is_map(Map.get(result, :usage)) ->
        Map.get(result, :usage)

      true ->
        nested_meta_usage(result)
    end
  end

  defp nested_meta_usage(result) do
    meta = Map.get(result, "_meta") || Map.get(result, :_meta)

    cond do
      not is_map(meta) ->
        %{}

      is_map(Map.get(meta, "usage")) ->
        Map.get(meta, "usage")

      is_map(Map.get(meta, :usage)) ->
        Map.get(meta, :usage)

      true ->
        %{}
    end
  end

  # First present alias wins. Missing keys continue; present-but-invalid => 0.
  defp usage_token(usage, keys) when is_map(usage) do
    Enum.find_value(keys, 0, fn key ->
      case Map.fetch(usage, key) do
        {:ok, value} when is_integer(value) and value >= 0 ->
          if Arbor.LLM.finite_number?(value), do: value, else: 0

        {:ok, _invalid} ->
          0

        :error ->
          nil
      end
    end)
  end

  defp accumulate_usage(state, result) when is_map(result) do
    %{input_tokens: input, output_tokens: output} = extract_prompt_usage(result)

    %{
      state
      | usage: %{
          input_tokens: checked_add_tokens(state.usage.input_tokens, input),
          output_tokens: checked_add_tokens(state.usage.output_tokens, output)
        },
        # Latest input_tokens approximates current context size
        context_tokens: input
    }
  end

  defp accumulate_usage(state, _), do: state

  # Keep the last valid signed-64 cumulative count when addition would overflow.
  defp checked_add_tokens(current, delta)
       when is_integer(current) and is_integer(delta) do
    sum = current + delta

    if Arbor.LLM.finite_number?(sum), do: sum, else: current
  end

  defp checked_add_tokens(current, _delta) when is_integer(current), do: current
  defp checked_add_tokens(_current, _delta), do: 0

  # -- Cost Attribution --

  defp maybe_report_usage(state, result) do
    if Code.ensure_loaded?(Arbor.AI.BudgetTracker) and
         Process.whereis(Arbor.AI.BudgetTracker) != nil do
      usage = extract_prompt_usage(result)
      model = state.model || "unknown"

      try do
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(Arbor.AI.BudgetTracker, :record_usage, [
          provider_to_backend(state.provider),
          %{
            model: model,
            input_tokens: usage.input_tokens,
            output_tokens: usage.output_tokens
          }
        ])
      rescue
        _ -> :ok
      catch
        _kind, _reason -> :ok
      end
    end
  end

  defp provider_to_backend(:claude), do: :anthropic
  defp provider_to_backend(:codex), do: :openai
  defp provider_to_backend(:gemini), do: :google
  defp provider_to_backend(other), do: other

  # -- Crash Recovery --

  defp maybe_reconnect(%{status: :recovery_required}), do: :error
  defp maybe_reconnect(%{reconnect_attempted: true}), do: :error
  defp maybe_reconnect(%{last_session_id: nil}), do: :error

  defp maybe_reconnect(state) do
    session_pid = self()
    operation_opts = internal_reconnect_opts()
    cwd = workspace_cwd(state.workspace, state.opts)

    result =
      with {:ok, client_opts} <- resolve_client_opts(state.provider, state.opts),
           {:ok, client_opts} <-
             RuntimeHome.inject(client_opts, state.runtime_home_cleanup, state.provider) do
        GrokSandbox.with_launch(
          state.provider,
          client_opts,
          cwd,
          Keyword.get(state.opts, :grok_sandbox_authority),
          state.owner,
          state.mcp_servers,
          fn prepared_opts ->
            OwnedOperation.run(
              fn ->
                reconnect_client(state, session_pid, prepared_opts, cwd, operation_opts)
              end,
              operation_opts,
              :reconnect_timeout
            )
          end
        )
        |> unwrap_grok_launch()
      end

    case result do
      {:ok, client} ->
        case attach_client(client) do
          {:ok, client_monitor} ->
            {:ok,
             %{
               state
               | client: client,
                 client_monitor: client_monitor,
                 session_id: state.last_session_id,
                 status: :ready,
                 reconnect_attempted: true
             }}

          {:error, _reason} ->
            terminate_client(client)
            :error
        end

      _error ->
        :error
    end
  end

  defp reconnect_client(state, session_pid, client_opts, cwd, operation_opts) do
    client_opts = configure_client_opts(client_opts, session_pid, state.opts, cwd)
    lifecycle_opts = bind_mcp_servers(operation_opts, state.mcp_servers)

    with {:ok, client} <- start_acp_client(client_opts) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(acp_client_module(), :load_session, [
             client,
             state.last_session_id,
             cwd,
             lifecycle_opts
           ]) do
        {:ok, _session_info} ->
          {:ok, client}

        _error ->
          terminate_client(client)
          :error
      end
    else
      _error -> :error
    end
  end

  defp internal_reconnect_opts do
    {:ok, opts, _timeout} = Arbor.AI.Timeout.start_deadline([], @default_close_timeout_ms)
    opts
  end

  defp summarize_result(result) when is_map(result) do
    text =
      Enum.find_value(["text", :text], "", fn key ->
        case Map.fetch(result, key) do
          {:ok, value} when is_binary(value) -> value
          _missing_or_invalid -> nil
        end
      end)

    %{text_length: String.length(text)}
  end

  defp summarize_result(_), do: %{}

  defp call_timeout(t) when is_integer(t) and t > 0, do: t
  defp call_timeout(:infinity), do: :infinity

  defp safe_lifecycle_call(session, message, timeout) do
    GenServer.call(session, message, call_timeout(timeout))
  rescue
    exception ->
      {:error, {:session_call_failed, Arbor.LLM.external_exception_message(exception)}}
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, {:noproc, _call} -> {:error, :session_unavailable}
    :exit, {:normal, _call} -> {:error, :session_unavailable}
    :exit, reason -> {:error, {:session_call_exit, Arbor.LLM.sanitize_external_reason(reason)}}
  end

  defp safe_prompt_call(session, content, opts, timeout) do
    case GenServer.whereis(session) do
      pid when is_pid(pid) -> do_safe_prompt_call(pid, content, opts, timeout)
      nil -> {:error, :session_unavailable}
    end
  rescue
    exception ->
      {:error, {:session_call_failed, Arbor.LLM.external_exception_message(exception)}}
  catch
    :exit, {:noproc, _call} -> {:error, :session_unavailable}
    :exit, reason -> {:error, {:session_call_exit, Arbor.LLM.sanitize_external_reason(reason)}}
  end

  defp do_safe_prompt_call(session, content, opts, timeout) when is_pid(session) do
    # The session owns the hard-timeout transition. Once it has accepted the
    # prompt, wait for that authoritative reply instead of racing a second
    # caller-side timeout against the session's timeout timer. The acceptance
    # handshake still bounds time spent waiting behind another GenServer call.
    proxy_ref = make_ref()
    parent = self()

    {proxy, monitor} =
      spawn_monitor(fn ->
        prompt_call_proxy(parent, session, content, opts, proxy_ref)
      end)

    receive do
      {:acp_prompt_proxy, ^proxy_ref, :accepted} ->
        await_prompt_proxy_result(proxy_ref, monitor, proxy)

      {:acp_prompt_proxy, ^proxy_ref, {:result, result}} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^proxy, _reason} ->
        {:error, :session_unavailable}
    after
      call_timeout(timeout) ->
        stop_prompt_proxy(proxy, monitor)
        {:error, :timeout}
    end
  end

  defp prompt_call_proxy(parent, session, content, opts, proxy_ref) do
    call_ref = make_ref()
    session_monitor = Process.monitor(session)
    parent_monitor = Process.monitor(parent)
    send(session, {:"$gen_call", {self(), call_ref}, {:send_message, content, opts}})

    receive do
      {:acp_prompt_accepted, ^call_ref} ->
        send(parent, {:acp_prompt_proxy, proxy_ref, :accepted})
        await_prompt_proxy_reply(parent, parent_monitor, session_monitor, call_ref, proxy_ref)

      {^call_ref, result} ->
        send(parent, {:acp_prompt_proxy, proxy_ref, {:result, result}})

      {:DOWN, ^session_monitor, :process, ^session, _reason} ->
        send(parent, {:acp_prompt_proxy, proxy_ref, {:result, {:error, :session_unavailable}}})

      {:DOWN, ^parent_monitor, :process, ^parent, _reason} ->
        :ok
    end
  end

  defp await_prompt_proxy_result(proxy_ref, monitor, proxy) do
    receive do
      {:acp_prompt_proxy, ^proxy_ref, {:result, result}} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^proxy, _reason} ->
        {:error, :session_unavailable}
    end
  end

  defp stop_prompt_proxy(proxy, monitor) do
    Process.exit(proxy, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^proxy, _reason} -> :ok
    after
      @callback_cleanup_timeout_ms ->
        Process.demonitor(monitor, [:flush])
    end
  end

  defp await_prompt_proxy_reply(parent, parent_monitor, session_monitor, call_ref, proxy_ref) do
    receive do
      {^call_ref, result} ->
        send(parent, {:acp_prompt_proxy, proxy_ref, {:result, result}})

      {:DOWN, ^session_monitor, :process, _session, _reason} ->
        send(parent, {:acp_prompt_proxy, proxy_ref, {:result, {:error, :session_unavailable}}})

      {:DOWN, ^parent_monitor, :process, ^parent, _reason} ->
        :ok
    end
  end

  defp acknowledge_prompt_call({caller, ref}) when is_pid(caller) and is_reference(ref),
    do: send(caller, {:acp_prompt_accepted, ref})

  defp acknowledge_prompt_call(_from), do: :ok

  defp prompt_caller_alive?({caller, _ref}) when is_pid(caller), do: Process.alive?(caller)
  defp prompt_caller_alive?(_from), do: false

  defp operation_timed_out(phase, state) do
    new_state = %{state | status: :error}
    emit_signal(:acp_session_error, new_state, %{error: :timeout, phase: phase})
    {:stop, :normal, {:error, :timeout}, new_state}
  end

  # -- Workspace Lifecycle --

  defp workspace_plan(opts) do
    case Keyword.get(opts, :workspace) do
      {:worktree, wt_opts} ->
        id = System.unique_integer([:positive])
        branch = Keyword.get(wt_opts, :branch, "acp/session-#{id}")
        base = Keyword.get(wt_opts, :base_dir, System.tmp_dir!())
        path = Path.join(base, "acp-worktree-#{id}")

        {:worktree_pending, path, branch}

      {:directory, path} ->
        {:directory_pending, path}

      nil ->
        nil
    end
  end

  defp materialize_workspace({:worktree_pending, path, branch}) do
    case System.cmd("git", ["worktree", "add", path, "-b", branch], stderr_to_stdout: true) do
      {_, 0} ->
        {:worktree, path, branch}

      {output, _} ->
        Logger.warning("AcpSession: failed to create worktree: #{String.trim(output)}")
        nil
    end
  end

  defp materialize_workspace({:directory_pending, path}) do
    if File.dir?(path) do
      {:directory, path}
    else
      Logger.warning("AcpSession: workspace directory does not exist: #{path}")
      nil
    end
  end

  defp materialize_workspace(workspace), do: workspace

  # Lazily establish the ACP session before the first prompt. The pool/adapter
  # path checks a session out and prompts without an explicit create_session, so
  # session_id would be nil and the agent receives "sessionId": null. cwd is
  # derived from the workspace (as in init/1), not state.opts[:cwd], which is
  # absent in the pool flow.
  defp do_send_message(content, opts, from, state) do
    with {:ok, opts, hard_timeout} <- Arbor.AI.Timeout.remaining(opts),
         {:ok, deadline_ms} <- Arbor.AI.Timeout.deadline(opts) do
      capture = transcript_capture(opts)
      state = prepare_prompt_capture(%{state | status: :busy}, capture)
      inactivity_timeout = inactivity_timeout(opts)

      # Monitor the GenServer.call owner for this prompt. When orchestration
      # cancel kills the action/turn process, we abort the ACP prompt immediately
      # instead of waiting for inactivity timeout.
      caller_pid = elem(from, 0)
      caller_ref = Process.monitor(caller_pid)

      prompt =
        start_task_prompt(state, content, opts, hard_timeout, inactivity_timeout)
        |> Map.merge(%{
          caller_pid: caller_pid,
          caller_ref: caller_ref,
          control: nil,
          prompt_text: content,
          prompt_kind: "initial",
          capture_index: 0,
          transcript_capture: capture,
          deadline_ms: deadline_ms
        })

      timers =
        start_prompt_timers(prompt.ref,
          hard_timeout: hard_timeout,
          inactivity_timeout: inactivity_timeout
        )

      await_prompt_result(prompt, timers, state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp start_prompt_worker(client, session_id, content, opts) do
    parent = self()
    ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result = run_prompt(client, session_id, content, opts)
        send(parent, {:acp_prompt_result, ref, result, System.monotonic_time(:millisecond)})
      end)

    %{pid: pid, monitor_ref: monitor_ref, ref: ref, caller_pid: nil, caller_ref: nil}
  end

  defp start_task_prompt(state, content, opts, hard_timeout, inactivity_timeout) do
    start_prompt_worker(
      state.client,
      state.session_id,
      content,
      prompt_client_opts(opts, hard_timeout)
    )
    |> Map.merge(%{
      prompt_opts: opts,
      hard_timeout: hard_timeout,
      inactivity_timeout: inactivity_timeout
    })
  end

  # -- Managed task controls -----------------------------------------------

  # A control is only accepted as data. There is deliberately no attempt to
  # infer a vendor-specific steering protocol from its text; stable ACP has no
  # standard native-steer operation. Accepted controls run as ordered follow-up
  # prompts against this exact client/session after the current prompt finishes.
  defp accept_queued_task_control(control, %{status: :busy} = state) do
    with {:ok, control} <- normalize_task_control(control) do
      case Map.fetch(state.task_controls, control.control_id) do
        {:ok, existing} ->
          existing_busy_task_control_result(existing, state)

        :error ->
          with {:ok, state} <- ensure_task_control_capacity(state),
               :ok <- ensure_queue_capacity(state) do
            control = Map.put(control, :status, :queued)
            state = put_task_control(state, control, queue?: true)
            emit_native_steer_unsupported(state, control)

            emit_task_control_signal(
              :acp_task_control_queued,
              state,
              control,
              :accepted_while_prompt_active
            )

            {{:ok, :queued, :same_session_follow_up}, state}
          else
            {:error, reason} ->
              emit_task_control_unsupported(state, control, reason)
              {{:error, reason}, state}
          end
      end
    else
      {:error, reason} ->
        emit_invalid_task_control_signal(state, control, reason)
        {{:error, reason}, state}
    end
  end

  defp accept_queued_task_control(control, state) do
    accept_deferred_task_control(control, state)
  end

  defp accept_deferred_task_control(control, state) do
    with {:ok, control} <- normalize_task_control(control) do
      case Map.fetch(state.task_controls, control.control_id) do
        {:ok, existing} ->
          existing_idle_task_control_result(existing, state)

        :error when state.status == :ready ->
          with {:ok, state} <- ensure_task_control_capacity(state) do
            control = Map.put(control, :status, :deferred)
            state = put_task_control(state, control)
            emit_native_steer_unsupported(state, control)

            emit_task_control_signal(
              :acp_task_control_deferred,
              state,
              control,
              :no_active_prompt
            )

            {{:ok, :deferred, :same_session_follow_up}, state}
          else
            {:error, reason} ->
              emit_task_control_unsupported(state, control, reason)
              {{:error, reason}, state}
          end

        :error ->
          {{:error, {:not_ready, state.status}}, state}
      end
    else
      {:error, reason} ->
        emit_invalid_task_control_signal(state, control, reason)
        {{:error, reason}, state}
    end
  end

  defp next_queued_task_control(state) do
    case Enum.find(state.task_control_sequence, fn control_id ->
           match?(%{status: :queued}, Map.get(state.task_controls, control_id))
         end) do
      nil ->
        {:none, state}

      control_id ->
        {{control_id, Map.fetch!(state.task_controls, control_id)}, state}
    end
  end

  # A deferred control was accepted while no prompt existed. Retrying its same
  # opaque ID during a prompt turns that accepted instruction into one ordered
  # follow-up; a different retry payload cannot replace the original message.
  defp promote_deferred_task_control(%{status: :deferred} = control, state) do
    case ensure_queue_capacity(state) do
      :ok ->
        control = %{control | status: :queued}
        state = put_task_control(state, control, queue?: true)

        emit_task_control_signal(
          :acp_task_control_queued,
          state,
          control,
          :deferred_control_promoted
        )

        {{:ok, :queued, :same_session_follow_up}, state}

      {:error, reason} ->
        emit_task_control_unsupported(state, control, reason)
        {{:error, reason}, state}
    end
  end

  defp existing_busy_task_control_result(%{status: :deferred} = control, state),
    do: promote_deferred_task_control(control, state)

  defp existing_busy_task_control_result(control, state),
    do: existing_task_control_result(control, state)

  defp existing_idle_task_control_result(%{status: :queued} = control, state) do
    state =
      transition_task_control(
        state,
        control.control_id,
        :not_delivered,
        :prompt_ended_before_delivery
      )

    existing_task_control_result(Map.fetch!(state.task_controls, control.control_id), state)
  end

  defp existing_idle_task_control_result(control, state),
    do: existing_task_control_result(control, state)

  defp existing_task_control_result(%{status: :delivered}, state),
    do: {{:ok, :delivered, :same_session_follow_up}, state}

  defp existing_task_control_result(%{status: status} = control, state)
       when status in @terminal_task_control_statuses do
    reason = Map.get(control, :reason, :unspecified)
    {{:error, {:task_control_terminal, status, reason}}, state}
  end

  defp existing_task_control_result(%{status: status}, state),
    do: {{:ok, status, :same_session_follow_up}, state}

  defp ensure_task_control_capacity(state) do
    state = prune_terminal_task_controls(state)

    if map_size(state.task_controls) < @max_task_control_history,
      do: {:ok, state},
      else: {:error, :task_control_history_full}
  end

  defp ensure_queue_capacity(state) do
    if queued_task_control_count(state) < @max_queued_task_controls,
      do: :ok,
      else: {:error, :task_control_queue_full}
  end

  defp queued_task_control_count(state) do
    Enum.count(state.task_controls, fn {_id, control} -> control.status == :queued end)
  end

  # Keep idempotency data bounded without dropping queued or deferred controls.
  # Terminal entries are pruned oldest-first; once every slot is non-terminal
  # the caller gets an explicit backpressure error instead of silent replay.
  defp prune_terminal_task_controls(state) do
    if map_size(state.task_controls) < @max_task_control_history do
      state
    else
      case Enum.find(state.task_control_history_order, fn control_id ->
             terminal_task_control?(Map.get(state.task_controls, control_id))
           end) do
        nil ->
          state

        control_id ->
          %{
            state
            | task_controls: Map.delete(state.task_controls, control_id),
              task_control_sequence: List.delete(state.task_control_sequence, control_id),
              task_control_history_order:
                List.delete(state.task_control_history_order, control_id)
          }
      end
    end
  end

  defp put_task_control(state, control, opts \\ []) do
    queue? = Keyword.get(opts, :queue?, false)
    existing? = Map.has_key?(state.task_controls, control.control_id)

    %{
      state
      | task_controls: Map.put(state.task_controls, control.control_id, control),
        task_control_sequence:
          if(queue?,
            do: state.task_control_sequence ++ [control.control_id],
            else: state.task_control_sequence
          ),
        task_control_history_order:
          if(existing?,
            do: state.task_control_history_order,
            else: state.task_control_history_order ++ [control.control_id]
          )
    }
  end

  defp mark_task_control_delivered(state, %{control: nil} = _prompt), do: state

  defp mark_task_control_delivered(state, %{control: control_id}) do
    transition_task_control(state, control_id, :delivered, :provider_prompt_completed)
  end

  defp terminal_task_control?(%{status: status}),
    do: status in @terminal_task_control_statuses

  defp terminal_task_control?(_control), do: false

  defp transition_task_control(state, control_id, status, reason, opts \\ [])
       when status in @terminal_task_control_statuses do
    case Map.fetch(state.task_controls, control_id) do
      {:ok, %{status: current_status}}
      when current_status in @terminal_task_control_statuses ->
        state

      {:ok, control} ->
        updated = control |> Map.put(:status, status) |> Map.put(:reason, reason)
        state = %{state | task_controls: Map.put(state.task_controls, control_id, updated)}

        if Keyword.get(opts, :emit?, true) do
          emit_task_control_signal(task_control_event(status), state, updated, reason)
        end

        state

      :error ->
        state
    end
  end

  defp task_control_event(:delivered), do: :acp_task_control_delivered
  defp task_control_event(:not_delivered), do: :acp_task_control_not_delivered
  defp task_control_event(:delivery_unknown), do: :acp_task_control_delivery_unknown
  defp task_control_event(:cancelled), do: :acp_task_control_cancelled

  defp settle_failed_prompt_task_controls(state, prompt, failure, opts \\ []) do
    {active_reason, queued_reason} = task_control_failure_reasons(failure)

    state =
      if prompt.control do
        transition_task_control(state, prompt.control, :delivery_unknown, active_reason, opts)
      else
        state
      end

    settle_task_controls(
      state,
      [:queued],
      :not_delivered,
      queued_reason,
      Keyword.put(opts, :except, prompt.control)
    )
  end

  defp settle_cancelled_prompt_task_controls(state, prompt, cancellation, opts) do
    state =
      if prompt.control do
        transition_task_control(
          state,
          prompt.control,
          :delivery_unknown,
          cancellation_delivery_reason(cancellation),
          opts
        )
      else
        state
      end

    settle_task_controls(
      state,
      [:queued, :deferred],
      :cancelled,
      cancellation,
      Keyword.put(opts, :except, prompt.control)
    )
  end

  defp settle_pending_task_controls(state, status, reason) do
    settle_task_controls(state, [:queued, :deferred], status, reason)
  end

  defp settle_task_controls(state, source_statuses, status, reason, opts \\ []) do
    except = Keyword.get(opts, :except)

    Enum.reduce(state.task_control_history_order, state, fn control_id, acc ->
      control = Map.get(acc.task_controls, control_id)

      if control_id != except and is_map(control) and
           Enum.member?(source_statuses, Map.get(control, :status)) do
        transition_task_control(acc, control_id, status, reason, opts)
      else
        acc
      end
    end)
  end

  defp task_control_failure_reasons(:provider_error),
    do: {:provider_delivery_failed, :provider_prompt_failed_before_delivery}

  defp task_control_failure_reasons(:prompt_exit),
    do: {:provider_delivery_exited, :provider_prompt_exited_before_delivery}

  defp task_control_failure_reasons(:client_lost),
    do: {:provider_delivery_client_lost, :provider_client_lost_before_delivery}

  defp task_control_failure_reasons(:timeout),
    do: {:provider_delivery_timed_out, :provider_prompt_timed_out_before_delivery}

  defp task_control_failure_reasons(:inactivity_timeout),
    do: {:provider_delivery_inactivity_unknown, :provider_prompt_inactive_before_delivery}

  defp task_control_failure_reasons(:stream_callback_timeout),
    do: {:stream_callback_timed_out, :stream_callback_timed_out_before_delivery}

  defp cancellation_delivery_reason(:caller_cancelled),
    do: :caller_cancelled_during_delivery

  defp cancellation_delivery_reason(:owner_cancelled),
    do: :owner_cancelled_during_delivery

  defp normalize_task_control(control) when is_map(control) do
    control_id = Map.get(control, :control_id) || Map.get(control, "control_id")
    message = Map.get(control, :message) || Map.get(control, "message")
    task_id = Map.get(control, :task_id) || Map.get(control, "task_id")

    with :ok <- bounded_nonblank(control_id, @max_task_control_id_bytes, :invalid_control_id),
         :ok <-
           bounded_nonblank(message, @max_task_control_message_bytes, :invalid_control_message),
         :ok <- bounded_nonblank(task_id, @max_task_id_bytes, :invalid_task_id) do
      {:ok, %{control_id: control_id, message: message, task_id: task_id}}
    end
  end

  defp normalize_task_control(_), do: {:error, :invalid_task_control}

  defp bounded_nonblank(value, max_bytes, _reason)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= max_bytes do
    if String.trim(value) == "", do: {:error, :blank_task_control}, else: :ok
  end

  defp bounded_nonblank(_value, _max_bytes, reason), do: {:error, reason}

  defp task_control_capabilities_for(state) do
    Config.task_control_capabilities(state.provider)
  end

  defp emit_task_control_signal(event, state, control, reason, metadata \\ %{}) do
    data =
      %{
        control_id: bounded_signal_value(control.control_id, @max_task_control_id_bytes),
        task_id: bounded_signal_value(control.task_id, @max_task_id_bytes),
        agent_id: bounded_signal_value(Keyword.get(state.opts, :agent_id), @max_task_id_bytes),
        session_id: bounded_signal_value(state.session_id, @max_task_id_bytes),
        provider: state.provider,
        mode: :same_session_follow_up,
        status: Map.get(control, :status, :unsupported),
        reason: bounded_task_control_reason(reason)
      }
      |> Map.merge(metadata)

    Arbor.Signals.durable_emit(:agent, event, data, stream_id: @task_control_stream_id)
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp emit_native_steer_unsupported(state, control) do
    emit_task_control_unsupported(state, control, :native_steer_unavailable)
  end

  defp emit_task_control_unsupported(state, control, reason) do
    capabilities = task_control_capabilities_for(state)

    emit_task_control_signal(
      :acp_task_control_unsupported,
      state,
      control,
      reason,
      %{
        native_steer: capabilities.native_steer,
        native_steer_configured: capabilities.native_steer_configured,
        native_steer_acknowledged: capabilities.native_steer_acknowledged
      }
    )
  end

  defp emit_invalid_task_control_signal(state, control, reason) do
    task_id =
      if is_map(control), do: Map.get(control, :task_id) || Map.get(control, "task_id"), else: nil

    control_id =
      if is_map(control),
        do: Map.get(control, :control_id) || Map.get(control, "control_id"),
        else: nil

    # Keep malformed caller input out of signals except for bounded IDs.
    emit_task_control_unsupported(
      state,
      %{
        control_id: bounded_signal_value(control_id, @max_task_control_id_bytes),
        task_id: bounded_signal_value(task_id, @max_task_id_bytes)
      },
      reason
    )
  end

  defp bounded_signal_value(value, max_bytes)
       when is_binary(value) and byte_size(value) <= max_bytes,
       do: value

  defp bounded_signal_value(_value, _max_bytes), do: nil

  defp bounded_task_control_reason(reason) when is_atom(reason), do: reason

  defp bounded_task_control_reason(reason)
       when is_binary(reason) and byte_size(reason) <= @max_task_control_reason_bytes,
       do: reason

  defp bounded_task_control_reason(_reason), do: :unspecified

  defp run_prompt(client, session_id, content, opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(acp_client_module(), :prompt, [client, session_id, content, opts]) do
      {:ok, result} ->
        case validate_acp_result(result, :prompt) do
          :ok -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, Arbor.LLM.sanitize_external_reason(reason)}

      other ->
        {:error, {:unexpected_prompt_result, Arbor.LLM.sanitize_external_reason(other)}}
    end
  rescue
    exception ->
      {:error, {:prompt_failed, Arbor.LLM.external_exception_message(exception)}}
  catch
    :exit, {:timeout, _} ->
      {:error, :timeout}

    :exit, reason ->
      {:error, {:prompt_exit, Arbor.LLM.sanitize_external_reason(reason)}}

    kind, reason ->
      {:error, {:prompt_failure, kind, Arbor.LLM.sanitize_external_reason(reason)}}
  end

  defp new_acp_session(client, cwd, opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(acp_client_module(), :new_session, [client, cwd, opts]) do
      {:ok, session_info} ->
        case validate_acp_result(session_info, :session) do
          :ok -> {:ok, session_info}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, Arbor.LLM.sanitize_external_reason(reason)}

      other ->
        {:error, {:unexpected_session_result, Arbor.LLM.sanitize_external_reason(other)}}
    end
  rescue
    exception ->
      {:error, {:session_failed, Arbor.LLM.external_exception_message(exception)}}
  catch
    kind, reason ->
      {:error, {:session_failure, kind, Arbor.LLM.sanitize_external_reason(reason)}}
  end

  defp await_prompt_result(prompt, timers, state) do
    receive do
      {:acp_prompt_result, ref, {:ok, result}, completed_at} when ref == prompt.ref ->
        if Arbor.AI.Timeout.completed_before_deadline?(completed_at, prompt.deadline_ms) do
          complete_prompt_success(prompt, timers, result, completed_at, state)
        else
          timeout_prompt(:timeout, prompt, timers, state)
        end

      {:acp_task_control, ref, reply_to, control} when is_reference(ref) and is_pid(reply_to) ->
        {result, new_state} = accept_queued_task_control(control, state)
        send(reply_to, {:acp_task_control_result, ref, result})
        await_prompt_result(prompt, timers, new_state)

      {:acp_prompt_result, ref, {:error, :timeout}, _completed_at} when ref == prompt.ref ->
        timeout_prompt(:timeout, prompt, timers, state)

      {:acp_prompt_result, ref, {:error, reason} = error, completed_at} when ref == prompt.ref ->
        cleanup_prompt(prompt, timers)

        if Arbor.AI.Timeout.completed_before_deadline?(completed_at, prompt.deadline_ms) do
          complete_prompt_error(prompt, :provider_error, reason, error, state)
        else
          timeout_prompt(:timeout, prompt, timers, state)
        end

      {:DOWN, monitor_ref, :process, _pid, reason} when monitor_ref == prompt.monitor_ref ->
        cleanup_prompt(prompt, timers)
        reason = Arbor.LLM.sanitize_external_reason(reason)

        complete_prompt_error(
          prompt,
          :prompt_exit,
          reason,
          {:error, {:prompt_exit, reason}},
          state
        )

      {:DOWN, _ref, :process, pid, reason} when pid == state.client ->
        kill_prompt_worker(prompt)
        cleanup_prompt(prompt, timers)
        reason = Arbor.LLM.sanitize_external_reason(reason)

        complete_prompt_error(prompt, :client_down, reason, {:error, :client_down}, %{
          state
          | client: nil
        })

      # Caller (GenServer.call owner) and/or session owner disappeared — cancel
      # the ACP prompt immediately. Prefer monitor DOWN only: EXIT is drained
      # below so trap_exit does not leave a stale message or double-cancel.
      {:DOWN, ref, :process, _pid, _reason} when ref == prompt.caller_ref ->
        timeout_prompt(:caller_cancelled, prompt, timers, state)

      {:DOWN, ref, :process, _pid, _reason} when ref == state.owner_monitor ->
        timeout_prompt(:owner_cancelled, prompt, timers, state)

      {:EXIT, _pid, _reason} ->
        # Linked owner/client EXIT under trap_exit; DOWN handles real cleanup.
        await_prompt_result(prompt, timers, state)

      {:acp_session_update, session_id, update} ->
        case process_session_update(state, session_id, update, prompt.prompt_opts) do
          {:ok, new_state} ->
            timers =
              maybe_reset_inactivity_timer(timers, prompt.ref, session_id, new_state, update)

            await_prompt_result(prompt, timers, new_state)

          {:error, :stream_callback_timeout, new_state} ->
            timeout_prompt(
              prompt_timeout_kind(prompt, :stream_callback_timeout),
              prompt,
              timers,
              new_state
            )
        end

      # start_timer/3 delivers {:timeout, TRef, payload}; TRef is both the
      # cancellable handle and the stale-timer discriminator.
      {:timeout, timer_ref, {:acp_prompt_inactivity_timeout, ref}}
      when ref == prompt.ref and timer_ref == timers.inactivity_timer ->
        timeout_prompt(:inactivity_timeout, prompt, timers, state)

      {:timeout, _stale_timer_ref, {:acp_prompt_inactivity_timeout, ref}}
      when ref == prompt.ref ->
        await_prompt_result(prompt, timers, state)

      {:timeout, timer_ref, {:acp_prompt_hard_timeout, ref}}
      when ref == prompt.ref and timer_ref == timers.hard_timer ->
        timeout_prompt(:timeout, prompt, timers, state)

      {:timeout, _stale_timer_ref, {:acp_prompt_hard_timeout, ref}}
      when ref == prompt.ref ->
        await_prompt_result(prompt, timers, state)

      {:timeout, _stale_timer_ref, {:acp_prompt_inactivity_timeout, _stale_ref}} ->
        await_prompt_result(prompt, timers, state)

      {:timeout, _stale_timer_ref, {:acp_prompt_hard_timeout, _stale_ref}} ->
        await_prompt_result(prompt, timers, state)
    end
  end

  defp complete_prompt_success(prompt, timers, result, completed_at, state) do
    cleanup_prompt(prompt, timers, preserve_caller_monitor: true)

    # A few adapters enqueue the final chunks immediately before returning the
    # prompt result. Drain anything already queued before merging text.
    case drain_pending_updates(state, prompt.prompt_opts) do
      {:ok, state} ->
        complete_prompt_after_updates(
          prompt,
          result,
          completed_at,
          drain_pending_task_controls(state)
        )

      {:error, :stream_callback_timeout, state} ->
        timeout_prompt(
          prompt_timeout_kind(prompt, :stream_callback_timeout),
          prompt,
          empty_prompt_timers(),
          state
        )
    end
  end

  defp complete_prompt_after_updates(prompt, result, completed_at, state) do
    result = merge_accumulated_text(result, state.accumulated_text)

    if Arbor.AI.Timeout.completed_before_deadline?(
         max(completed_at, System.monotonic_time(:millisecond)),
         prompt.deadline_ms
       ) do
      complete_durable_prompt_success(prompt, result, state)
    else
      timeout_prompt(:timeout, prompt, empty_prompt_timers(), state)
    end
  end

  defp prompt_timeout_kind(prompt, fallback) do
    if hard_deadline_exhausted?(prompt), do: :timeout, else: fallback
  end

  defp hard_deadline_exhausted?(%{deadline_ms: deadline}) when is_integer(deadline) do
    System.monotonic_time(:millisecond) >= deadline
  end

  defp hard_deadline_exhausted?(_prompt), do: false

  defp complete_durable_prompt_success(prompt, result, state) do
    case capture_prompt_turn(prompt, :success, result, nil, state) do
      {:ok, descriptor} ->
        result = maybe_attach_transcript_descriptor(result, descriptor)

        new_state =
          %{state | status: :busy}
          |> accumulate_usage(result)
          |> mark_task_control_delivered(prompt)

        continue_after_durable_prompt(prompt, result, new_state)

      {:error, reason} ->
        transcript_durability_failed(prompt, state, reason)
    end
  end

  defp continue_after_durable_prompt(prompt, result, state) do
    # The sink runs synchronously while this GenServer owns the prompt. Controls
    # can arrive during that durability wait, so accept them against the still-
    # busy state before deciding whether the prompt chain is complete.
    state = drain_pending_task_controls(state)

    case next_queued_task_control(state) do
      {:none, state} ->
        maybe_report_usage(state, result)
        emit_signal(:acp_session_completed, state, %{result: summarize_result(result)})
        demonitor_owner(prompt.caller_ref)
        {:reply, {:ok, result}, clear_prompt_capture(%{state | status: :ready})}

      {{control_id, control}, state} ->
        case Arbor.AI.Timeout.remaining(prompt.prompt_opts) do
          {:ok, follow_up_opts, remaining} ->
            follow_up =
              start_task_prompt(
                state,
                control.message,
                follow_up_opts,
                remaining,
                prompt.inactivity_timeout
              )
              |> Map.merge(%{
                caller_pid: prompt.caller_pid,
                caller_ref: prompt.caller_ref,
                control: control_id,
                prompt_text: control.message,
                prompt_kind: "task_control",
                capture_index: prompt.capture_index + 1,
                transcript_capture: prompt.transcript_capture,
                deadline_ms: prompt.deadline_ms
              })

            follow_up_timers =
              start_prompt_timers(follow_up.ref,
                hard_timeout: follow_up.hard_timeout,
                inactivity_timeout: follow_up.inactivity_timeout
              )

            capture_state = prepare_prompt_capture(state, prompt.transcript_capture)
            await_prompt_result(follow_up, follow_up_timers, capture_state)

          {:error, _reason} ->
            timeout_before_follow_up(prompt, state)
        end
    end
  end

  defp complete_prompt_error(prompt, terminal_status, reason, reply, state) do
    case capture_prompt_turn(prompt, terminal_status, nil, reason, state) do
      {:ok, _descriptor} ->
        settlement_failure =
          case terminal_status do
            :client_down -> :client_lost
            other -> other
          end

        new_state =
          state
          |> settle_failed_prompt_task_controls(prompt, settlement_failure)
          |> clear_prompt_capture()
          |> Map.put(:status, :error)

        emit_signal(:acp_session_error, new_state, %{error: reason, phase: :prompt})
        {:reply, reply, new_state}

      {:error, sink_reason} ->
        transcript_durability_failed(prompt, state, sink_reason, terminal_status)
    end
  end

  defp capture_prompt_turn(%{transcript_capture: nil}, _status, _result, _error, _state),
    do: {:ok, nil}

  defp capture_prompt_turn(prompt, status, result, error, state) do
    capture = prompt.transcript_capture

    attrs = %{
      execution_id: capture.execution_id,
      capture_index: prompt.capture_index,
      prompt_kind: prompt.prompt_kind,
      control_id: prompt.control,
      terminal_status: terminal_status_name(status),
      prompt: prompt.prompt_text,
      response_text: prompt_response_text(result, state),
      error: capture_error(error),
      stop_reason: prompt_stop_reason(result),
      provider: state.provider,
      provider_session_id: state.session_id || state.last_session_id,
      stream_tail: state.stream_tail || AcpTranscript.empty_stream_tail(),
      captured_at: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    }

    with {:ok, turn} <- AcpTranscript.build_turn(attrs) do
      run_transcript_sink(capture, turn)
    end
  end

  defp run_transcript_sink(capture, turn) do
    result =
      Arbor.LLM.run_with_deadline(
        fn -> {:transcript_sink_result, invoke_transcript_sink(capture.sink, turn)} end,
        capture.timeout_ms,
        :transcript_sink_timeout
      )

    case result do
      {:transcript_sink_result, {:ok, descriptor}} ->
        if AcpTranscript.valid_descriptor?(descriptor),
          do: {:ok, descriptor},
          else: {:error, :invalid_transcript_descriptor_ack}

      {:transcript_sink_result, {:error, reason}} ->
        {:error, {:transcript_sink_failed, Arbor.LLM.sanitize_external_reason(reason)}}

      {:transcript_sink_result, other} ->
        {:error, {:invalid_transcript_sink_ack, Arbor.LLM.sanitize_external_reason(other)}}

      {:error, :transcript_sink_timeout} ->
        {:error, :transcript_sink_timeout}

      {:error, reason} ->
        {:error, {:transcript_sink_failed, Arbor.LLM.sanitize_external_reason(reason)}}
    end
  end

  defp invoke_transcript_sink({module, function, fixed_args}, turn) do
    # The sink remains reload-stable data. This short-lived apply executes only
    # inside the monitored deadline worker and is never retained in session state.
    apply(module, function, fixed_args ++ [turn])
  end

  defp maybe_attach_transcript_descriptor(result, nil), do: result

  defp maybe_attach_transcript_descriptor(result, descriptor) when is_map(result),
    do: Map.put(result, "transcript", descriptor)

  defp transcript_durability_failed(prompt, state, reason, outcome \\ :provider_succeeded) do
    previous_state = state

    {new_state, lifecycle} =
      case outcome do
        :provider_succeeded ->
          settled =
            state
            |> mark_task_control_delivered(prompt)
            |> settle_task_controls(
              [:queued],
              :not_delivered,
              :transcript_durability_failed_before_delivery
            )

          {settled |> clear_prompt_capture() |> Map.put(:status, :error), :reply}

        cancellation when cancellation in [:caller_cancelled, :owner_cancelled] ->
          settled =
            settle_cancelled_prompt_task_controls(
              state,
              prompt,
              cancellation,
              emit?: false
            )

          {settled |> clear_prompt_capture() |> Map.put(:status, :error), :stop}

        timeout when timeout in [:timeout, :inactivity_timeout] ->
          settled =
            state
            |> settle_failed_prompt_task_controls(prompt, timeout, emit?: false)
            |> clear_prompt_capture()
            |> Map.put(:status, :recovery_required)

          control_events = changed_task_control_events(previous_state, settled)
          {enqueue_pending_settlement(settled, timeout, control_events), :timeout_reply}

        :stream_callback_timeout ->
          settled =
            state
            |> settle_failed_prompt_task_controls(prompt, :stream_callback_timeout, emit?: false)
            |> clear_prompt_capture()
            |> Map.put(:status, :error)

          {settled, :stop}

        failure ->
          settlement_failure = if failure == :client_down, do: :client_lost, else: failure
          settled = settle_failed_prompt_task_controls(state, prompt, settlement_failure)
          {settled |> clear_prompt_capture() |> Map.put(:status, :error), :reply}
      end

    demonitor_owner(prompt.caller_ref)

    emit_signal(:acp_session_error, new_state, %{
      error: :transcript_durability_failed,
      reason: Arbor.LLM.sanitize_external_reason(reason),
      phase: :transcript_sink
    })

    case lifecycle do
      :reply ->
        {:reply, {:error, {:transcript_durability_failed, reason}}, new_state}

      :timeout_reply ->
        {:reply, {:error, {:transcript_durability_failed, outcome, reason}}, new_state}

      :stop ->
        _ = cancel_acp_prompt_owned(previous_state, internal_cleanup_opts())
        _ = disconnect_client_owned(previous_state, internal_cleanup_opts())

        emit_timeout_observability(
          new_state,
          outcome,
          changed_task_control_events(previous_state, new_state)
        )

        {:stop, :normal, {:error, {:transcript_durability_failed, outcome, reason}}, new_state}
    end
  end

  defp timeout_before_follow_up(prompt, state) do
    previous_state = state

    new_state =
      state
      |> settle_task_controls(
        [:queued],
        :not_delivered,
        :provider_prompt_timed_out_before_delivery
      )
      |> clear_prompt_capture()
      |> Map.put(:status, :recovery_required)

    control_events = changed_task_control_events(previous_state, new_state)
    new_state = enqueue_pending_settlement(new_state, :timeout, control_events)
    demonitor_owner(prompt.caller_ref)
    {:reply, {:error, :timeout}, new_state}
  end

  defp prompt_response_text(result, state) when is_map(result) do
    Map.get(result, "text") || Map.get(result, :text) || state.accumulated_text || ""
  end

  defp prompt_response_text(_result, state), do: state.accumulated_text || ""

  defp prompt_stop_reason(result) when is_map(result) do
    Map.get(result, "stop_reason") || Map.get(result, :stop_reason) ||
      Map.get(result, "stopReason") || Map.get(result, :stopReason) || ""
  end

  defp prompt_stop_reason(_result), do: ""

  defp capture_error(nil), do: ""
  defp capture_error(reason), do: Arbor.LLM.inspect_external_reason(reason)

  defp terminal_status_name(:success), do: "success"
  defp terminal_status_name(:provider_error), do: "provider_error"
  defp terminal_status_name(:timeout), do: "timeout"
  defp terminal_status_name(:inactivity_timeout), do: "inactivity_timeout"
  defp terminal_status_name(:stream_callback_failure), do: "stream_callback_failure"
  defp terminal_status_name(:stream_callback_timeout), do: "stream_callback_timeout"
  defp terminal_status_name(:prompt_exit), do: "prompt_exit"
  defp terminal_status_name(:client_down), do: "client_down"

  defp terminal_status_name(status) when status in [:caller_cancelled, :owner_cancelled],
    do: "cancelled"

  defp timeout_prompt(kind, prompt, timers, state) do
    kill_prompt_worker(prompt)
    cleanup_prompt(prompt, timers)

    case capture_prompt_turn(prompt, kind, nil, kind, state) do
      {:ok, _descriptor} ->
        finish_timed_out_prompt(kind, prompt, state)

      {:error, reason} ->
        transcript_durability_failed(prompt, state, reason, kind)
    end
  end

  defp finish_timed_out_prompt(kind, prompt, state) do
    previous_state = state

    new_state =
      case kind do
        cancellation when cancellation in [:caller_cancelled, :owner_cancelled] ->
          settle_cancelled_prompt_task_controls(state, prompt, cancellation, emit?: false)

        failure when failure in [:timeout, :inactivity_timeout, :stream_callback_timeout] ->
          settle_failed_prompt_task_controls(state, prompt, failure, emit?: false)
      end
      |> clear_prompt_capture()
      |> Map.put(
        :status,
        if(kind in [:timeout, :inactivity_timeout], do: :recovery_required, else: :error)
      )

    error = if kind in [:caller_cancelled, :owner_cancelled], do: :cancelled, else: kind

    if kind in [:timeout, :inactivity_timeout] do
      control_events = changed_task_control_events(previous_state, new_state)
      new_state = enqueue_pending_settlement(new_state, kind, control_events)
      {:reply, {:error, error}, new_state}
    else
      _ = cancel_acp_prompt_owned(state, internal_cleanup_opts())
      _ = disconnect_client_owned(state, internal_cleanup_opts())

      emit_timeout_observability(
        new_state,
        kind,
        changed_task_control_events(previous_state, new_state)
      )

      {:stop, :normal, {:error, error}, new_state}
    end
  end

  defp emit_timeout_observability(state, kind, control_events) do
    Enum.each(control_events, fn {event, control, reason} ->
      emit_task_control_signal(event, state, control, reason)
    end)

    if kind == :inactivity_timeout do
      emit_signal(:acp_session_idle, state, %{
        reason: :inactivity_timeout,
        phase: :prompt
      })
    end

    error = if kind in [:caller_cancelled, :owner_cancelled], do: :cancelled, else: kind
    emit_signal(:acp_session_error, state, %{error: error, phase: :prompt})
  end

  defp enqueue_pending_settlement(state, kind, control_events) do
    ref = make_ref()
    settlement = %{kind: kind, control_events: control_events}

    state = %{
      state
      | pending_settlements: Map.put(state.pending_settlements, ref, settlement),
        pending_settlement_order: state.pending_settlement_order ++ [ref]
    }

    send(self(), {:acp_timeout_settlement, ref})
    state
  end

  defp take_pending_settlement(state, ref) do
    case Map.pop(state.pending_settlements, ref) do
      {nil, _pending} ->
        :not_found

      {settlement, pending} ->
        {:ok, settlement,
         %{
           state
           | pending_settlements: pending,
             pending_settlement_order: List.delete(state.pending_settlement_order, ref)
         }}
    end
  end

  defp flush_pending_settlements(%{pending_settlement_order: []} = state), do: state

  defp flush_pending_settlements(state) do
    settlements =
      Enum.flat_map(state.pending_settlement_order, fn ref ->
        case Map.fetch(state.pending_settlements, ref) do
          {:ok, settlement} -> [settlement]
          :error -> []
        end
      end)

    state = %{state | pending_settlements: %{}, pending_settlement_order: []}
    Enum.each(settlements, &emit_pending_timeout_settlement(state, &1))
    state
  end

  defp emit_pending_timeout_settlement(state, %{kind: kind, control_events: control_events}) do
    cancel_acp_prompt(state)
    emit_timeout_observability(state, kind, control_events)
  end

  defp changed_task_control_events(before, settled) do
    Enum.flat_map(settled.task_control_history_order, fn control_id ->
      previous = Map.get(before.task_controls, control_id)
      current = Map.get(settled.task_controls, control_id)

      if is_map(previous) and is_map(current) and
           previous.status != current.status and terminal_task_control?(current) do
        [{task_control_event(current.status), current, Map.get(current, :reason, :unspecified)}]
      else
        []
      end
    end)
  end

  defp cleanup_prompt(prompt, timers, opts \\ []) do
    Process.demonitor(prompt.monitor_ref, [:flush])

    unless Keyword.get(opts, :preserve_caller_monitor, false),
      do: demonitor_owner(Map.get(prompt, :caller_ref))

    cancel_prompt_timers(timers)
  end

  defp monitor_owner(owner) when is_pid(owner) do
    if Process.alive?(owner) do
      {owner, Process.monitor(owner)}
    else
      {owner, nil}
    end
  end

  defp monitor_owner(_owner), do: {nil, nil}

  defp demonitor_owner(ref) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    :ok
  end

  defp demonitor_owner(_), do: :ok

  defp kill_prompt_worker(prompt) do
    if Process.alive?(prompt.pid), do: Process.exit(prompt.pid, :kill)
  end

  defp cancel_acp_prompt(%{client: nil}), do: :ok

  defp cancel_acp_prompt(%{client: client, session_id: session_id}) do
    module = acp_client_module()

    if Process.alive?(client) and function_exported?(module, :cancel, 2) do
      run_cleanup_callback(fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(module, :cancel, [client, session_id])
      end)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp cancel_acp_prompt_owned(%{client: nil}, _opts), do: :ok

  defp cancel_acp_prompt_owned(%{client: client, session_id: session_id}, opts) do
    module = acp_client_module()

    if Process.alive?(client) and function_exported?(module, :cancel, 2) do
      OwnedOperation.run(
        fn ->
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          apply(module, :cancel, [client, session_id])
        end,
        opts,
        :timeout
      )
    else
      :ok
    end
  end

  defp run_cleanup_callback(callback) when is_function(callback, 0) do
    Task.start(fn ->
      {pid, monitor} =
        spawn_monitor(fn ->
          try do
            callback.()
          rescue
            _exception -> :ok
          catch
            _kind, _reason -> :ok
          end
        end)

      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
      after
        @callback_cleanup_timeout_ms ->
          if Process.alive?(pid), do: Process.exit(pid, :kill)

          receive do
            {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
          after
            @callback_cleanup_timeout_ms -> Process.demonitor(monitor, [:flush])
          end
      end
    end)

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp start_prompt_timers(prompt_ref, opts) do
    hard_timeout = Keyword.fetch!(opts, :hard_timeout)
    inactivity_timeout = Keyword.fetch!(opts, :inactivity_timeout)

    %{
      hard_timeout: hard_timeout,
      hard_timer: schedule_timer(hard_timeout, {:acp_prompt_hard_timeout, prompt_ref}),
      inactivity_timeout: inactivity_timeout,
      inactivity_timer:
        schedule_timer(inactivity_timeout, {:acp_prompt_inactivity_timeout, prompt_ref})
    }
  end

  defp empty_prompt_timers do
    %{
      hard_timeout: :infinity,
      hard_timer: nil,
      inactivity_timeout: :infinity,
      inactivity_timer: nil
    }
  end

  defp schedule_timer(:infinity, _message), do: nil

  defp schedule_timer(timeout_ms, {tag, prompt_ref}) when is_integer(timeout_ms) do
    # Use start_timer/3 so the delivered message carries the same reference that
    # Process.cancel_timer/1 accepts. A synthetic make_ref()/send_after pairing
    # leaves live timers after "cancel" and floods stale inactivity messages.
    :erlang.start_timer(timeout_ms, self(), {tag, prompt_ref})
  end

  defp maybe_reset_inactivity_timer(timers, prompt_ref, session_id, state, update) do
    if session_id == state.session_id and progress_update?(update) do
      cancel_timer(timers.inactivity_timer)

      %{
        timers
        | inactivity_timer:
            schedule_timer(
              timers.inactivity_timeout,
              {:acp_prompt_inactivity_timeout, prompt_ref}
            )
      }
    else
      timers
    end
  end

  defp cancel_prompt_timers(timers) do
    cancel_timer(timers.hard_timer)
    cancel_timer(timers.inactivity_timer)
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) when is_reference(timer_ref) do
    case Process.cancel_timer(timer_ref) do
      false ->
        # Timer already fired (or never existed): non-blockingly drop the exact
        # delivered message so completion races do not hit handle_info/2.
        receive do
          {:timeout, ^timer_ref, _payload} -> :ok
        after
          0 -> :ok
        end

      _remaining_ms ->
        :ok
    end

    :ok
  end

  defp prompt_client_opts(opts, hard_timeout) do
    opts
    |> Keyword.delete(:inactivity_timeout_ms)
    |> drop_transcript_capture_opts()
    |> Keyword.put(:timeout, hard_timeout)
  end

  defp inactivity_timeout(opts) do
    opts
    |> Keyword.fetch!(:inactivity_timeout_ms)
    |> normalize_timeout(@default_inactivity_timeout_ms)
  end

  defp normalize_prompt_timeouts(opts) do
    default_inactivity =
      Application.get_env(:arbor_ai, :acp_inactivity_timeout_ms, @default_inactivity_timeout_ms)

    with {:ok, opts, _timeout} <-
           Arbor.AI.Timeout.start_deadline(opts, @default_operation_timeout_ms),
         {:ok, opts, _inactivity} <-
           Arbor.AI.Timeout.normalize_key(opts, :inactivity_timeout_ms, default_inactivity,
             minimum: 0,
             allow_infinity: true
           ),
         {:ok, opts} <- normalize_transcript_capture_opts(opts) do
      {:ok, opts}
    end
  end

  defp normalize_transcript_capture_opts(opts) do
    sink = Keyword.get(opts, :transcript_sink)
    execution_id = Keyword.get(opts, :transcript_execution_id)

    cond do
      is_nil(sink) and is_nil(execution_id) ->
        {:ok, Keyword.delete(opts, :transcript_sink_timeout_ms)}

      valid_transcript_sink?(sink) and valid_transcript_execution_id?(execution_id) ->
        case Keyword.get(opts, :transcript_sink_timeout_ms, @default_transcript_sink_timeout_ms) do
          timeout
          when is_integer(timeout) and timeout > 0 and
                 timeout <= @max_transcript_sink_timeout_ms ->
            {:ok, Keyword.put(opts, :transcript_sink_timeout_ms, timeout)}

          _ ->
            {:error, :invalid_transcript_sink_timeout}
        end

      true ->
        {:error, :invalid_transcript_capture}
    end
  end

  defp transcript_capture(opts) do
    case Keyword.get(opts, :transcript_sink) do
      nil ->
        nil

      sink ->
        %{
          sink: sink,
          execution_id: Keyword.fetch!(opts, :transcript_execution_id),
          timeout_ms: Keyword.fetch!(opts, :transcript_sink_timeout_ms)
        }
    end
  end

  defp valid_transcript_sink?({module, function, fixed_args})
       when is_atom(module) and is_atom(function) and is_list(fixed_args) and
              length(fixed_args) <= 8 do
    Enum.all?(fixed_args, &transcript_sink_arg?/1)
  end

  defp valid_transcript_sink?(_sink), do: false

  defp transcript_sink_arg?(value)
       when is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value),
       do: true

  defp transcript_sink_arg?(value) when is_atom(value), do: true
  defp transcript_sink_arg?(_value), do: false

  defp valid_transcript_execution_id?(execution_id) when is_binary(execution_id) do
    String.valid?(execution_id) and String.trim(execution_id) != "" and
      byte_size(execution_id) <= 512 and not String.contains?(execution_id, <<0>>) and
      not String.match?(execution_id, ~r/[\x00-\x1F\x7F]/)
  end

  defp valid_transcript_execution_id?(_execution_id), do: false

  defp drop_transcript_capture_opts(opts) do
    Keyword.drop(opts, [
      :transcript_sink,
      :transcript_execution_id,
      :transcript_sink_timeout_ms
    ])
  end

  defp normalize_timeout(:infinity, _default), do: :infinity

  defp normalize_timeout(timeout_ms, _default) when is_integer(timeout_ms) and timeout_ms >= 0,
    do: timeout_ms

  defp normalize_timeout(_timeout_ms, default), do: default

  # Process {:acp_session_update} messages already queued in the mailbox. Most
  # updates are handled in the prompt wait loop; this catches final chunks that
  # arrive just before the client returns the prompt result.
  @doc false
  def drain_pending_updates(state) do
    {:ok, opts, _timeout} =
      Arbor.AI.Timeout.start_deadline([], @stream_callback_timeout_ms)

    case drain_pending_updates(state, opts) do
      {:ok, state} -> state
      {:error, :stream_callback_timeout, state} -> Map.put(state, :status, :error)
    end
  end

  defp drain_pending_updates(state, opts) do
    receive do
      {:acp_session_update, session_id, update} ->
        case process_session_update(state, session_id, update, opts) do
          {:ok, state} ->
            drain_pending_updates(state, opts)

          {:error, :stream_callback_timeout, state} ->
            {:error, :stream_callback_timeout, state}
        end
    after
      0 -> {:ok, state}
    end
  end

  # A prompt result and a control can cross in the mailbox. Drain controls that
  # were already accepted by the process scheduler while the prompt was active
  # before deciding whether to reply to the original caller.
  defp drain_pending_task_controls(%{status: :busy} = state) do
    receive do
      {:acp_task_control, ref, reply_to, control} when is_reference(ref) and is_pid(reply_to) ->
        {result, state} = accept_queued_task_control(control, state)
        send(reply_to, {:acp_task_control_result, ref, result})
        drain_pending_task_controls(state)
    after
      0 -> state
    end
  end

  defp ensure_session(%{session_id: sid} = state, _opts) when is_binary(sid), do: {:ok, state}

  defp ensure_session(state, opts) do
    cwd =
      Keyword.get(opts, :cwd) ||
        workspace_cwd(state.workspace, state.opts) ||
        process_cwd_with_log()

    new_opts = bind_mcp_servers(opts, state.mcp_servers)

    provider_opts = drop_transcript_capture_opts(new_opts)

    result =
      OwnedOperation.run(
        fn -> new_acp_session(state.client, cwd, provider_opts) end,
        opts,
        :timeout
      )

    case result do
      {:ok, info} ->
        sid = Map.get(info, "sessionId") || Map.get(info, :session_id)

        with :ok <- maybe_select_model(state.client, sid, state.model, opts) do
          {:ok, %{state | session_id: sid, last_session_id: sid}}
        end

      {:error, reason} ->
        {:error, Arbor.LLM.sanitize_external_reason(reason)}
    end
  end

  defp validate_acp_result(result, kind) when is_map(result) do
    with :ok <-
           Arbor.LLM.validate_decoded_term(result,
             max_bytes: 4_194_304,
             max_nodes: 20_000,
             max_depth: 24,
             max_map_keys: 4_000,
             max_list_items: 20_000
           ),
         :ok <- validate_acp_text(result),
         :ok <- validate_acp_usage(result) do
      :ok
    else
      {:error, reason} -> {:error, {:invalid_acp_result, kind, reason}}
    end
  end

  defp validate_acp_result(_result, kind),
    do: {:error, {:invalid_acp_result, kind, :map_required}}

  defp validate_acp_text(result) do
    validate_alias_values(
      result,
      ["text", :text],
      fn
        nil -> true
        text -> is_binary(text)
      end,
      :binary_text_required
    )
  end

  defp validate_acp_usage(result) do
    usages = present_alias_values(result, ["usage", :usage])

    case usages do
      [] ->
        :ok

      values ->
        if Enum.all?(values, &is_map/1) do
          Enum.reduce_while(values, :ok, fn usage, :ok ->
            case validate_acp_token_fields(usage) do
              :ok -> {:cont, :ok}
              {:error, _reason} = error -> {:halt, error}
            end
          end)
        else
          {:error, :usage_map_required}
        end
    end
  end

  defp validate_alias_values(map, keys, predicate, error) do
    if Enum.all?(present_alias_values(map, keys), predicate), do: :ok, else: {:error, error}
  end

  defp present_alias_values(map, keys) do
    Enum.reduce(keys, [], fn key, values ->
      case Map.fetch(map, key) do
        {:ok, value} -> [value | values]
        :error -> values
      end
    end)
  end

  defp validate_acp_token_fields(usage) do
    fields = [
      "input_tokens",
      :input_tokens,
      "inputTokens",
      "output_tokens",
      :output_tokens,
      "outputTokens"
    ]

    if Enum.all?(fields, fn field ->
         case Map.fetch(usage, field) do
           :error -> true
           {:ok, value} -> is_integer(value) and value >= 0 and Arbor.LLM.finite_number?(value)
         end
       end) do
      :ok
    else
      {:error, :bounded_non_negative_token_usage_required}
    end
  end

  # Best-effort model selection for router agents (e.g. opencode) that expose a
  # "model" config option via session/set_config_option. Agents that pick their
  # model another way reject this, which we ignore. Without it, opencode runs on
  # an unselected default and returns an empty turn.
  defp maybe_put_kw(kw, _key, nil), do: kw
  defp maybe_put_kw(kw, key, value), do: Keyword.put(kw, key, value)

  # Thread the workspace path to the spawned CLI's OS process cwd so native-fs
  # agents resolve relative writes inside the workspace, not the directory the
  # BEAM runs from. Without this, the ACP session/new cwd is set but the OS cwd
  # is inherited (the repo root) and native writes escape the sandbox.
  # Native agents (Stdio transport) read :cd; adapted agents (adapter_bridge)
  # read :cwd from adapter_opts.
  defp inject_os_cwd(client_opts, nil), do: client_opts

  defp inject_os_cwd(client_opts, cwd) do
    client_opts
    |> Keyword.put(:cd, cwd)
    |> put_adapter_cwd(cwd)
  end

  defp put_adapter_cwd(client_opts, cwd) do
    case Keyword.get(client_opts, :adapter_opts) do
      ao when is_list(ao) ->
        Keyword.put(client_opts, :adapter_opts, Keyword.put(ao, :cwd, cwd))

      _ ->
        client_opts
    end
  end

  defp maybe_select_model(_client, _sid, model, _opts) when model in [nil, ""], do: :ok

  defp maybe_select_model(client, sid, model, opts) do
    case OwnedOperation.run(
           fn ->
             # credo:disable-for-next-line Credo.Check.Refactor.Apply
             apply(acp_client_module(), :set_config_option, [client, sid, "model", model])
           end,
           opts,
           :timeout
         ) do
      {:error, :timeout} -> {:error, :timeout}
      _result -> :ok
    end
  end

  defp workspace_cwd({:worktree, path, _branch}, _opts), do: path
  defp workspace_cwd({:worktree_pending, path, _branch}, _opts), do: path
  defp workspace_cwd({:directory, path}, _opts), do: path
  defp workspace_cwd({:directory_pending, path}, _opts), do: path
  defp workspace_cwd(_, opts), do: Keyword.get(opts, :cwd)

  # ex_mcp's Protocol.encode_session_{new,load,resume} require a non-nil
  # cwd per ACP spec. Without this fallback an internal callsite that
  # forgets to thread :cwd through (or a fresh session before the workspace
  # is set up) would raise FunctionClauseError at the wire boundary.
  # File.cwd!() — the BEAM process's working directory — is the natural
  # "agent works from where the server runs" default.
  defp resolve_cwd(opts, state_opts, workspace) do
    Keyword.get(opts, :cwd) ||
      Keyword.get(state_opts, :cwd) ||
      workspace_cwd(Keyword.get(opts, :workspace), []) ||
      workspace_cwd(workspace, []) ||
      process_cwd_with_log()
  end

  defp process_cwd_with_log do
    cwd = File.cwd!()

    Logger.debug(
      "AcpSession falling back to process cwd #{inspect(cwd)} — caller passed no :cwd " <>
        "and session opts have none either. Specify :cwd in init or per-call opts to silence."
    )

    cwd
  end

  defp cleanup_workspace({:worktree, path, branch}) do
    if File.dir?(path) do
      System.cmd("git", ["worktree", "remove", path, "--force"], stderr_to_stdout: true)
    end

    System.cmd("git", ["branch", "-D", branch], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp cleanup_workspace({:worktree_pending, path, branch}),
    do: cleanup_workspace({:worktree, path, branch})

  defp cleanup_workspace(_), do: :ok

  defp cleanup_workspace_owned(nil), do: :ok

  defp cleanup_workspace_owned(workspace) do
    case OwnedOperation.run(
           fn -> cleanup_workspace(workspace) end,
           internal_cleanup_opts(),
           :workspace_cleanup_timeout
         ) do
      {:error, _reason} -> :ok
      _result -> :ok
    end
  end

  defp cleanup_runtime_home(nil), do: :ok

  defp cleanup_runtime_home(cleanup_identity) when is_map(cleanup_identity) do
    case RuntimeHome.cleanup(cleanup_identity) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "AcpSession private runtime-home cleanup failed: " <>
            Arbor.LLM.inspect_external_reason(reason)
        )

        :ok
    end
  end

  defp cleanup_runtime_home(_invalid), do: :ok
end
