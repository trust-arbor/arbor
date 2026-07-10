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

  @default_acp_client ExMCP.ACP.Client
  @default_inactivity_timeout_ms 300_000
  @task_control_timeout_ms 5_000
  @max_task_control_message_bytes 16_384
  @max_task_control_id_bytes 256
  @max_task_id_bytes 512
  @max_task_control_reason_bytes 200
  @max_task_control_history 256
  @max_queued_task_controls 64
  @task_control_stream_id "agent:task_steering"
  @terminal_task_control_statuses [
    :delivered,
    :not_delivered,
    :delivery_unknown,
    :cancelled
  ]

  defstruct [
    :client,
    :session_id,
    :last_session_id,
    :provider,
    :model,
    :owner,
    :owner_monitor,
    :stream_callback,
    :opts,
    :workspace,
    :mcp_servers,
    status: :starting,
    accumulated_text: "",
    context_tokens: 0,
    reconnect_attempted: false,
    usage: %{input_tokens: 0, output_tokens: 0},
    task_controls: %{},
    task_control_sequence: [],
    task_control_history_order: []
  ]

  # -- Public API --

  @doc """
  Start a new AcpSession GenServer.

  ## Options

  - `:provider` — provider atom (required): `:claude`, `:codex`, `:gemini`, etc.
  - `:model` — model string override (optional)
  - `:system_prompt` — system prompt for the agent (optional)
  - `:cwd` — working directory for the session (optional)
  - `:stream_callback` — `fn(update) -> any()` for streaming events (optional)
  - `:timeout` — timeout for ACP operations in ms (default: 120_000)
  - `:name` — GenServer name registration (optional)
  - `:agent_id` — Arbor agent ID for security integration (optional)
  - `:adapter_opts` — additional adapter-specific options (optional)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    # Capture the starter as the session owner so we can monitor it even when
    # the session is start_link'd (linked) and later :kill'd — trap_exit +
    # monitor lets us abort prompts and disconnect the ACP client orderly.
    init_opts = Keyword.put_new(init_opts, :owner, self())
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Create a new ACP session with the connected agent.

  Must be called after `start_link/1` before sending messages.
  Returns session metadata from the agent.

  ## Options

  - `:cwd` — working directory for the session (overrides init cwd)
  """
  @spec create_session(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_session(session, opts \\ []) do
    GenServer.call(session, {:create_session, opts}, timeout(opts))
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
    GenServer.call(session, {:send_message, content, opts}, :infinity)
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
    ref = make_ref()
    send(session, {:acp_task_control, ref, self(), control})

    receive do
      {:acp_task_control_result, ^ref, result} -> result
    after
      Keyword.get(opts, :timeout, @task_control_timeout_ms) -> {:error, :control_delivery_timeout}
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
    GenServer.call(session, {:resume_session, session_id, opts}, timeout(opts))
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
  @spec close(GenServer.server()) :: :ok
  def close(session) do
    GenServer.call(session, :close, 30_000)
  end

  # -- GenServer Callbacks --

  @impl true
  def init(opts) do
    # Survive linked owner :kill so we can cancel the ACP prompt and disconnect
    # the client instead of vanishing without terminate/2.
    Process.flag(:trap_exit, true)

    provider = Keyword.fetch!(opts, :provider)
    {owner, owner_monitor} = monitor_owner(Keyword.get(opts, :owner))

    if acp_available?() do
      # Create workspace if requested
      workspace_result = maybe_create_workspace(opts)
      cwd = workspace_cwd(workspace_result, opts)

      resolved =
        case Keyword.get(opts, :client_opts) do
          nil -> Config.resolve(provider, opts)
          raw -> {:ok, raw}
        end

      case resolved do
        {:ok, client_opts} ->
          # Build client options with resolved workspace cwd
          client_opts =
            client_opts
            |> Keyword.put(:event_listener, self())
            |> Keyword.put_new(:handler, Arbor.AI.AcpSession.Handler)
            |> Keyword.put_new(:handler_opts,
              session_pid: self(),
              agent_id: Keyword.get(opts, :agent_id),
              cwd: cwd
            )
            |> maybe_put_kw(:capabilities, Keyword.get(opts, :capabilities))
            |> inject_os_cwd(cwd)

          case start_acp_client(client_opts) do
            {:ok, client} ->
              state = %__MODULE__{
                client: client,
                provider: provider,
                model: Keyword.get(opts, :model),
                owner: owner,
                owner_monitor: owner_monitor,
                stream_callback: Keyword.get(opts, :stream_callback),
                mcp_servers: Keyword.get(opts, :mcp_servers),
                workspace: workspace_result,
                status: :ready,
                opts: opts
              }

              emit_signal(:acp_session_started, state)
              {:ok, state}

            {:error, reason} ->
              demonitor_owner(owner_monitor)
              cleanup_workspace(workspace_result)
              Logger.error("Failed to start ACP client for #{provider}: #{inspect(reason)}")
              {:stop, reason}
          end

        {:error, reason} ->
          demonitor_owner(owner_monitor)
          cleanup_workspace(workspace_result)
          Logger.error("Unknown ACP provider: #{inspect(provider)}")
          {:stop, reason}
      end
    else
      Logger.warning("ExMCP.ACP.Client not available — AcpSession will not function")

      {:ok,
       %__MODULE__{
         provider: provider,
         owner: owner,
         owner_monitor: owner_monitor,
         status: :error,
         opts: opts
       }}
    end
  end

  @impl true
  def handle_call({:create_session, _opts}, _from, %{status: :error} = state) do
    {:reply, {:error, {:not_available, "ACP client not initialized"}}, state}
  end

  def handle_call({:create_session, opts}, _from, state) do
    cwd = resolve_cwd(opts, state.opts)

    # Inject mcp_servers from pool-provided ToolServer (if any)
    opts =
      case state.mcp_servers do
        servers when is_list(servers) and servers != [] ->
          Keyword.put_new(opts, :mcp_servers, servers)

        _ ->
          opts
      end

    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(acp_client_module(), :new_session, [state.client, cwd, opts]) do
      {:ok, session_info} ->
        session_id = Map.get(session_info, "sessionId") || Map.get(session_info, :session_id)

        new_state = %{
          state
          | session_id: session_id,
            last_session_id: session_id,
            status: :ready
        }

        {:reply, {:ok, session_info}, new_state}

      {:error, reason} = error ->
        Logger.warning("AcpSession create_session failed: #{inspect(reason)}")
        new_state = %{state | status: :error}
        emit_signal(:acp_session_error, new_state, %{error: reason, phase: :create})
        {:reply, error, new_state}
    end
  end

  def handle_call({:resume_session, _session_id, _opts}, _from, %{status: :error} = state) do
    {:reply, {:error, {:not_available, "ACP client not initialized"}}, state}
  end

  def handle_call({:resume_session, session_id, opts}, _from, state) do
    cwd = resolve_cwd(opts, state.opts)

    result =
      try do
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(acp_client_module(), :load_session, [state.client, session_id, cwd, opts])
      rescue
        e -> {:error, {:resume_failed, Exception.message(e)}}
      catch
        :exit, reason -> {:error, {:resume_exit, reason}}
      end

    case result do
      {:ok, session_info} ->
        new_state = %{
          state
          | session_id: session_id,
            last_session_id: session_id,
            status: :ready
        }

        emit_signal(:acp_session_started, new_state, %{resumed: true})
        {:reply, {:ok, session_info}, new_state}

      {:error, reason} = error ->
        Logger.warning("AcpSession resume_session failed: #{inspect(reason)}")
        emit_signal(:acp_session_error, state, %{error: reason, phase: :resume})
        {:reply, error, state}
    end
  end

  def handle_call({:send_message, _content, _opts}, _from, %{status: status} = state)
      when status not in [:ready] do
    {:reply, {:error, {:not_ready, status}}, state}
  end

  def handle_call({:send_message, content, opts}, from, state) do
    case ensure_session(state, opts) do
      {:ok, state} -> do_send_message(content, opts, from, state)
      {:error, reason} -> {:reply, {:error, reason}, %{state | status: :error}}
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

  def handle_call(:close, _from, state) do
    state = settle_pending_task_controls(state, :cancelled, :session_closed)
    disconnect_client(state)
    emit_signal(:acp_session_closed, state)
    {:stop, :normal, :ok, %{state | status: :closed}}
  end

  @impl true
  def handle_info({:acp_session_update, session_id, update}, state) do
    {:noreply, process_session_update(state, session_id, update)}
  end

  # No prompt is active. The control is retained for idempotency but there is
  # no in-flight ACP request to steer, so never claim it was delivered.
  def handle_info({:acp_task_control, ref, reply_to, control}, state)
      when is_reference(ref) and is_pid(reply_to) do
    {result, state} = accept_deferred_task_control(control, state)
    send(reply_to, {:acp_task_control_result, ref, result})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{owner_monitor: ref} = state) do
    Logger.info(
      "AcpSession owner gone (#{inspect(reason)}); aborting session #{inspect(state.session_id)}"
    )

    state = settle_pending_task_controls(state, :cancelled, :owner_cancelled)
    disconnect_client(state)
    emit_signal(:acp_session_closed, state, %{reason: :owner_cancelled})
    {:stop, :normal, %{state | status: :closed, owner_monitor: nil}}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{client: pid} = state) do
    Logger.warning("ACP client process died: #{inspect(reason)}")
    emit_signal(:acp_session_error, state, %{error: :client_down, reason: reason})

    # Attempt auto-reconnect if we have a session to resume (max 1 try)
    case maybe_reconnect(state) do
      {:ok, new_state} ->
        Logger.info("ACP client reconnected for session #{state.last_session_id}")
        {:noreply, new_state}

      :error ->
        new_state =
          state
          |> settle_pending_task_controls(:not_delivered, :provider_client_lost)
          |> Map.merge(%{status: :error, client: nil})

        {:noreply, new_state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    # trap_exit keeps us alive when a linked owner/client dies with :kill so the
    # matching Process.monitor DOWN path can cancel/disconnect orderly. Do not
    # handle owner/client cleanup here — that would race/double-run with DOWN.
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("AcpSession unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    _state = settle_pending_task_controls(state, :not_delivered, :session_terminated)
    demonitor_owner(state.owner_monitor)
    disconnect_client(state)
    cleanup_workspace(state.workspace)
    :ok
  end

  # -- Private --

  defp acp_client_module do
    Application.get_env(:arbor_ai, :acp_client_module, @default_acp_client)
  end

  defp acp_available? do
    Code.ensure_loaded?(acp_client_module())
  end

  defp start_acp_client(opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    result = apply(acp_client_module(), :start_link, [opts])

    case result do
      {:ok, pid} ->
        Process.monitor(pid)
        {:ok, pid}

      error ->
        error
    end
  rescue
    e -> {:error, {:start_failed, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:start_exit, reason}}
  end

  defp disconnect_client(%{client: nil}), do: :ok

  defp disconnect_client(%{client: client}) do
    if Process.alive?(client) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(acp_client_module(), :disconnect, [client])
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
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
    :exit, _ -> :ok
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

  defp process_session_update(state, session_id, update) do
    if state.stream_callback do
      try do
        state.stream_callback.(update)
      rescue
        exception -> Logger.warning("AcpSession stream_callback error: #{inspect(exception)}")
      end
    end

    # Accumulate streaming text chunks (Gemini/adapter sessions can deliver text
    # via session/update instead of the prompt result).
    state = accumulate_text(update, state)

    Logger.debug("ACP session #{session_id} update: #{inspect(update_type(update))}")
    state
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

  defp accumulate_usage(state, result) when is_map(result) do
    usage = Map.get(result, "usage") || Map.get(result, :usage) || %{}

    # Handle both snake_case (native ACP) and camelCase (Claude/Codex adapters)
    input =
      Map.get(usage, "input_tokens") || Map.get(usage, :input_tokens) ||
        Map.get(usage, "inputTokens") || 0

    output =
      Map.get(usage, "output_tokens") || Map.get(usage, :output_tokens) ||
        Map.get(usage, "outputTokens") || 0

    %{
      state
      | usage: %{
          input_tokens: state.usage.input_tokens + input,
          output_tokens: state.usage.output_tokens + output
        },
        # Latest input_tokens approximates current context size
        context_tokens: input
    }
  end

  defp accumulate_usage(state, _), do: state

  # -- Cost Attribution --

  defp maybe_report_usage(state, result) do
    if Code.ensure_loaded?(Arbor.AI.BudgetTracker) and
         Process.whereis(Arbor.AI.BudgetTracker) != nil do
      usage = Map.get(result, "usage") || Map.get(result, :usage) || %{}
      model = state.model || "unknown"

      try do
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(Arbor.AI.BudgetTracker, :record_usage, [
          provider_to_backend(state.provider),
          %{
            model: model,
            input_tokens:
              Map.get(usage, "input_tokens") || Map.get(usage, :input_tokens) ||
                Map.get(usage, "inputTokens") || 0,
            output_tokens:
              Map.get(usage, "output_tokens") || Map.get(usage, :output_tokens) ||
                Map.get(usage, "outputTokens") || 0
          }
        ])
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp provider_to_backend(:claude), do: :anthropic
  defp provider_to_backend(:codex), do: :openai
  defp provider_to_backend(:gemini), do: :google
  defp provider_to_backend(other), do: other

  # -- Crash Recovery --

  defp maybe_reconnect(%{reconnect_attempted: true}), do: :error
  defp maybe_reconnect(%{last_session_id: nil}), do: :error

  defp maybe_reconnect(state) do
    resolved =
      case Keyword.get(state.opts, :client_opts) do
        nil -> Config.resolve(state.provider, state.opts)
        raw -> {:ok, raw}
      end

    case resolved do
      {:ok, client_opts} ->
        client_opts =
          client_opts
          |> Keyword.put(:event_listener, self())
          |> Keyword.put_new(:handler, Arbor.AI.AcpSession.Handler)
          |> Keyword.put_new(:handler_opts,
            session_pid: self(),
            agent_id: Keyword.get(state.opts, :agent_id),
            cwd: Keyword.get(state.opts, :cwd)
          )

        case start_acp_client(client_opts) do
          {:ok, client} ->
            # Try to resume the previous session
            # credo:disable-for-next-line Credo.Check.Refactor.Apply
            case apply(acp_client_module(), :load_session, [
                   client,
                   state.last_session_id,
                   resolve_cwd([], state.opts)
                 ]) do
              {:ok, _session_info} ->
                {:ok,
                 %{
                   state
                   | client: client,
                     session_id: state.last_session_id,
                     status: :ready,
                     reconnect_attempted: true
                 }}

              {:error, _reason} ->
                # Resume failed — kill the new client
                disconnect_client(%{client: client})
                :error
            end

          {:error, _} ->
            :error
        end

      {:error, _} ->
        :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp summarize_result(result) when is_map(result) do
    text = Map.get(result, "text") || Map.get(result, :text, "")
    %{text_length: String.length(to_string(text))}
  end

  defp summarize_result(_), do: %{}

  # Floor for GenServer.call timeouts on create/resume. LLM tool args sometimes
  # pass timeout: 0 or 1 for optional fields; those abort before ACP can respond.
  @min_call_timeout_ms 30_000

  defp timeout(opts) do
    case Keyword.get(opts, :timeout, :infinity) do
      t when is_integer(t) and t >= @min_call_timeout_ms -> t
      t when is_integer(t) and t > 0 -> @min_call_timeout_ms
      :infinity -> :infinity
      _ -> :infinity
    end
  end

  # -- Workspace Lifecycle --

  defp maybe_create_workspace(opts) do
    case Keyword.get(opts, :workspace) do
      {:worktree, wt_opts} ->
        id = System.unique_integer([:positive])
        branch = Keyword.get(wt_opts, :branch, "acp/session-#{id}")
        base = Keyword.get(wt_opts, :base_dir, System.tmp_dir!())
        path = Path.join(base, "acp-worktree-#{id}")

        case System.cmd("git", ["worktree", "add", path, "-b", branch], stderr_to_stdout: true) do
          {_, 0} ->
            {:worktree, path, branch}

          {output, _} ->
            Logger.warning("AcpSession: failed to create worktree: #{String.trim(output)}")
            nil
        end

      {:directory, path} ->
        if File.dir?(path) do
          {:directory, path}
        else
          Logger.warning("AcpSession: workspace directory does not exist: #{path}")
          nil
        end

      nil ->
        nil
    end
  end

  # Lazily establish the ACP session before the first prompt. The pool/adapter
  # path checks a session out and prompts without an explicit create_session, so
  # session_id would be nil and the agent receives "sessionId": null. cwd is
  # derived from the workspace (as in init/1), not state.opts[:cwd], which is
  # absent in the pool flow.
  defp do_send_message(content, opts, from, state) do
    state = %{state | status: :busy, accumulated_text: ""}
    hard_timeout = hard_timeout(opts)
    inactivity_timeout = inactivity_timeout(opts)

    # Monitor the GenServer.call owner for this prompt. When orchestration
    # cancel kills the action/turn process, we abort the ACP prompt immediately
    # instead of waiting for inactivity timeout.
    caller_pid = elem(from, 0)
    caller_ref = Process.monitor(caller_pid)

    prompt =
      start_task_prompt(state, content, opts, hard_timeout, inactivity_timeout)
      |> Map.merge(%{caller_pid: caller_pid, caller_ref: caller_ref, control: nil})

    timers =
      start_prompt_timers(prompt.ref,
        hard_timeout: hard_timeout,
        inactivity_timeout: inactivity_timeout
      )

    await_prompt_result(prompt, timers, state)
  end

  defp start_prompt_worker(client, session_id, content, opts) do
    parent = self()
    ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(parent, {:acp_prompt_result, ref, run_prompt(client, session_id, content, opts)})
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

  defp transition_task_control(state, control_id, status, reason)
       when status in @terminal_task_control_statuses do
    case Map.fetch(state.task_controls, control_id) do
      {:ok, %{status: current_status}}
      when current_status in @terminal_task_control_statuses ->
        state

      {:ok, control} ->
        updated = control |> Map.put(:status, status) |> Map.put(:reason, reason)
        state = %{state | task_controls: Map.put(state.task_controls, control_id, updated)}
        emit_task_control_signal(task_control_event(status), state, updated, reason)
        state

      :error ->
        state
    end
  end

  defp task_control_event(:delivered), do: :acp_task_control_delivered
  defp task_control_event(:not_delivered), do: :acp_task_control_not_delivered
  defp task_control_event(:delivery_unknown), do: :acp_task_control_delivery_unknown
  defp task_control_event(:cancelled), do: :acp_task_control_cancelled

  defp settle_failed_prompt_task_controls(state, prompt, failure) do
    {active_reason, queued_reason} = task_control_failure_reasons(failure)

    state =
      if prompt.control do
        transition_task_control(
          state,
          prompt.control,
          :delivery_unknown,
          active_reason
        )
      else
        state
      end

    settle_task_controls(
      state,
      [:queued],
      :not_delivered,
      queued_reason,
      except: prompt.control
    )
  end

  defp settle_cancelled_prompt_task_controls(state, prompt, cancellation) do
    state =
      if prompt.control do
        transition_task_control(
          state,
          prompt.control,
          :delivery_unknown,
          cancellation_delivery_reason(cancellation)
        )
      else
        state
      end

    settle_task_controls(
      state,
      [:queued, :deferred],
      :cancelled,
      cancellation,
      except: prompt.control
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
        transition_task_control(acc, control_id, status, reason)
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
    :exit, _ -> :ok
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
      {:ok, _result} = ok -> ok
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_prompt_result, other}}
    end
  rescue
    exception ->
      {:error, {:prompt_failed, Exception.message(exception)}}
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, {:prompt_exit, reason}}
    kind, reason -> {:error, {kind, reason}}
  end

  defp await_prompt_result(prompt, timers, state) do
    receive do
      {:acp_prompt_result, ref, {:ok, result}} when ref == prompt.ref ->
        complete_prompt_success(prompt, timers, result, state)

      {:acp_task_control, ref, reply_to, control} when is_reference(ref) and is_pid(reply_to) ->
        {result, new_state} = accept_queued_task_control(control, state)
        send(reply_to, {:acp_task_control_result, ref, result})
        await_prompt_result(prompt, timers, new_state)

      {:acp_prompt_result, ref, {:error, :timeout}} when ref == prompt.ref ->
        timeout_prompt(:timeout, prompt, timers, state)

      {:acp_prompt_result, ref, {:error, reason} = error} when ref == prompt.ref ->
        cleanup_prompt(prompt, timers)

        new_state =
          state
          |> settle_failed_prompt_task_controls(prompt, :provider_error)
          |> Map.put(:status, :error)

        emit_signal(:acp_session_error, new_state, %{error: reason, phase: :prompt})
        {:reply, error, new_state}

      {:DOWN, monitor_ref, :process, _pid, reason} when monitor_ref == prompt.monitor_ref ->
        cleanup_prompt(prompt, timers)

        new_state =
          state
          |> settle_failed_prompt_task_controls(prompt, :prompt_exit)
          |> Map.put(:status, :error)

        emit_signal(:acp_session_error, new_state, %{error: reason, phase: :prompt})
        {:reply, {:error, {:prompt_exit, reason}}, new_state}

      {:DOWN, _ref, :process, pid, reason} when pid == state.client ->
        kill_prompt_worker(prompt)
        cleanup_prompt(prompt, timers)

        new_state =
          state
          |> settle_failed_prompt_task_controls(prompt, :client_lost)
          |> Map.merge(%{status: :error, client: nil})

        emit_signal(:acp_session_error, new_state, %{error: :client_down, reason: reason})
        {:reply, {:error, :client_down}, new_state}

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
        new_state = process_session_update(state, session_id, update)
        timers = maybe_reset_inactivity_timer(timers, prompt.ref, session_id, new_state, update)
        await_prompt_result(prompt, timers, new_state)

      {:acp_prompt_inactivity_timeout, ref, timer_ref}
      when ref == prompt.ref and timer_ref == timers.inactivity_timer ->
        timeout_prompt(:inactivity_timeout, prompt, timers, state)

      {:acp_prompt_inactivity_timeout, ref, _stale_timer_ref} when ref == prompt.ref ->
        await_prompt_result(prompt, timers, state)

      {:acp_prompt_hard_timeout, ref, timer_ref}
      when ref == prompt.ref and timer_ref == timers.hard_timer ->
        timeout_prompt(:timeout, prompt, timers, state)

      {:acp_prompt_hard_timeout, ref, _stale_timer_ref} when ref == prompt.ref ->
        await_prompt_result(prompt, timers, state)

      {:acp_prompt_inactivity_timeout, _stale_ref, _stale_timer_ref} ->
        await_prompt_result(prompt, timers, state)

      {:acp_prompt_hard_timeout, _stale_ref, _stale_timer_ref} ->
        await_prompt_result(prompt, timers, state)
    end
  end

  defp complete_prompt_success(prompt, timers, result, state) do
    cleanup_prompt(prompt, timers, preserve_caller_monitor: true)

    # A few adapters enqueue the final chunks immediately before returning the
    # prompt result. Drain anything already queued before merging text.
    state = state |> drain_pending_updates() |> drain_pending_task_controls()
    result = merge_accumulated_text(result, state.accumulated_text)

    new_state =
      %{state | status: :busy} |> accumulate_usage(result) |> mark_task_control_delivered(prompt)

    maybe_report_usage(new_state, result)
    emit_signal(:acp_session_completed, new_state, %{result: summarize_result(result)})

    case next_queued_task_control(new_state) do
      {:none, new_state} ->
        demonitor_owner(prompt.caller_ref)
        {:reply, {:ok, result}, %{new_state | status: :ready}}

      {{control_id, control}, new_state} ->
        follow_up =
          start_task_prompt(
            new_state,
            control.message,
            prompt.prompt_opts,
            prompt.hard_timeout,
            prompt.inactivity_timeout
          )
          |> Map.merge(%{
            caller_pid: prompt.caller_pid,
            caller_ref: prompt.caller_ref,
            control: control_id
          })

        follow_up_timers =
          start_prompt_timers(follow_up.ref,
            hard_timeout: follow_up.hard_timeout,
            inactivity_timeout: follow_up.inactivity_timeout
          )

        await_prompt_result(follow_up, follow_up_timers, %{new_state | accumulated_text: ""})
    end
  end

  defp timeout_prompt(kind, prompt, timers, state) do
    cancel_acp_prompt(state)
    kill_prompt_worker(prompt)
    cleanup_prompt(prompt, timers)

    new_state =
      case kind do
        cancellation when cancellation in [:caller_cancelled, :owner_cancelled] ->
          settle_cancelled_prompt_task_controls(state, prompt, cancellation)

        failure when failure in [:timeout, :inactivity_timeout] ->
          settle_failed_prompt_task_controls(state, prompt, failure)
      end
      |> Map.put(:status, :error)

    # Inactivity means the ACP agent went silent — could be stuck awaiting a
    # host-side approval, or truly hung. Emit a distinct idle signal before the
    # error/kill so Signal/dashboard subscribers can distinguish "waiting" from
    # hard failure (acp_session_error still fires for the abort itself).
    if kind == :inactivity_timeout do
      emit_signal(:acp_session_idle, new_state, %{
        reason: :inactivity_timeout,
        phase: :prompt
      })
    end

    error = if kind in [:caller_cancelled, :owner_cancelled], do: :cancelled, else: kind
    emit_signal(:acp_session_error, new_state, %{error: error, phase: :prompt})
    {:stop, :normal, {:error, error}, new_state}
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
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(module, :cancel, [client, session_id])
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
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

  defp schedule_timer(:infinity, _message), do: nil

  defp schedule_timer(timeout_ms, {tag, prompt_ref}) when is_integer(timeout_ms) do
    timer_ref = make_ref()
    Process.send_after(self(), {tag, prompt_ref, timer_ref}, timeout_ms)
    timer_ref
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

  defp cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp prompt_client_opts(opts, hard_timeout) do
    opts
    |> Keyword.delete(:inactivity_timeout_ms)
    |> Keyword.put(:timeout, hard_timeout)
  end

  defp hard_timeout(opts) do
    opts
    |> Keyword.get(:timeout, :infinity)
    |> normalize_timeout(:infinity)
  end

  defp inactivity_timeout(opts) do
    opts
    |> Keyword.get(
      :inactivity_timeout_ms,
      Application.get_env(:arbor_ai, :acp_inactivity_timeout_ms, @default_inactivity_timeout_ms)
    )
    |> normalize_timeout(@default_inactivity_timeout_ms)
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
    receive do
      {:acp_session_update, session_id, update} ->
        drain_pending_updates(process_session_update(state, session_id, update))
    after
      0 -> state
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

    new_opts =
      case state.mcp_servers do
        servers when is_list(servers) and servers != [] ->
          Keyword.put_new(opts, :mcp_servers, servers)

        _ ->
          opts
      end

    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(acp_client_module(), :new_session, [state.client, cwd, new_opts]) do
      {:ok, info} ->
        sid = Map.get(info, "sessionId") || Map.get(info, :session_id)
        maybe_select_model(state.client, sid, state.model)
        {:ok, %{state | session_id: sid, last_session_id: sid}}

      {:error, reason} ->
        {:error, reason}
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
    |> Keyword.put_new(:cd, cwd)
    |> put_adapter_cwd(cwd)
  end

  defp put_adapter_cwd(client_opts, cwd) do
    case Keyword.get(client_opts, :adapter_opts) do
      ao when is_list(ao) ->
        Keyword.put(client_opts, :adapter_opts, Keyword.put_new(ao, :cwd, cwd))

      _ ->
        client_opts
    end
  end

  defp maybe_select_model(_client, _sid, model) when model in [nil, ""], do: :ok

  defp maybe_select_model(client, sid, model) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(acp_client_module(), :set_config_option, [client, sid, "model", model])
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp workspace_cwd({:worktree, path, _branch}, _opts), do: path
  defp workspace_cwd({:directory, path}, _opts), do: path
  defp workspace_cwd(_, opts), do: Keyword.get(opts, :cwd)

  # ex_mcp's Protocol.encode_session_{new,load,resume} require a non-nil
  # cwd per ACP spec. Without this fallback an internal callsite that
  # forgets to thread :cwd through (or a fresh session before the workspace
  # is set up) would raise FunctionClauseError at the wire boundary.
  # File.cwd!() — the BEAM process's working directory — is the natural
  # "agent works from where the server runs" default.
  defp resolve_cwd(opts, state_opts) do
    Keyword.get(opts, :cwd) ||
      Keyword.get(state_opts, :cwd) ||
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
    :exit, _ -> :ok
  end

  defp cleanup_workspace(_), do: :ok
end
