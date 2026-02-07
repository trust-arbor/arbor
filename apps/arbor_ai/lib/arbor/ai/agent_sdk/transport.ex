defmodule Arbor.AI.AgentSDK.Transport do
  @moduledoc """
  Transport layer for Claude Agent SDK.

  Spawns the Claude Code CLI as a subprocess and streams responses.
  Uses `--output-format stream-json --verbose --print` mode for capturing
  thinking blocks and real-time streaming.

  ## Architecture

  Each query spawns a new CLI process with the prompt in the command line.
  Responses are streamed back as NDJSON events and parsed in real-time.

  ## Usage

      # Run a query and stream results
      {:ok, transport} = Transport.start_link(
        prompt: "What is 2+2?",
        receiver: self(),
        model: :opus
      )

      # Receive messages
      receive do
        {:claude_message, %{"type" => "assistant", ...}} -> ...
        {:claude_message, %{"type" => "result", ...}} -> ...
        {:transport_closed, status} -> ...
      end
  """

  use GenServer

  require Logger

  alias Arbor.AI.AgentSDK.Error
  alias Arbor.AI.AgentSDK.Permissions
  alias Arbor.AI.StreamParser

  @type option ::
          {:prompt, String.t()}
          | {:cwd, String.t()}
          | {:model, atom() | String.t()}
          | {:system_prompt, String.t()}
          | {:max_turns, pos_integer()}
          | {:receiver, pid()}
          | {:permission_mode, Permissions.permission_mode()}
          | {:allowed_tools, [String.t() | atom()]}
          | {:disallowed_tools, [String.t() | atom()]}

  @type t :: GenServer.server()

  # Default buffer limit (1MB)
  @buffer_limit 1_048_576

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a transport process linked to the caller.

  Requires `:prompt` option with the query to send.
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
  Check if the transport is connected and the CLI process is running.
  """
  @spec connected?(t()) :: boolean()
  def connected?(transport) do
    GenServer.call(transport, :connected?)
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
    prompt = Keyword.get(opts, :prompt, "")

    if prompt == "" do
      {:stop, Error.prompt_required()}
    else
      state = %{
        port: nil,
        receiver: receiver,
        cwd: cwd,
        opts: opts,
        buffer: "",
        parser_state: StreamParser.new(),
        connected: false
      }

      case connect(state) do
        {:ok, new_state} ->
          {:ok, new_state}

        {:error, reason} ->
          {:stop, reason}
      end
    end
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  def handle_call(:close, _from, state) do
    new_state = disconnect(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info({:cli_output, output}, state) do
    # Process the complete CLI output
    new_state = process_data(state, output)

    # Notify that transport is done
    notify_receiver(state.receiver, {:transport_closed, 0})
    {:noreply, %{new_state | connected: false}}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    new_state = process_data(state, data)
    {:noreply, new_state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.debug("Claude CLI process exited with status #{status}")
    notify_receiver(state.receiver, {:transport_closed, status})
    {:noreply, %{state | port: nil, connected: false}}
  end

  def handle_info({port, :closed}, %{port: port} = state) do
    Logger.debug("Claude CLI port closed")
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
        # Use :os.cmd which works reliably with Claude CLI
        # Run in a separate process to not block the GenServer
        parent = self()

        spawn_link(fn ->
          command = "#{cmd} #{Enum.map(args, &shell_escape/1) |> Enum.join(" ")}"
          Logger.debug("Executing: #{command}")

          output = :os.cmd(String.to_charlist(command))
          output_str = List.to_string(output)

          # Send output to parent for processing
          send(parent, {:cli_output, output_str})
        end)

        {:ok, %{state | connected: true}}

      {:error, _} = error ->
        error
    end
  end

  defp shell_escape(arg) do
    # Simple shell escaping for arguments
    if String.contains?(arg, [" ", "'", "\""]) do
      "\"#{String.replace(arg, "\"", "\\\"")}\""
    else
      arg
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
        {:error, Error.cli_not_found()}

      path ->
        args = build_args(opts)
        {:ok, {path, args}}
    end
  end

  defp find_cli do
    paths = [
      System.find_executable("claude"),
      Path.expand("~/.claude/local/claude"),
      "/usr/local/bin/claude"
    ]

    Enum.find(paths, &(&1 && File.exists?(&1)))
  end

  defp build_args(opts) do
    prompt = Keyword.get(opts, :prompt, "")
    permission_mode = Permissions.resolve_mode(opts)

    # Base args for streaming with thinking
    args = [
      "--output-format",
      "stream-json",
      "--verbose",
      "--print"
    ]

    # Permission mode flags
    args = args ++ Permissions.cli_flags(permission_mode)

    # Tool restriction flags (override permission mode tool flags if present)
    tool_flags = Permissions.tool_restriction_flags(opts)
    args = if tool_flags != [], do: args ++ tool_flags, else: args

    # Model selection
    args =
      case Keyword.get(opts, :model) do
        nil -> args
        model -> args ++ ["--model", to_string(model)]
      end

    # System prompt
    args =
      case Keyword.get(opts, :system_prompt) do
        nil -> args
        sys_prompt -> args ++ ["--system-prompt", sys_prompt]
      end

    # Max turns
    args =
      case Keyword.get(opts, :max_turns) do
        nil -> args
        turns -> args ++ ["--max-turns", to_string(turns)]
      end

    # Add prompt at the end
    args ++ ["-p", prompt]
  end

  defp process_data(state, data) do
    buffer = state.buffer <> data

    if byte_size(buffer) > @buffer_limit do
      Logger.warning("Transport buffer exceeded limit, truncating")
      notify_receiver(state.receiver, {:transport_error, Error.buffer_overflow()})
      %{state | buffer: ""}
    else
      {messages, remaining_buffer, new_parser_state} = parse_buffer(buffer, state.parser_state)

      Enum.each(messages, fn msg ->
        notify_receiver(state.receiver, {:claude_message, msg})
      end)

      %{state | buffer: remaining_buffer, parser_state: new_parser_state}
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

            case event do
              %{"type" => "assistant"} = msg ->
                {[msg | msgs], new_ps}

              %{"type" => "result"} = msg ->
                {[msg | msgs], new_ps}

              %{"type" => "stream_event", "event" => %{"type" => "content_block_stop"}} ->
                result = StreamParser.finalize(new_ps)

                if result.thinking && result.thinking != [] do
                  {[%{type: :thinking_complete, thinking: result.thinking} | msgs], new_ps}
                else
                  {msgs, new_ps}
                end

              _ ->
                {msgs, new_ps}
            end

          {:error, _} ->
            {msgs, ps}
        end
      end)

    {Enum.reverse(messages), remaining, final_state}
  end

  defp notify_receiver(receiver, message) do
    send(receiver, message)
  end
end
