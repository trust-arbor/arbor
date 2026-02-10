defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.ClaudeCli do
  @moduledoc """
  Provider adapter that calls the `claude` CLI binary directly via Port.

  This adapter enables the orchestrator to use Claude without the full Arbor
  umbrella running — just needs the `claude` binary in PATH. Uses one-shot
  mode with `--output-format json` for structured responses.

  Supports:
  - Model selection (opus, sonnet, haiku)
  - Session resumption (multi-turn via `--resume`)
  - System prompts
  - Working directory (hands-like worktree execution)
  - Timeout control
  """

  @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

  alias Arbor.Orchestrator.UnifiedLLM.{Request, Response}

  require Logger

  @default_timeout 300_000
  @default_model "sonnet"

  @session_vars_to_clear ~w(
    CLAUDE_CODE_ENTRYPOINT CLAUDE_SESSION_ID CLAUDE_CONFIG_DIR
    ARBOR_SDLC_SESSION_ID ARBOR_SDLC_ITEM_PATH ARBOR_SESSION_TYPE
  )

  @impl true
  def provider, do: "claude_cli"

  @impl true
  def complete(%Request{} = request, opts \\ []) do
    with {:ok, cmd, args} <- build_command(request, opts),
         {:ok, output} <- execute(cmd, args, opts),
         {:ok, response} <- parse_output(output) do
      {:ok, response}
    end
  end

  @doc "Returns true if the `claude` binary is available in PATH."
  def available? do
    System.find_executable("claude") != nil
  end

  # -- Command Building --

  defp build_command(%Request{} = request, opts) do
    case System.find_executable("claude") do
      nil ->
        {:error, :claude_not_found}

      cmd ->
        args = build_args(request, opts)
        {:ok, cmd, args}
    end
  end

  defp build_args(%Request{} = request, opts) do
    {system_messages, user_messages} = split_messages(request.messages)
    prompt = extract_prompt(user_messages)
    system_prompt = extract_system_prompt(system_messages)

    args = []

    # Model
    model = resolve_model(request.model)
    args = if model != @default_model, do: ["--model", model | args], else: args

    # System prompt
    args =
      if system_prompt && system_prompt != "" do
        ["--system-prompt", system_prompt | args]
      else
        args
      end

    # Max tokens
    args =
      if request.max_tokens do
        ["--max-tokens", to_string(request.max_tokens) | args]
      else
        args
      end

    # Session resumption
    session_id = Keyword.get(opts, :session_id)

    args =
      cond do
        is_binary(session_id) and session_id != "" ->
          ["--resume", session_id | args]

        Keyword.get(opts, :continue_session, false) ->
          ["-c" | args]

        true ->
          args
      end

    # Output format + permissions
    args = args ++ ["--output-format", "json", "--dangerously-skip-permissions"]

    # Prompt (must be last)
    args = args ++ ["-p", prompt]

    args
  end

  # -- Port Execution --

  defp execute(cmd, args, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    working_dir = Keyword.get(opts, :working_dir)

    port_opts =
      [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, args},
        {:env, safe_env_charlist()}
      ]

    port_opts =
      if working_dir do
        [{:cd, to_charlist(working_dir)} | port_opts]
      else
        port_opts
      end

    port = Port.open({:spawn_executable, to_charlist(cmd)}, port_opts)
    collect_output(port, <<>>, timeout)
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

  # -- Output Parsing --

  defp parse_output(output) do
    trimmed = String.trim(output)

    # Claude may output multiple lines; find the JSON result line
    json_str = find_json_line(trimmed)

    case Jason.decode(json_str) do
      {:ok, json} ->
        parse_json_response(json)

      {:error, _} ->
        # Fallback: treat as plain text
        {:ok, %Response{text: trimmed, finish_reason: :stop}}
    end
  end

  defp find_json_line(output) do
    # Claude --output-format json typically outputs a single JSON object.
    # If there's extra output before it, find the last line starting with {
    output
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find(output, fn line ->
      trimmed = String.trim(line)
      String.starts_with?(trimmed, "{")
    end)
  end

  defp parse_json_response(%{"type" => "result"} = json) do
    text = json["result"] || ""
    session_id = json["session_id"]
    {_model, model_usage} = extract_model_usage(json["modelUsage"])
    top_usage = json["usage"] || %{}

    usage = %{
      "input_tokens" => top_usage["input_tokens"] || model_usage[:input_tokens] || 0,
      "output_tokens" => top_usage["output_tokens"] || model_usage[:output_tokens] || 0
    }

    response = %Response{
      text: text,
      finish_reason: if(json["is_error"], do: :error, else: :stop),
      content_parts: [],
      usage: usage,
      warnings: [],
      raw: %{
        "session_id" => session_id,
        "duration_ms" => json["duration_ms"],
        "cost_usd" => json["total_cost_usd"]
      }
    }

    {:ok, response}
  end

  defp parse_json_response(json) when is_map(json) do
    # Unknown JSON structure — extract what we can
    text = json["result"] || json["text"] || json["content"] || ""
    {:ok, %Response{text: text, finish_reason: :stop}}
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

  # -- Message Helpers (reused from Arborcli adapter pattern) --

  defp split_messages(messages) do
    Enum.split_with(messages, fn msg ->
      msg.role in [:system, :developer]
    end)
  end

  defp extract_prompt(user_messages) do
    user_messages
    |> Enum.filter(fn msg -> msg.role == :user end)
    |> List.last()
    |> case do
      nil -> ""
      msg -> extract_text(msg.content)
    end
  end

  defp extract_system_prompt(system_messages) do
    system_messages
    |> Enum.map(fn msg -> extract_text(msg.content) end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp extract_text(content) when is_binary(content), do: content

  defp extract_text(parts) when is_list(parts) do
    parts
    |> Enum.filter(fn
      %{type: :text} -> true
      %{type: "text"} -> true
      %{kind: :text} -> true
      _ -> false
    end)
    |> Enum.map(fn part ->
      Map.get(part, :text, Map.get(part, "text", ""))
    end)
    |> Enum.join("\n")
  end

  defp extract_text(_), do: ""

  defp resolve_model(nil), do: @default_model
  defp resolve_model("opus"), do: "opus"
  defp resolve_model("sonnet"), do: "sonnet"
  defp resolve_model("haiku"), do: "haiku"
  defp resolve_model("claude-opus-4-5" <> _), do: "opus"
  defp resolve_model("claude-sonnet-4" <> _), do: "sonnet"
  defp resolve_model("claude-haiku" <> _), do: "haiku"
  defp resolve_model(model) when is_binary(model), do: model
  defp resolve_model(model) when is_atom(model), do: Atom.to_string(model)

  # Build a safe environment for CLI subprocesses.
  # Port.open's :env option requires charlists.
  defp safe_env_charlist do
    cleared = Enum.map(@session_vars_to_clear, &{to_charlist(&1), false})
    [{~c"TERM", ~c"dumb"} | cleared]
  end
end
