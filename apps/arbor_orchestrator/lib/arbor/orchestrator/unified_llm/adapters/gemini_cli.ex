defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.GeminiCli do
  @moduledoc """
  Provider adapter that calls the `gemini` CLI binary directly via Port.

  Uses one-shot mode with `-o json` for a structured JSON response.
  Gemini auto-selects between Pro and Flash models unless explicitly overridden.

  Supports:
  - Model selection (auto by default, explicit via -m)
  - System prompts (via prepend to prompt)
  - Working directory
  - Timeout control
  - Sandbox mode
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

  # Lines from Gemini CLI that aren't JSON output
  @noise_prefixes [
    "Loaded cached credentials",
    "(node:",
    "(Use `node"
  ]

  @impl true
  def provider, do: "gemini_cli"

  @impl true
  def complete(%Request{} = request, opts \\ []) do
    with {:ok, cmd, args} <- build_command(request, opts),
         {:ok, output} <- execute(cmd, args, opts),
         {:ok, response} <- parse_output(output) do
      {:ok, response}
    end
  end

  @doc "Returns true if the `gemini` binary is available in PATH."
  def available? do
    System.find_executable("gemini") != nil
  end

  # -- Command Building --

  defp build_command(%Request{} = request, opts) do
    case System.find_executable("gemini") do
      nil ->
        {:error, :gemini_not_found}

      cmd ->
        args = build_args(request, opts)
        {:ok, cmd, args}
    end
  end

  defp build_args(%Request{} = request, opts) do
    {system_messages, user_messages} = split_messages(request.messages)
    prompt = extract_prompt(user_messages)
    system_prompt = extract_system_prompt(system_messages)

    # Prepend system prompt to user prompt (gemini has no --system-prompt flag)
    full_prompt =
      if system_prompt && system_prompt != "" do
        system_prompt <> "\n\n" <> prompt
      else
        prompt
      end

    args = []

    # Model (optional — Gemini auto-selects by default)
    model = resolve_model(request.model)
    args = if model, do: ["-m", model | args], else: args

    # Sandbox mode
    args =
      if Keyword.get(opts, :sandbox, false) do
        ["-s" | args]
      else
        args
      end

    # JSON output
    args = args ++ ["-o", "json"]

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

  # -- Output Parsing (Single JSON) --

  defp parse_output(output) do
    # Filter noise lines and find JSON
    clean_output = filter_noise(output)
    json_str = find_json_object(clean_output)

    case Jason.decode(json_str) do
      {:ok, json} ->
        parse_json_response(json)

      {:error, _} ->
        # Fallback: treat as plain text
        {:ok, %Response{text: String.trim(clean_output), finish_reason: :stop}}
    end
  end

  defp filter_noise(output) do
    output
    |> String.split("\n")
    |> Enum.reject(fn line ->
      trimmed = String.trim(line)
      Enum.any?(@noise_prefixes, &String.starts_with?(trimmed, &1))
    end)
    |> Enum.join("\n")
  end

  defp find_json_object(output) do
    # Find the JSON object — look for { ... } spanning potentially multiple lines
    trimmed = String.trim(output)

    if String.starts_with?(trimmed, "{") do
      trimmed
    else
      # Search lines for start of JSON
      output
      |> String.split("\n")
      |> Enum.drop_while(fn line -> !String.starts_with?(String.trim(line), "{") end)
      |> Enum.join("\n")
      |> case do
        "" -> output
        json -> json
      end
    end
  end

  defp parse_json_response(json) do
    text = json["response"] || ""
    session_id = json["session_id"]
    usage = extract_usage(json)

    {:ok,
     %Response{
       text: text,
       finish_reason: if(text == "", do: :error, else: :stop),
       content_parts: [],
       usage: usage,
       warnings: [],
       raw: %{
         "session_id" => session_id,
         "stats" => json["stats"]
       }
     }}
  end

  defp extract_usage(%{"stats" => %{"models" => models}}) when is_map(models) do
    # Gemini may use multiple models; sum all usage
    Enum.reduce(models, %{"input_tokens" => 0, "output_tokens" => 0}, fn {_model, stats}, acc ->
      tokens = stats["tokens"] || %{}

      %{
        "input_tokens" => acc["input_tokens"] + (tokens["input"] || 0),
        "output_tokens" => acc["output_tokens"] + (tokens["candidates"] || 0)
      }
    end)
  end

  defp extract_usage(_), do: %{}

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

  defp resolve_model(nil), do: nil
  defp resolve_model("auto"), do: nil
  defp resolve_model(model) when is_binary(model), do: model
  defp resolve_model(model) when is_atom(model), do: Atom.to_string(model)

  defp safe_env_charlist do
    cleared = Enum.map(@session_vars_to_clear, &{to_charlist(&1), false})
    [{~c"TERM", ~c"dumb"} | cleared]
  end
end
