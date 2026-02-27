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
    :provider,
    :model,
    :stream_callback,
    :opts,
    status: :starting
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
      resolved =
        case Keyword.get(opts, :client_opts) do
          nil -> Config.resolve(provider, opts)
          raw -> {:ok, raw}
        end

      case resolved do
        {:ok, client_opts} ->
          # Build client options
          client_opts =
            client_opts
            |> Keyword.put(:event_listener, self())
            |> Keyword.put_new(:handler, Arbor.AI.AcpSession.Handler)
            |> Keyword.put_new(:handler_opts,
              session_pid: self(),
              agent_id: Keyword.get(opts, :agent_id),
              cwd: Keyword.get(opts, :cwd)
            )

          case start_acp_client(client_opts) do
            {:ok, client} ->
              state = %__MODULE__{
                client: client,
                provider: provider,
                model: Keyword.get(opts, :model),
                stream_callback: Keyword.get(opts, :stream_callback),
                status: :starting,
                opts: opts
              }

              emit_signal(:acp_session_started, state)
              {:ok, state}

            {:error, reason} ->
              Logger.error("Failed to start ACP client for #{provider}: #{inspect(reason)}")
              {:stop, reason}
          end

        {:error, reason} ->
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
        new_state = %{state | session_id: session_id, status: :ready}
        {:reply, {:ok, session_info}, new_state}

      {:error, reason} = error ->
        Logger.warning("AcpSession create_session failed: #{inspect(reason)}")
        new_state = %{state | status: :error}
        emit_signal(:acp_session_error, new_state, %{error: reason, phase: :create})
        {:reply, error, new_state}
    end
  end

  def handle_call({:send_message, _content, _opts}, _from, %{status: status} = state)
      when status not in [:ready] do
    {:reply, {:error, {:not_ready, status}}, state}
  end

  def handle_call({:send_message, content, opts}, _from, state) do
    state = %{state | status: :busy}

    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(@acp_client, :prompt, [state.client, state.session_id, content, opts]) do
      {:ok, result} ->
        new_state = %{state | status: :ready}
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
      status: state.status
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

    Logger.debug(
      "ACP session #{session_id} update: #{inspect(Map.get(update, "type", "unknown"))}"
    )

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{client: pid} = state) do
    Logger.warning("ACP client process died: #{inspect(reason)}")
    emit_signal(:acp_session_error, state, %{error: :client_down, reason: reason})
    {:noreply, %{state | status: :error, client: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("AcpSession unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    disconnect_client(state)
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

  defp summarize_result(result) when is_map(result) do
    text = Map.get(result, "text") || Map.get(result, :text, "")
    %{text_length: String.length(to_string(text))}
  end

  defp summarize_result(_), do: %{}

  defp timeout(opts) do
    Keyword.get(opts, :timeout, 120_000)
  end
end
