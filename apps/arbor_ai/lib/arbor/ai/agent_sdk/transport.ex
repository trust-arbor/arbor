defmodule Arbor.AI.AgentSDK.Transport do
  @moduledoc """
  Persistent Port transport layer for Claude Agent SDK.

  Opens a single Claude CLI process per Client session and communicates via
  stdin/stdout using NDJSON (stream-json) format. This replaces the one-shot
  `System.cmd` approach, enabling:

  - **Thinking blocks** — interactive mode produces extended thinking events
  - **Multi-turn conversations** — session continuity via `--resume`
  - **Lower latency** — no CLI startup overhead per query

  ## State Machine

      :disconnected → :connecting → :ready → :querying → :ready
                                                ↓
                                           :reconnecting → :ready
                                                ↓
                                           :disconnected (max retries)

  ## Usage

      {:ok, transport} = Transport.start_link(
        receiver: self(),
        model: :opus
      )

      # Wait for {:transport_ready} message
      {:ok, ref} = Transport.send_query(transport, "What is 2+2?")

      # Receive messages tagged with query_ref
      receive do
        {:claude_message, ^ref, %{"type" => "assistant", ...}} -> ...
        {:claude_message, ^ref, %{"type" => "result", ...}} -> ...
        {:transport_error, ^ref, %Error{}} -> ...
      end
  """

  use GenServer

  require Logger

  alias Arbor.AI.AgentSDK.Error
  alias Arbor.AI.AgentSDK.Permissions
  alias Arbor.AI.StreamParser

  @type option ::
          {:cwd, String.t()}
          | {:model, atom() | String.t()}
          | {:system_prompt, String.t()}
          | {:max_turns, pos_integer()}
          | {:receiver, pid()}
          | {:permission_mode, Permissions.permission_mode()}
          | {:allowed_tools, [String.t() | atom()]}
          | {:disallowed_tools, [String.t() | atom()]}

  @type t :: GenServer.server()
  @type query_ref :: reference()

  @type state :: :disconnected | :connecting | :ready | :querying | :reconnecting

  # Default buffer limit (50MB — multi-turn tool use generates large output)
  @buffer_limit 52_428_800

  # Reconnection parameters
  @max_reconnect_attempts 3
  @reconnect_backoffs [1_000, 2_000, 4_000]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a persistent transport process linked to the caller.

  Opens the Claude CLI eagerly. The receiver will get `{:transport_ready}`
  when the Port is connected and ready for queries.

  ## Options

  - `:receiver` — PID to receive messages (default: caller)
  - `:cwd` — working directory for the CLI
  - `:model` — model to use (`:opus`, `:sonnet`, `:haiku`)
  - `:system_prompt` — system prompt for context
  - `:permission_mode` — permission mode for tool use
  - `:allowed_tools` / `:disallowed_tools` — tool restrictions
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Send a query to the CLI via stdin.

  Returns `{:ok, query_ref}` if the transport is ready, or
  `{:error, %Error{type: :not_ready}}` if not yet connected.

  The receiver will get messages tagged with the returned `query_ref`.
  """
  @spec send_query(t(), String.t(), keyword()) :: {:ok, query_ref()} | {:error, Error.t()}
  def send_query(transport, prompt, opts \\ []) do
    GenServer.call(transport, {:send_query, prompt, opts})
  end

  @doc """
  Check if the transport is connected and ready for queries.
  """
  @spec ready?(t()) :: boolean()
  def ready?(transport) do
    GenServer.call(transport, :ready?)
  end

  @doc """
  Close the transport and terminate the CLI process.
  """
  @spec close(t()) :: :ok
  def close(transport) do
    GenServer.call(transport, :close)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    receiver = Keyword.get(opts, :receiver, self())
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    state = %{
      port: nil,
      receiver: receiver,
      cwd: cwd,
      opts: opts,
      buffer: "",
      parser_state: StreamParser.new(),
      status: :disconnected,
      session_id: nil,
      query_ref: nil,
      reconnect_attempts: 0
    }

    # Connect eagerly
    case open_port(state) do
      {:ok, new_state} ->
        {:ok, new_state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send_query, prompt, _opts}, _from, %{status: :ready} = state) do
    ref = make_ref()
    message = build_stdin_message(prompt, state.session_id)

    try do
      Port.command(state.port, message)

      new_state = %{
        state
        | status: :querying,
          query_ref: ref,
          buffer: "",
          parser_state: StreamParser.reset(state.parser_state)
      }

      {:reply, {:ok, ref}, new_state}
    catch
      :error, reason ->
        Logger.error("Failed to send query via Port.command: #{inspect(reason)}")

        {:reply, {:error, Error.port_crashed(reason)},
         %{state | status: :disconnected, port: nil}}
    end
  end

  def handle_call({:send_query, _prompt, _opts}, _from, state) do
    {:reply, {:error, Error.not_ready()}, state}
  end

  def handle_call(:ready?, _from, state) do
    {:reply, state.status == :ready, state}
  end

  def handle_call(:close, _from, state) do
    new_state = close_port(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    new_state = process_data(state, data)
    {:noreply, new_state}
  end

  def handle_info({port, {:exit_status, 0}}, %{port: port} = state) do
    Logger.debug("Claude CLI exited normally (status 0)")
    notify_receiver(state.receiver, {:transport_closed, :normal})

    # Reply error to pending query if any
    if state.query_ref do
      notify_receiver(
        state.receiver,
        {:transport_error, state.query_ref, Error.process_error(0, "CLI exited during query")}
      )
    end

    {:noreply, %{state | port: nil, status: :disconnected, query_ref: nil}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("Claude CLI exited unexpectedly with status #{status}")

    # Attempt reconnection
    new_state = %{state | port: nil}
    attempt_reconnect(new_state, status)
  end

  def handle_info({port, :closed}, %{port: port} = state) do
    Logger.debug("Claude CLI port closed")
    notify_receiver(state.receiver, {:transport_closed, :normal})
    {:noreply, %{state | port: nil, status: :disconnected, query_ref: nil}}
  end

  def handle_info(:reconnect, state) do
    case open_port(state) do
      {:ok, new_state} ->
        Logger.info("Reconnected to Claude CLI (attempt #{state.reconnect_attempts})")
        {:noreply, %{new_state | reconnect_attempts: 0}}

      {:error, reason} ->
        Logger.warning("Reconnect attempt #{state.reconnect_attempts} failed: #{inspect(reason)}")
        attempt_reconnect(state, reason)
    end
  end

  def handle_info(msg, state) do
    Logger.debug("Transport received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    close_port(state)
    :ok
  end

  # ============================================================================
  # Port Management
  # ============================================================================

  defp open_port(state) do
    cli_path = Keyword.get(state.opts, :cli_path) || find_cli()

    case cli_path do
      nil ->
        {:error, Error.cli_not_found()}

      path ->
        args = build_args(state.opts, state.session_id)

        try do
          port_opts = [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            args: Enum.map(args, &to_charlist/1),
            cd: to_charlist(state.cwd)
          ]

          port = Port.open({:spawn_executable, to_charlist(path)}, port_opts)

          new_state = %{state | port: port, status: :ready}
          notify_receiver(state.receiver, {:transport_ready})
          {:ok, new_state}
        catch
          :error, reason ->
            {:error, Error.port_crashed(reason)}
        end
    end
  end

  defp close_port(%{port: nil} = state), do: %{state | status: :disconnected}

  defp close_port(%{port: port} = state) do
    catch_port_close(port)
    %{state | port: nil, status: :disconnected}
  end

  defp catch_port_close(port) do
    Port.close(port)
  catch
    :error, _ -> :ok
  end

  defp attempt_reconnect(state, reason) do
    attempt = state.reconnect_attempts + 1

    if attempt > @max_reconnect_attempts do
      Logger.error("Exhausted #{@max_reconnect_attempts} reconnection attempts")

      # Error pending query
      if state.query_ref do
        notify_receiver(
          state.receiver,
          {:transport_error, state.query_ref, Error.reconnect_failed(attempt - 1)}
        )
      end

      notify_receiver(state.receiver, {:transport_closed, {:reconnect_failed, reason}})
      {:noreply, %{state | status: :disconnected, query_ref: nil, reconnect_attempts: 0}}
    else
      backoff = Enum.at(@reconnect_backoffs, attempt - 1, 4_000)
      Logger.info("Scheduling reconnect attempt #{attempt} in #{backoff}ms")
      Process.send_after(self(), :reconnect, backoff)
      {:noreply, %{state | status: :reconnecting, reconnect_attempts: attempt}}
    end
  end

  # ============================================================================
  # Stdin Message Construction
  # ============================================================================

  defp build_stdin_message(prompt, session_id) do
    message = %{
      "type" => "user",
      "message" => %{"role" => "user", "content" => prompt},
      "session_id" => session_id || "default"
    }

    Jason.encode!(message) <> "\n"
  end

  # ============================================================================
  # CLI Command Building
  # ============================================================================

  defp find_cli do
    paths = [
      System.find_executable("claude"),
      Path.expand("~/.claude/local/claude"),
      "/usr/local/bin/claude"
    ]

    Enum.find(paths, &(&1 && File.exists?(&1)))
  end

  defp build_args(opts, session_id) do
    permission_mode = Permissions.resolve_mode(opts)

    # Interactive mode (no -p/--print) with stream-json input and output.
    # --input-format stream-json: accepts NDJSON messages on stdin
    # --output-format stream-json: produces NDJSON events on stdout
    # --include-partial-messages: content_block_start/delta/stop events
    # --verbose: system events and richer output
    base_args = [
      "--output-format",
      "stream-json",
      "--input-format",
      "stream-json",
      "--include-partial-messages",
      "--verbose"
    ]

    # Default thinking budget for the subprocess. The CLI's non-interactive mode
    # defaults maxThinkingTokens to 0 (disabled) unless --max-thinking-tokens is
    # explicitly passed. Without this, the subprocess never produces thinking blocks.
    thinking_budget = Keyword.get(opts, :max_thinking_tokens, 10_000)

    args =
      base_args
      |> append_permission_flags(permission_mode, opts)
      |> append_optional_flag(opts, :model, "--model")
      |> append_optional_flag(opts, :system_prompt, "--system-prompt")
      |> append_optional_flag(opts, :max_turns, "--max-turns")
      |> Kernel.++(["--max-thinking-tokens", to_string(thinking_budget)])

    # Add --resume for session continuity on reconnect
    if session_id do
      args ++ ["--resume", session_id]
    else
      args
    end
  end

  defp append_permission_flags(args, permission_mode, opts) do
    args = args ++ Permissions.cli_flags(permission_mode)
    tool_flags = Permissions.tool_restriction_flags(opts)
    if tool_flags != [], do: args ++ tool_flags, else: args
  end

  defp append_optional_flag(args, opts, key, flag) do
    case Keyword.get(opts, key) do
      nil -> args
      value -> args ++ [flag, to_string(value)]
    end
  end

  # ============================================================================
  # Data Processing
  # ============================================================================

  defp process_data(state, data) do
    buffer = state.buffer <> data

    if byte_size(buffer) > @buffer_limit do
      Logger.warning("Transport buffer exceeded limit, truncating")

      notify_receiver(
        state.receiver,
        {:transport_error, state.query_ref, Error.buffer_overflow()}
      )

      %{state | buffer: ""}
    else
      {messages, remaining_buffer, new_parser_state} = parse_buffer(buffer, state.parser_state)

      state = %{state | buffer: remaining_buffer, parser_state: new_parser_state}

      Enum.reduce(messages, state, fn msg, acc ->
        dispatch_message(acc, msg)
      end)
    end
  end

  defp parse_buffer(buffer, parser_state) do
    lines = String.split(buffer, "\n")

    {complete_lines, remaining} =
      case List.pop_at(lines, -1) do
        {last, rest} when last == "" -> {rest, ""}
        {last, rest} -> {rest, last}
      end

    {messages, final_state} =
      Enum.reduce(complete_lines, {[], parser_state}, fn line, {msgs, ps} ->
        case StreamParser.parse_line(line) do
          {:ok, event} ->
            new_ps = StreamParser.process_line(ps, line)
            process_parsed_event(event, msgs, new_ps)

          {:error, _} ->
            {msgs, ps}
        end
      end)

    {Enum.reverse(messages), remaining, final_state}
  end

  defp process_parsed_event(%{"type" => "assistant"} = msg, msgs, ps) do
    content = get_in(msg, ["message", "content"]) || []
    thinking_count = Enum.count(content, fn b -> b["type"] == "thinking" end)

    Logger.debug(
      "[Transport] assistant message: #{length(content)} content blocks, #{thinking_count} thinking"
    )

    {[msg | msgs], ps}
  end

  defp process_parsed_event(%{"type" => "result"} = msg, msgs, ps) do
    {[msg | msgs], ps}
  end

  defp process_parsed_event(
         %{"type" => "stream_event", "event" => %{"type" => "content_block_stop"}},
         msgs,
         ps
       ) do
    result = StreamParser.finalize(ps)
    maybe_emit_thinking(result, msgs, ps)
  end

  defp process_parsed_event(_event, msgs, ps), do: {msgs, ps}

  defp maybe_emit_thinking(%{thinking: thinking}, msgs, ps)
       when is_list(thinking) and thinking != [] do
    Logger.debug("[Transport] content_block_stop: found #{length(thinking)} thinking blocks")
    {[%{type: :thinking_complete, thinking: thinking} | msgs], ps}
  end

  defp maybe_emit_thinking(_result, msgs, ps), do: {msgs, ps}

  # ============================================================================
  # Message Dispatch
  # ============================================================================

  defp dispatch_message(%{status: :querying, query_ref: ref} = state, %{"type" => "result"} = msg)
       when ref != nil do
    # Capture session_id for reconnection
    session_id = msg["session_id"] || state.session_id

    # Send the result message tagged with query_ref
    notify_receiver(state.receiver, {:claude_message, ref, msg})

    # Query complete — transition back to ready
    %{state | status: :ready, query_ref: nil, session_id: session_id}
  end

  defp dispatch_message(state, %{"type" => "result"} = msg) do
    # Result event received outside of active query (e.g., during CLI init).
    # Capture session_id but don't change status or notify receiver.
    session_id = msg["session_id"] || state.session_id

    Logger.debug(
      "[Transport] Ignoring result event outside active query (status: #{state.status})"
    )

    %{state | session_id: session_id}
  end

  defp dispatch_message(%{status: :querying} = state, msg) do
    notify_receiver(state.receiver, {:claude_message, state.query_ref, msg})
    state
  end

  defp dispatch_message(state, msg) do
    # Messages outside of active query (init phase) — log but don't forward
    Logger.debug("[Transport] Ignoring message outside active query: #{msg["type"]}")
    state
  end

  defp notify_receiver(receiver, message) do
    send(receiver, message)
  end
end
