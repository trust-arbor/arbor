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

  defstruct [
    :client,
    :session_id,
    :last_session_id,
    :provider,
    :model,
    :stream_callback,
    :opts,
    :workspace,
    :mcp_servers,
    status: :starting,
    accumulated_text: "",
    context_tokens: 0,
    reconnect_attempted: false,
    usage: %{input_tokens: 0, output_tokens: 0}
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
    provider = Keyword.fetch!(opts, :provider)

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
                stream_callback: Keyword.get(opts, :stream_callback),
                mcp_servers: Keyword.get(opts, :mcp_servers),
                workspace: workspace_result,
                status: :ready,
                opts: opts
              }

              emit_signal(:acp_session_started, state)
              {:ok, state}

            {:error, reason} ->
              cleanup_workspace(workspace_result)
              Logger.error("Failed to start ACP client for #{provider}: #{inspect(reason)}")
              {:stop, reason}
          end

        {:error, reason} ->
          cleanup_workspace(workspace_result)
          Logger.error("Unknown ACP provider: #{inspect(provider)}")
          {:stop, reason}
      end
    else
      Logger.warning("ExMCP.ACP.Client not available — AcpSession will not function")
      {:ok, %__MODULE__{provider: provider, status: :error, opts: opts}}
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

  def handle_call({:send_message, content, opts}, _from, state) do
    case ensure_session(state, opts) do
      {:ok, state} -> do_send_message(content, opts, state)
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

  def handle_call(:close, _from, state) do
    disconnect_client(state)
    emit_signal(:acp_session_closed, state)
    {:stop, :normal, :ok, %{state | status: :closed}}
  end

  @impl true
  def handle_info({:acp_session_update, session_id, update}, state) do
    {:noreply, process_session_update(state, session_id, update)}
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
        {:noreply, %{state | status: :error, client: nil}}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("AcpSession unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
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
  defp do_send_message(content, opts, state) do
    state = %{state | status: :busy, accumulated_text: ""}
    hard_timeout = hard_timeout(opts)
    inactivity_timeout = inactivity_timeout(opts)

    prompt =
      start_prompt_worker(
        state.client,
        state.session_id,
        content,
        prompt_client_opts(opts, hard_timeout)
      )

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

    %{pid: pid, monitor_ref: monitor_ref, ref: ref}
  end

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

      {:acp_prompt_result, ref, {:error, :timeout}} when ref == prompt.ref ->
        timeout_prompt(:timeout, prompt, timers, state)

      {:acp_prompt_result, ref, {:error, reason} = error} when ref == prompt.ref ->
        cleanup_prompt(prompt, timers)
        new_state = %{state | status: :error}
        emit_signal(:acp_session_error, new_state, %{error: reason, phase: :prompt})
        {:reply, error, new_state}

      {:DOWN, monitor_ref, :process, _pid, reason} when monitor_ref == prompt.monitor_ref ->
        cleanup_prompt(prompt, timers)
        new_state = %{state | status: :error}
        emit_signal(:acp_session_error, new_state, %{error: reason, phase: :prompt})
        {:reply, {:error, {:prompt_exit, reason}}, new_state}

      {:DOWN, _ref, :process, pid, reason} when pid == state.client ->
        kill_prompt_worker(prompt)
        cancel_prompt_timers(timers)
        new_state = %{state | status: :error, client: nil}
        emit_signal(:acp_session_error, new_state, %{error: :client_down, reason: reason})
        {:reply, {:error, :client_down}, new_state}

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
    cleanup_prompt(prompt, timers)

    # A few adapters enqueue the final chunks immediately before returning the
    # prompt result. Drain anything already queued before merging text.
    state = drain_pending_updates(state)
    result = merge_accumulated_text(result, state.accumulated_text)
    new_state = %{state | status: :ready} |> accumulate_usage(result)
    maybe_report_usage(new_state, result)
    emit_signal(:acp_session_completed, new_state, %{result: summarize_result(result)})
    {:reply, {:ok, result}, new_state}
  end

  defp timeout_prompt(kind, prompt, timers, state) do
    cancel_acp_prompt(state)
    kill_prompt_worker(prompt)
    cleanup_prompt(prompt, timers)

    new_state = %{state | status: :error}

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

    emit_signal(:acp_session_error, new_state, %{error: kind, phase: :prompt})
    {:stop, :normal, {:error, kind}, new_state}
  end

  defp cleanup_prompt(prompt, timers) do
    Process.demonitor(prompt.monitor_ref, [:flush])
    cancel_prompt_timers(timers)
  end

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
