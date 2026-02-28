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

  @acp_client ExMCP.ACP.Client

  defstruct [
    :client,
    :session_id,
    :last_session_id,
    :provider,
    :model,
    :stream_callback,
    :opts,
    :workspace,
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

  - `:timeout` — override timeout for this request
  """
  @spec send_message(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_message(session, content, opts \\ []) do
    GenServer.call(session, {:send_message, content, opts}, timeout(opts))
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

          case start_acp_client(client_opts) do
            {:ok, client} ->
              state = %__MODULE__{
                client: client,
                provider: provider,
                model: Keyword.get(opts, :model),
                stream_callback: Keyword.get(opts, :stream_callback),
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
    cwd = Keyword.get(opts, :cwd) || Keyword.get(state.opts, :cwd)

    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(@acp_client, :new_session, [state.client, cwd, opts]) do
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
    cwd = Keyword.get(opts, :cwd) || Keyword.get(state.opts, :cwd)

    result =
      try do
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(@acp_client, :load_session, [state.client, session_id, cwd, opts])
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
    # Reset accumulated text before each prompt — streaming chunks arrive during prompt/4
    state = %{state | status: :busy, accumulated_text: ""}

    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(@acp_client, :prompt, [state.client, state.session_id, content, opts]) do
      {:ok, result} ->
        # Merge streaming text into result if agent didn't include it
        result = merge_accumulated_text(result, state.accumulated_text)
        new_state = %{state | status: :ready} |> accumulate_usage(result)
        maybe_report_usage(new_state, result)
        emit_signal(:acp_session_completed, new_state, %{result: summarize_result(result)})
        {:reply, {:ok, result}, new_state}

      {:error, reason} = error ->
        new_state = %{state | status: :error}
        emit_signal(:acp_session_error, new_state, %{error: reason, phase: :prompt})
        {:reply, error, new_state}
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
    if state.stream_callback do
      try do
        state.stream_callback.(update)
      rescue
        e -> Logger.warning("AcpSession stream_callback error: #{inspect(e)}")
      end
    end

    # Accumulate streaming text chunks (Gemini delivers text via session/update,
    # not in prompt result)
    state = accumulate_text(update, state)

    Logger.debug(
      "ACP session #{session_id} update: #{inspect(Map.get(update, "kind", "unknown"))}"
    )

    {:noreply, state}
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

  defp acp_available? do
    Code.ensure_loaded?(@acp_client)
  end

  defp start_acp_client(opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    result = apply(@acp_client, :start_link, [opts])

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
      apply(@acp_client, :disconnect, [client])
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp emit_signal(event, state, metadata \\ %{}) do
    if Code.ensure_loaded?(Arbor.Signals) do
      signal_data =
        %{
          provider: state.provider,
          session_id: state.session_id,
          model: state.model,
          status: state.status
        }
        |> Map.merge(metadata)

      try do
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(Arbor.Signals, :emit, [{:agent, event}, signal_data])
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  # -- Streaming Text Accumulation --

  defp accumulate_text(%{"kind" => "text", "content" => content}, state)
       when is_binary(content) do
    %{state | accumulated_text: state.accumulated_text <> content}
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

    input = Map.get(usage, "input_tokens") || Map.get(usage, :input_tokens, 0)
    output = Map.get(usage, "output_tokens") || Map.get(usage, :output_tokens, 0)

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
            input_tokens: Map.get(usage, "input_tokens") || Map.get(usage, :input_tokens, 0),
            output_tokens: Map.get(usage, "output_tokens") || Map.get(usage, :output_tokens, 0)
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
            case apply(@acp_client, :load_session, [
                   client,
                   state.last_session_id,
                   Keyword.get(state.opts, :cwd)
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

  defp timeout(opts) do
    Keyword.get(opts, :timeout, 120_000)
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

  defp workspace_cwd({:worktree, path, _branch}, _opts), do: path
  defp workspace_cwd({:directory, path}, _opts), do: path
  defp workspace_cwd(_, opts), do: Keyword.get(opts, :cwd)

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
