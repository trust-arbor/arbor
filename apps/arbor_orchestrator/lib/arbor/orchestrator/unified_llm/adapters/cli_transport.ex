defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.CliTransport do
  @moduledoc """
  Persistent Port GenServer for Claude CLI, communicating over NDJSON (stream-json).

  Replaces the one-shot `Port.open` pattern in `ClaudeCli` with a persistent process
  that maintains a single Claude CLI subprocess per session, enabling:

  - **Lower latency** — no CLI startup overhead per query
  - **Multi-turn conversations** — session continuity via `--resume`
  - **Thinking blocks** — interactive mode produces extended thinking events

  ## State Machine

      :disconnected → :connecting → :ready → :querying → :ready
                                                  ↓
                                             :reconnecting → :ready
                                                  ↓
                                             :disconnected (max retries)

  ## Usage

      {:ok, pid} = CliTransport.start_link(model: "sonnet")

      {:ok, response} = CliTransport.complete(pid, "What is 2+2?", nil, [])

      session = CliTransport.session_id(pid)
      CliTransport.close(pid)
  """

  use GenServer

  require Logger

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.ErrorMapper
  alias Arbor.Orchestrator.UnifiedLLM.ProviderError
  alias Arbor.Orchestrator.UnifiedLLM.Response

  @type t :: GenServer.server()

  @type state_name :: :disconnected | :connecting | :ready | :querying | :reconnecting

  # Default buffer limit (50MB — multi-turn tool use generates large output)
  @buffer_limit 52_428_800

  # Reconnection parameters
  @max_reconnect_attempts 3
  @reconnect_backoffs [1_000, 2_000, 4_000]

  # Default query timeout (10 minutes — LLM calls can be slow)
  @default_timeout 600_000

  # Environment variables to clear for subprocess isolation
  @session_vars_to_clear ~w(
    CLAUDE_CODE_ENTRYPOINT CLAUDE_SESSION_ID CLAUDE_CONFIG_DIR
    CLAUDECODE
    ARBOR_SDLC_SESSION_ID ARBOR_SDLC_ITEM_PATH ARBOR_SESSION_TYPE
  )

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a persistent transport process linked to the caller.

  Opens the Claude CLI eagerly. The process transitions to `:ready` once the
  Port is connected.

  ## Options

  - `:model` — model to use (e.g., `"opus"`, `"sonnet"`, `"haiku"`)
  - `:system_prompt` — system prompt for context
  - `:cwd` — working directory for the CLI
  - `:cli_path` — explicit path to `claude` binary
  - `:max_thinking_tokens` — thinking budget (default: 10_000)
  - `:name` — GenServer name registration
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    gen_opts = if opts[:name], do: [name: opts[:name]], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Send a query and block until the result is ready.

  Returns `{:ok, Response.t()}` on success, or `{:error, term()}` on failure.

  ## Options

  - `:timeout` — max wait time in ms (default: 600_000)
  - `:stream_callback` — optional function receiving stream event maps during
    processing. Events include:
    - `%{type: :thinking, text: "..."}` — thinking block content
    - `%{type: :tool_use, name: "...", input: %{...}}` — tool invocation
    - `%{type: :text_delta, text: "..."}` — response text chunk
  """
  @spec complete(t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def complete(pid, prompt, system_prompt \\ nil, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    # Add buffer for GenServer call overhead
    call_timeout = timeout + 5_000

    GenServer.call(pid, {:complete, prompt, system_prompt, opts}, call_timeout)
  catch
    :exit, {:timeout, _} ->
      {:error, :timeout}

    :exit, reason ->
      {:error, {:transport_exit, reason}}
  end

  @doc """
  Close the Port and stop the GenServer.
  """
  @spec close(t()) :: :ok
  def close(pid) do
    GenServer.call(pid, :close)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Get the current session_id for continuity across restarts.
  """
  @spec session_id(t()) :: String.t() | nil
  def session_id(pid) do
    GenServer.call(pid, :session_id)
  catch
    :exit, _ -> nil
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    state = %{
      port: nil,
      cwd: cwd,
      opts: opts,
      buffer: "",
      status: :disconnected,
      session_id: nil,
      reconnect_attempts: 0,
      pending_caller: nil,
      pending_timeout_ref: nil,
      accumulated_messages: [],
      stream_callback: nil
    }

    case open_port(state) do
      {:ok, new_state} ->
        {:ok, new_state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:complete, prompt, system_prompt, opts}, from, %{status: :ready} = state) do
    message = build_stdin_message(prompt, state.session_id)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    stream_callback = Keyword.get(opts, :stream_callback)

    # Stash system_prompt into opts for potential reconnect
    state = maybe_set_system_prompt(state, system_prompt)

    try do
      Port.command(state.port, message)

      timer_ref = Process.send_after(self(), :query_timeout, timeout)

      new_state = %{
        state
        | status: :querying,
          buffer: "",
          pending_caller: from,
          pending_timeout_ref: timer_ref,
          accumulated_messages: [],
          stream_callback: stream_callback
      }

      {:noreply, new_state}
    catch
      :error, reason ->
        Logger.error("[CliTransport] Port.command failed: #{inspect(reason)}")

        {:reply, {:error, ErrorMapper.from_transport("claude_cli", reason)},
         %{state | status: :disconnected, port: nil}}
    end
  end

  def handle_call({:complete, _prompt, _system_prompt, _opts}, _from, %{status: status} = state) do
    {:reply,
     {:error,
      ProviderError.exception(
        message: "transport not ready (status: #{status})",
        provider: "claude_cli",
        retryable: status == :reconnecting
      )}, state}
  end

  def handle_call(:close, _from, state) do
    new_state = close_port(state)
    {:stop, :normal, :ok, new_state}
  end

  def handle_call(:session_id, _from, state) do
    {:reply, state.session_id, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    new_state = process_data(state, data)
    {:noreply, new_state}
  end

  def handle_info({port, {:exit_status, 0}}, %{port: port} = state) do
    Logger.debug("[CliTransport] CLI exited normally (status 0)")

    state = reply_error_if_pending(state, "CLI exited during query")
    {:noreply, %{state | port: nil, status: :disconnected}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[CliTransport] CLI exited unexpectedly with status #{status}")

    new_state = %{state | port: nil}
    attempt_reconnect(new_state, {:exit_status, status})
  end

  def handle_info({port, :closed}, %{port: port} = state) do
    Logger.debug("[CliTransport] Port closed")

    state = reply_error_if_pending(state, "Port closed during query")
    {:noreply, %{state | port: nil, status: :disconnected}}
  end

  def handle_info(:reconnect, state) do
    case open_port(state) do
      {:ok, new_state} ->
        Logger.info("[CliTransport] Reconnected (attempt #{state.reconnect_attempts})")
        {:noreply, %{new_state | reconnect_attempts: 0}}

      {:error, reason} ->
        Logger.warning(
          "[CliTransport] Reconnect attempt #{state.reconnect_attempts} failed: #{inspect(reason)}"
        )

        attempt_reconnect(state, reason)
    end
  end

  def handle_info(:query_timeout, %{status: :querying} = state) do
    Logger.warning("[CliTransport] Query timed out")
    state = reply_error_if_pending(state, "query timed out")
    {:noreply, %{state | status: :ready}}
  end

  def handle_info(:query_timeout, state) do
    # Timer fired after query already completed — ignore
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("[CliTransport] Unexpected message: #{inspect(msg)}")
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
        {:error, :claude_cli_not_found}

      path ->
        args = build_args(state.opts, state.session_id)

        try do
          port_opts = [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            args: Enum.map(args, &to_charlist/1),
            cd: to_charlist(state.cwd),
            env: safe_env_charlist()
          ]

          port = Port.open({:spawn_executable, to_charlist(path)}, port_opts)

          new_state = %{state | port: port, status: :ready}
          Logger.debug("[CliTransport] Port opened, status: ready")
          {:ok, new_state}
        catch
          :error, reason ->
            {:error, {:port_open_failed, reason}}
        end
    end
  end

  defp close_port(%{port: nil} = state), do: %{state | status: :disconnected}

  defp close_port(%{port: port} = state) do
    try do
      Port.close(port)
    catch
      :error, _ -> :ok
    end

    %{state | port: nil, status: :disconnected}
  end

  defp attempt_reconnect(state, reason) do
    attempt = state.reconnect_attempts + 1

    if attempt > @max_reconnect_attempts do
      Logger.error("[CliTransport] Exhausted #{@max_reconnect_attempts} reconnection attempts")

      state = reply_error_if_pending(state, "reconnection failed after #{attempt - 1} attempts")

      {:noreply, %{state | status: :disconnected, reconnect_attempts: 0}}
    else
      backoff = Enum.at(@reconnect_backoffs, attempt - 1, 4_000)

      Logger.info(
        "[CliTransport] Scheduling reconnect attempt #{attempt} in #{backoff}ms (reason: #{inspect(reason)})"
      )

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
    thinking_budget = Keyword.get(opts, :max_thinking_tokens, 10_000)

    base_args = [
      "--output-format",
      "stream-json",
      "--input-format",
      "stream-json",
      "--include-partial-messages",
      "--verbose",
      "--max-thinking-tokens",
      to_string(thinking_budget),
      "--dangerously-skip-permissions"
    ]

    args =
      base_args
      |> append_optional_flag(opts, :model, "--model")
      |> append_optional_flag(opts, :system_prompt, "--system-prompt")

    # Add --resume for session continuity
    if session_id do
      args ++ ["--resume", session_id]
    else
      args
    end
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
      Logger.warning("[CliTransport] Buffer exceeded #{@buffer_limit} bytes, truncating")

      state = reply_error_if_pending(state, "buffer overflow (#{byte_size(buffer)} bytes)")
      %{state | buffer: ""}
    else
      {messages, remaining_buffer} = parse_buffer(buffer)
      state = %{state | buffer: remaining_buffer}

      Enum.reduce(messages, state, fn msg, acc ->
        handle_parsed_message(acc, msg)
      end)
    end
  end

  defp parse_buffer(buffer) do
    lines = String.split(buffer, "\n")

    {complete_lines, remaining} =
      case List.pop_at(lines, -1) do
        {last, rest} when last == "" -> {rest, ""}
        {last, rest} -> {rest, last}
      end

    messages =
      complete_lines
      |> Enum.map(&try_parse_json/1)
      |> Enum.reject(&is_nil/1)

    {messages, remaining}
  end

  defp try_parse_json(""), do: nil

  defp try_parse_json(line) do
    case Jason.decode(line) do
      {:ok, json} -> json
      {:error, _} -> nil
    end
  end

  # ============================================================================
  # Message Handling
  # ============================================================================

  defp handle_parsed_message(%{status: :querying} = state, %{"type" => "result"} = msg) do
    # Query complete — build response and reply to caller
    session_id = msg["session_id"] || state.session_id
    response = build_response(msg, state.accumulated_messages)

    cancel_timeout(state.pending_timeout_ref)
    GenServer.reply(state.pending_caller, {:ok, response})

    %{
      state
      | status: :ready,
        session_id: session_id,
        pending_caller: nil,
        pending_timeout_ref: nil,
        accumulated_messages: [],
        stream_callback: nil
    }
  end

  defp handle_parsed_message(%{status: :querying} = state, %{"type" => "assistant"} = msg) do
    # Accumulate assistant messages for content extraction
    emit_stream_events(state.stream_callback, msg)
    %{state | accumulated_messages: state.accumulated_messages ++ [msg]}
  end

  defp handle_parsed_message(%{status: :querying} = state, %{"type" => "stream_event"} = msg) do
    # Accumulate stream events for thinking block extraction
    emit_stream_events(state.stream_callback, msg)
    %{state | accumulated_messages: state.accumulated_messages ++ [msg]}
  end

  defp handle_parsed_message(state, %{"type" => "result"} = msg) do
    # Result during init phase — capture session_id, don't forward
    session_id = msg["session_id"] || state.session_id
    Logger.debug("[CliTransport] Init-phase result event (session: #{session_id})")
    %{state | session_id: session_id}
  end

  defp handle_parsed_message(state, _msg) do
    # Other events (system, etc.) — ignore
    state
  end

  # ============================================================================
  # Response Building
  # ============================================================================

  defp build_response(%{"type" => "result"} = result_msg, accumulated_messages) do
    text = result_msg["result"] || ""
    {_model, model_usage} = extract_model_usage(result_msg["modelUsage"])
    top_usage = result_msg["usage"] || %{}

    usage = %{
      "input_tokens" => top_usage["input_tokens"] || model_usage[:input_tokens] || 0,
      "output_tokens" => top_usage["output_tokens"] || model_usage[:output_tokens] || 0
    }

    # Extract thinking blocks from accumulated assistant messages
    thinking_parts = extract_thinking(accumulated_messages)

    content_parts =
      if thinking_parts != [] do
        thinking_parts ++ [%{type: :text, text: text}]
      else
        []
      end

    finish_reason = if result_msg["is_error"], do: :error, else: :stop

    %Response{
      text: text,
      finish_reason: finish_reason,
      content_parts: content_parts,
      usage: usage,
      warnings: [],
      raw: %{
        "session_id" => result_msg["session_id"],
        "duration_ms" => result_msg["duration_ms"],
        "cost_usd" => result_msg["total_cost_usd"]
      }
    }
  end

  defp extract_model_usage(nil), do: {nil, %{}}

  defp extract_model_usage(model_usage) when is_map(model_usage) do
    case Map.to_list(model_usage) do
      [{model_name, stats} | _] ->
        usage = %{
          input_tokens: stats["inputTokens"] || 0,
          output_tokens: stats["outputTokens"] || 0
        }

        {model_name, usage}

      [] ->
        {nil, %{}}
    end
  end

  defp extract_thinking(messages) do
    messages
    |> Enum.filter(fn
      %{"type" => "assistant"} -> true
      _ -> false
    end)
    |> Enum.flat_map(fn msg ->
      content = get_in(msg, ["message", "content"]) || []

      Enum.filter(content, fn
        %{"type" => "thinking"} -> true
        _ -> false
      end)
    end)
    |> Enum.map(fn block ->
      %{type: :thinking, text: block["thinking"] || block["text"] || ""}
    end)
  end

  # ============================================================================
  # Stream Callback Emission
  # ============================================================================

  defp emit_stream_events(nil, _msg), do: :ok

  defp emit_stream_events(callback, %{"type" => "assistant"} = msg) do
    content = get_in(msg, ["message", "content"]) || []

    Enum.each(content, fn
      %{"type" => "thinking", "thinking" => text} ->
        safe_callback(callback, %{type: :thinking, text: text})

      %{"type" => "thinking", "text" => text} ->
        safe_callback(callback, %{type: :thinking, text: text})

      %{"type" => "tool_use", "name" => name, "input" => input} ->
        safe_callback(callback, %{type: :tool_use, name: name, input: input})

      %{"type" => "tool_use", "name" => name} ->
        safe_callback(callback, %{type: :tool_use, name: name, input: %{}})

      %{"type" => "text", "text" => text} ->
        safe_callback(callback, %{type: :text_delta, text: text})

      _ ->
        :ok
    end)
  end

  defp emit_stream_events(callback, %{"type" => "stream_event"} = msg) do
    case msg do
      %{"event" => %{"type" => "content_block_delta", "delta" => delta}} ->
        emit_delta(callback, delta)

      %{"event" => %{"type" => "content_block_start", "content_block" => block}} ->
        emit_content_block(callback, block)

      _ ->
        :ok
    end
  end

  defp emit_stream_events(_callback, _msg), do: :ok

  defp emit_delta(callback, %{"type" => "thinking_delta", "thinking" => text}) do
    safe_callback(callback, %{type: :thinking, text: text})
  end

  defp emit_delta(callback, %{"type" => "text_delta", "text" => text}) do
    safe_callback(callback, %{type: :text_delta, text: text})
  end

  defp emit_delta(callback, %{"type" => "input_json_delta", "partial_json" => _text}) do
    # Tool input being streamed — emit as a heartbeat so callers know work is happening
    safe_callback(callback, %{type: :tool_input_delta})
  end

  defp emit_delta(_callback, _delta), do: :ok

  defp emit_content_block(callback, %{"type" => "tool_use", "name" => name} = block) do
    safe_callback(callback, %{
      type: :tool_use,
      name: name,
      input: block["input"] || %{}
    })
  end

  defp emit_content_block(_callback, _block), do: :ok

  defp safe_callback(callback, event) do
    callback.(event)
  rescue
    e ->
      Logger.debug("[CliTransport] Stream callback error: #{inspect(e)}")
      :ok
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp reply_error_if_pending(%{pending_caller: nil} = state, _reason), do: state

  defp reply_error_if_pending(%{pending_caller: caller} = state, reason) do
    cancel_timeout(state.pending_timeout_ref)

    error =
      ProviderError.exception(
        message: reason,
        provider: "claude_cli",
        retryable: true
      )

    GenServer.reply(caller, {:error, error})

    %{state | pending_caller: nil, pending_timeout_ref: nil, accumulated_messages: []}
  end

  defp cancel_timeout(nil), do: :ok

  defp cancel_timeout(ref) do
    Process.cancel_timer(ref)
    # Flush any already-sent :query_timeout message
    receive do
      :query_timeout -> :ok
    after
      0 -> :ok
    end
  end

  defp maybe_set_system_prompt(state, nil), do: state

  defp maybe_set_system_prompt(state, system_prompt) do
    opts = Keyword.put(state.opts, :system_prompt, system_prompt)
    %{state | opts: opts}
  end

  defp safe_env_charlist do
    cleared = Enum.map(@session_vars_to_clear, &{to_charlist(&1), false})
    [{~c"TERM", ~c"dumb"} | cleared]
  end
end
