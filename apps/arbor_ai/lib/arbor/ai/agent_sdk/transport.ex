defmodule Arbor.AI.AgentSDK.Transport do
  @moduledoc """
  Transport layer for Claude Agent SDK.

  Manages the Claude Code CLI subprocess and provides bidirectional
  communication via stdin/stdout using JSON streaming protocol.

  ## Protocol

  - Input: JSON messages sent via stdin (`--input-format stream-json`)
  - Output: NDJSON events received from stdout (`--output-format stream-json`)

  ## Architecture

  Uses an Elixir Port to spawn and communicate with the CLI process.
  Messages are sent as JSON lines, responses are streamed back as NDJSON events.

  ## Usage

      {:ok, transport} = Transport.start_link(cwd: "/path/to/project")

      # Send a message
      :ok = Transport.send_message(transport, %{type: "user", content: "Hello"})

      # Messages are streamed to the registered receiver
      receive do
        {:claude_message, message} -> handle_message(message)
      end
  """

  use GenServer

  require Logger

  alias Arbor.AI.StreamParser

  @type option ::
          {:cwd, String.t()}
          | {:model, atom() | String.t()}
          | {:system_prompt, String.t()}
          | {:allowed_tools, [String.t()]}
          | {:max_turns, pos_integer()}
          | {:receiver, pid()}

  @type t :: GenServer.server()

  # Default buffer limit (1MB like Python SDK)
  @buffer_limit 1_048_576

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a transport process linked to the caller.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Start a transport process without linking.
  """
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts \\ []) do
    GenServer.start(__MODULE__, opts)
  end

  @doc """
  Send a message to the Claude CLI process.

  The message will be JSON-encoded and written to the process stdin.
  """
  @spec send_message(t(), map()) :: :ok | {:error, term()}
  def send_message(transport, message) when is_map(message) do
    GenServer.call(transport, {:send_message, message})
  end

  @doc """
  Send a user prompt to Claude.

  This is a convenience wrapper that formats the message correctly.
  """
  @spec send_prompt(t(), String.t()) :: :ok | {:error, term()}
  def send_prompt(transport, prompt) when is_binary(prompt) do
    send_message(transport, %{type: "user", content: prompt})
  end

  @doc """
  Send an interrupt/abort signal.
  """
  @spec interrupt(t()) :: :ok
  def interrupt(transport) do
    GenServer.call(transport, :interrupt)
  end

  @doc """
  Close the transport and terminate the CLI process.
  """
  @spec close(t()) :: :ok
  def close(transport) do
    GenServer.call(transport, :close)
  end

  @doc """
  Check if the transport is connected and the CLI process is running.
  """
  @spec connected?(t()) :: boolean()
  def connected?(transport) do
    GenServer.call(transport, :connected?)
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
      connected: false
    }

    # Connect immediately
    case connect(state) do
      {:ok, new_state} ->
        {:ok, new_state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send_message, message}, _from, %{port: port, connected: true} = state) do
    case send_to_port(port, message) do
      :ok -> {:reply, :ok, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:send_message, _message}, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:interrupt, _from, %{port: port} = state) when not is_nil(port) do
    # Send SIGINT equivalent
    Port.command(port, "\x03")
    {:reply, :ok, state}
  end

  def handle_call(:interrupt, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(:close, _from, state) do
    new_state = disconnect(state)
    {:reply, :ok, new_state}
  end

  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    new_state = process_data(state, data)
    {:noreply, new_state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.info("Claude CLI process exited with status #{status}")
    notify_receiver(state.receiver, {:transport_closed, status})
    {:noreply, %{state | port: nil, connected: false}}
  end

  def handle_info({port, :closed}, %{port: port} = state) do
    Logger.info("Claude CLI port closed")
    notify_receiver(state.receiver, {:transport_closed, :normal})
    {:noreply, %{state | port: nil, connected: false}}
  end

  def handle_info(msg, state) do
    Logger.debug("Transport received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    disconnect(state)
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp connect(state) do
    case build_command(state.opts) do
      {:ok, {cmd, args}} ->
        port_opts = [
          :binary,
          :exit_status,
          :use_stdio,
          :stream,
          {:cd, state.cwd},
          {:args, args},
          {:env, build_env()}
        ]

        try do
          port = Port.open({:spawn_executable, cmd}, port_opts)
          Logger.info("Claude CLI transport connected", cmd: cmd, args: args)
          {:ok, %{state | port: port, connected: true}}
        rescue
          error ->
            Logger.error("Failed to spawn Claude CLI: #{inspect(error)}")
            {:error, {:spawn_failed, error}}
        end

      {:error, _} = error ->
        error
    end
  end

  defp disconnect(%{port: nil} = state), do: state

  defp disconnect(%{port: port} = state) do
    Port.close(port)
    %{state | port: nil, connected: false}
  end

  defp build_command(opts) do
    cli_path = Keyword.get(opts, :cli_path) || find_cli()

    case cli_path do
      nil ->
        {:error, :cli_not_found}

      path ->
        args = build_args(opts)
        {:ok, {path, args}}
    end
  end

  defp find_cli do
    # Check common locations
    paths = [
      System.find_executable("claude"),
      Path.expand("~/.claude/local/claude"),
      "/usr/local/bin/claude"
    ]

    Enum.find(paths, &(&1 && File.exists?(&1)))
  end

  defp build_args(opts) do
    args = [
      # Streaming JSON protocol
      "--input-format",
      "stream-json",
      "--output-format",
      "stream-json",
      "--verbose"
    ]

    # Model selection
    args =
      case Keyword.get(opts, :model) do
        nil -> args
        model -> ["--model", to_string(model) | args]
      end

    # System prompt
    args =
      case Keyword.get(opts, :system_prompt) do
        nil -> args
        prompt -> ["--system-prompt", prompt | args]
      end

    # Max turns
    args =
      case Keyword.get(opts, :max_turns) do
        nil -> args
        turns -> ["--max-turns", to_string(turns) | args]
      end

    # Allowed tools
    args =
      case Keyword.get(opts, :allowed_tools) do
        nil ->
          args

        tools when is_list(tools) ->
          Enum.reduce(tools, args, fn tool, acc ->
            ["--allowedTools", tool | acc]
          end)
      end

    # Skip permission prompts for programmatic use
    args = ["--dangerously-skip-permissions" | args]

    args
  end

  defp build_env do
    base_env = System.get_env() |> Map.to_list()

    sdk_env = [
      {"CLAUDE_SDK_VERSION", "arbor-elixir-0.1.0"},
      {"CLAUDE_CODE_ENTRYPOINT", "sdk"}
    ]

    sdk_env ++ base_env
  end

  defp send_to_port(port, message) do
    try do
      json = Jason.encode!(message) <> "\n"
      Port.command(port, json)
      :ok
    rescue
      error ->
        Logger.error("Failed to send message: #{inspect(error)}")
        {:error, {:send_failed, error}}
    end
  end

  defp process_data(state, data) do
    buffer = state.buffer <> data

    # Check buffer limit
    if byte_size(buffer) > @buffer_limit do
      Logger.warning("Transport buffer exceeded limit, truncating")
      notify_receiver(state.receiver, {:transport_error, :buffer_overflow})
      %{state | buffer: ""}
    else
      {messages, remaining_buffer, new_parser_state} = parse_buffer(buffer, state.parser_state)

      # Notify receiver of each message
      Enum.each(messages, fn msg ->
        notify_receiver(state.receiver, {:claude_message, msg})
      end)

      %{state | buffer: remaining_buffer, parser_state: new_parser_state}
    end
  end

  defp parse_buffer(buffer, parser_state) do
    lines = String.split(buffer, "\n")

    # Last element might be incomplete
    {complete_lines, remaining} =
      case List.pop_at(lines, -1) do
        {last, rest} when last == "" -> {rest, ""}
        {last, rest} -> {rest, last}
      end

    # Parse each complete line
    {messages, final_state} =
      Enum.reduce(complete_lines, {[], parser_state}, fn line, {msgs, ps} ->
        case StreamParser.parse_line(line) do
          {:ok, event} ->
            new_ps = StreamParser.process_line(ps, line)

            # Emit certain events immediately
            case event do
              %{"type" => "assistant"} = msg ->
                {[msg | msgs], new_ps}

              %{"type" => "result"} = msg ->
                {[msg | msgs], new_ps}

              %{"type" => "stream_event", "event" => inner} ->
                # For thinking blocks, emit as they come
                case inner do
                  %{"type" => "content_block_stop"} ->
                    result = StreamParser.finalize(new_ps)

                    if result.thinking && result.thinking != [] do
                      {[%{type: :thinking_complete, thinking: result.thinking} | msgs], new_ps}
                    else
                      {msgs, new_ps}
                    end

                  _ ->
                    {msgs, new_ps}
                end

              _ ->
                {msgs, new_ps}
            end

          {:error, _} ->
            # Skip non-JSON lines
            {msgs, ps}
        end
      end)

    {Enum.reverse(messages), remaining, final_state}
  end

  defp notify_receiver(receiver, message) do
    send(receiver, message)
  end
end
