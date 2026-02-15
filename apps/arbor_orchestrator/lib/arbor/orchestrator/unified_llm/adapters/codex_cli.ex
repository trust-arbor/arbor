defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.CodexCli do
  @moduledoc """
  Provider adapter that calls the `codex` CLI binary directly via Port.

  Uses one-shot `codex exec` mode with `--json` for structured NDJSON responses.
  Parses the NDJSON event stream to extract agent messages and usage stats.

  Supports:
  - Model selection (gpt5, oss models)
  - System prompts (via prepend to prompt)
  - Working directory
  - Timeout control
  """

  @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

  alias Arbor.Orchestrator.UnifiedLLM.{Request, Response}

  require Logger

  @default_timeout 600_000

  @session_vars_to_clear ~w(
    CLAUDE_CODE_ENTRYPOINT CLAUDE_SESSION_ID CLAUDE_CONFIG_DIR
    CLAUDECODE
    ARBOR_SDLC_SESSION_ID ARBOR_SDLC_ITEM_PATH ARBOR_SESSION_TYPE
  )

  @impl true
  def provider, do: "codex_cli"

  @impl true
  def complete(%Request{} = request, opts \\ []) do
    with {:ok, cmd, args} <- build_command(request, opts),
         {:ok, output} <- execute(cmd, args, opts),
         {:ok, response} <- parse_output(output) do
      {:ok, response}
    end
  end

  @doc "Returns true if the `codex` binary is available in PATH."
  def available? do
    System.find_executable("codex") != nil
  end

  # -- Command Building --

  defp build_command(%Request{} = request, opts) do
    case System.find_executable("codex") do
      nil ->
        {:error, :codex_not_found}

      cmd ->
        args = build_args(request, opts)
        {:ok, cmd, args}
    end
  end

  defp build_args(%Request{} = request, _opts) do
    {system_messages, user_messages} = split_messages(request.messages)
    prompt = extract_prompt(user_messages)
    system_prompt = extract_system_prompt(system_messages)

    # Prepend system prompt to user prompt (codex has no --system-prompt flag)
    full_prompt =
      if system_prompt && system_prompt != "" do
        system_prompt <> "\n\n" <> prompt
      else
        prompt
      end

    args = ["exec"]

    # Model
    model = resolve_model(request.model)
    args = if model, do: args ++ ["-m", model], else: args

    # JSON output + skip git check
    args = args ++ ["--json", "--skip-git-repo-check"]

    # Prompt (positional, must be last)
    args ++ [full_prompt]
  end

  # -- Port Execution --

  defp execute(cmd, args, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    working_dir = Keyword.get(opts, :working_dir)

    shell_cmd = build_shell_command(cmd, args)

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

  # -- Output Parsing (NDJSON) --

  defp parse_output(output) do
    lines =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.starts_with?(&1, "{"))

    events =
      Enum.flat_map(lines, fn line ->
        case Jason.decode(line) do
          {:ok, event} -> [event]
          _ -> []
        end
      end)

    text = extract_agent_text(events)
    usage = extract_usage(events)
    session_id = extract_session_id(events)

    {:ok,
     %Response{
       text: text,
       finish_reason: if(text == "", do: :error, else: :stop),
       content_parts: [],
       usage: usage,
       warnings: [],
       raw: %{"session_id" => session_id}
     }}
  end

  defp extract_agent_text(events) do
    events
    |> Enum.filter(fn event ->
      event["type"] == "item.completed" &&
        get_in(event, ["item", "type"]) == "agent_message"
    end)
    |> Enum.map(fn event -> get_in(event, ["item", "text"]) || "" end)
    |> Enum.join("\n")
  end

  defp extract_usage(events) do
    case Enum.find(events, &(&1["type"] == "turn.completed")) do
      %{"usage" => usage} ->
        %{
          "input_tokens" => usage["input_tokens"] || 0,
          "output_tokens" => usage["output_tokens"] || 0
        }

      _ ->
        %{}
    end
  end

  defp extract_session_id(events) do
    case Enum.find(events, &(&1["type"] == "thread.started")) do
      %{"thread_id" => id} -> id
      _ -> nil
    end
  end

  # -- Message Helpers --

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
      _ -> false
    end)
    |> Enum.map(fn part -> Map.get(part, :text, Map.get(part, "text", "")) end)
    |> Enum.join("\n")
  end

  defp extract_text(_), do: ""

  # Let codex pick its own default model — account-dependent
  defp resolve_model(nil), do: nil
  defp resolve_model("default"), do: nil
  defp resolve_model(model) when is_binary(model), do: model
  defp resolve_model(model) when is_atom(model), do: Atom.to_string(model)

  defp safe_env_charlist do
    cleared = Enum.map(@session_vars_to_clear, &{to_charlist(&1), false})
    [{~c"TERM", ~c"dumb"} | cleared]
  end
end
