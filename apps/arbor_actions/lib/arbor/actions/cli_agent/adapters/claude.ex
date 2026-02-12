defmodule Arbor.Actions.CliAgent.Adapters.Claude do
  @moduledoc """
  Claude Code CLI adapter.

  Handles execution via the `claude` binary with:
  - One-shot mode (`-p` + `--output-format json`)
  - `--max-thinking-tokens` (critical for non-TTY Port execution)
  - `--allowedTools` for capability-scoped permissions (never `--dangerously-skip-permissions`)
  - Session env var clearing to prevent subprocess inheriting parent state
  - Port execution with `</dev/null` to prevent stdin blocking
  """

  alias Arbor.Actions.CliAgent.PermissionMapper

  @session_vars_to_clear ~w(
    CLAUDE_CODE_ENTRYPOINT CLAUDE_SESSION_ID CLAUDE_CONFIG_DIR
    ARBOR_SDLC_SESSION_ID ARBOR_SDLC_ITEM_PATH ARBOR_SESSION_TYPE
  )

  @doc """
  Execute a prompt through Claude CLI.
  """
  @spec execute(map(), map()) :: {:ok, map()} | {:error, term()}
  def execute(params, context) do
    with {:ok, claude_path} <- find_binary(),
         {:ok, tool_flags} <- resolve_tool_flags(params, context),
         args <- build_args(params, tool_flags) do
      case execute_port(claude_path, args, params) do
        {:ok, output} ->
          {:ok, parse_result(output, params)}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  @doc """
  Returns true if the `claude` binary is available in PATH.
  """
  @spec available?() :: boolean()
  def available? do
    System.find_executable("claude") != nil
  end

  @doc """
  Build CLI argument list from params and tool flags.

  Exposed for testing — allows verifying arg construction without executing.
  """
  @spec build_args(map(), [String.t()]) :: [String.t()]
  def build_args(params, tool_flags) do
    args = ["-p", params.prompt, "--output-format", "json"]

    # Thinking tokens (critical for non-TTY Port execution)
    max_thinking = params[:max_thinking_tokens] || 10_000
    args = args ++ ["--max-thinking-tokens", to_string(max_thinking)]

    # Model
    args =
      case params[:model] do
        nil -> args
        model -> ["--model", model | args]
      end

    # System prompt
    args =
      case params[:system_prompt] do
        nil -> args
        "" -> args
        prompt -> ["--system-prompt", prompt | args]
      end

    # Session resumption
    args =
      case params[:session_id] do
        nil -> args
        "" -> args
        id -> ["--resume", id | args]
      end

    # Tool permission flags (from capabilities or explicit override)
    args ++ tool_flags
  end

  @doc """
  Parse JSON output from Claude CLI into a result map.

  Exposed for testing.
  """
  @spec parse_result(String.t(), map()) :: map()
  def parse_result(output, _params) do
    trimmed = String.trim(output)
    json_str = find_json_line(trimmed)

    case Jason.decode(json_str) do
      {:ok, %{"type" => "result"} = json} ->
        parse_json_result(json)

      {:ok, json} when is_map(json) ->
        %{
          text: json["result"] || json["text"] || json["content"] || "",
          session_id: json["session_id"],
          model: nil,
          input_tokens: 0,
          output_tokens: 0,
          cost_usd: nil,
          is_error: false,
          duration_ms: nil,
          duration_api_ms: nil
        }

      {:error, _} ->
        %{
          text: trimmed,
          session_id: nil,
          model: nil,
          input_tokens: 0,
          output_tokens: 0,
          cost_usd: nil,
          is_error: false,
          duration_ms: nil,
          duration_api_ms: nil
        }
    end
  end

  # -- Private --

  defp find_binary do
    case System.find_executable("claude") do
      nil -> {:error, :agent_not_found}
      path -> {:ok, path}
    end
  end

  defp resolve_tool_flags(params, context) do
    cond do
      # Explicit allowlist override
      is_list(params[:allowed_tools]) and params[:allowed_tools] != [] ->
        tools = Enum.join(params.allowed_tools, ",")
        {:ok, ["--allowedTools", tools]}

      # Explicit denylist override
      is_list(params[:disallowed_tools]) and params[:disallowed_tools] != [] ->
        tools = Enum.join(params.disallowed_tools, ",")
        {:ok, ["--disallowedTools", tools]}

      # Derive from agent capabilities
      true ->
        agent_id = context[:agent_id] || params[:agent_id]

        if agent_id do
          PermissionMapper.capabilities_to_tool_flags(agent_id)
        else
          {:ok, []}
        end
    end
  end

  defp execute_port(claude_path, args, params) do
    timeout = params[:timeout] || 300_000
    working_dir = params[:working_dir]

    # Build shell command with </dev/null to prevent stdin blocking
    shell_cmd = build_shell_command(claude_path, args)

    port_opts = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:env, safe_env_charlist()}
    ]

    port_opts =
      if working_dir do
        [{:cd, to_charlist(working_dir)} | port_opts]
      else
        port_opts
      end

    port = Port.open({:spawn, shell_cmd}, port_opts)
    collect_output(port, <<>>, timeout)
  end

  defp build_shell_command(cmd, args) do
    escaped_args = Enum.map(args, &shell_escape/1)
    Enum.join([cmd | escaped_args], " ") <> " </dev/null"
  end

  defp shell_escape(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, acc <> data, timeout)

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, code}} ->
        {:error, {:exit_code, code, acc}}
    after
      timeout ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  defp find_json_line(output) do
    output
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find(output, fn line ->
      trimmed = String.trim(line)
      String.starts_with?(trimmed, "{")
    end)
  end

  defp parse_json_result(%{"type" => "result"} = json) do
    {model_name, model_usage} = extract_model_usage(json["modelUsage"])
    top_usage = json["usage"] || %{}

    %{
      text: json["result"] || "",
      session_id: json["session_id"],
      model: model_name,
      input_tokens: top_usage["input_tokens"] || model_usage[:input_tokens] || 0,
      output_tokens: top_usage["output_tokens"] || model_usage[:output_tokens] || 0,
      cost_usd: json["total_cost_usd"],
      is_error: json["is_error"] || false,
      duration_ms: json["duration_ms"],
      duration_api_ms: json["duration_api_ms"]
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

  defp safe_env_charlist do
    cleared = Enum.map(@session_vars_to_clear, &{to_charlist(&1), false})
    [{~c"TERM", ~c"dumb"} | cleared]
  end

  defp format_error(:agent_not_found), do: "Claude CLI binary not found in PATH"
  defp format_error(:timeout), do: "CLI execution timed out"

  defp format_error({:exit_code, code, output}) do
    "CLI exited with code #{code}: #{String.slice(output, 0, 500)}"
  end

  defp format_error(reason), do: "CLI execution failed: #{inspect(reason)}"
end
