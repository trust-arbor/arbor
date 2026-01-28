defmodule Arbor.AI.Backends.GeminiCli do
  @moduledoc """
  Gemini CLI backend for LLM text generation.

  Uses the `gemini` command-line tool with subscription-based pricing.
  Gemini automatically selects between models (Pro/Flash) based on task complexity.

  ## Session Management

  Gemini CLI returns session_id in JSON output and supports:
  - Resume last session: `--resume latest`
  - Resume by index: `-r <index>`

  ## Output

  Gemini has excellent JSON output support with detailed stats including:
  - Token counts per model
  - Tool usage statistics
  - File change tracking

  ## Usage

      # Basic generation
      {:ok, response} = GeminiCli.generate_text("Hello")

      # Resume last session
      {:ok, response} = GeminiCli.generate_text("Continue", new_session: false)

      # Force new session
      {:ok, response} = GeminiCli.generate_text("Fresh start", new_session: true)
  """

  use Arbor.AI.Backends.CliBackend, provider: :gemini

  # Gemini auto-selects models, but we track what it uses
  @default_model :auto

  # ============================================================================
  # Callback Implementations
  # ============================================================================

  @impl true
  def build_command(prompt, opts) do
    session_mode = CliBackend.session_mode(nil, opts)
    session_index = Keyword.get(opts, :session_index)
    session_id = Keyword.get(opts, :session_id)

    args = []

    # Session handling
    # Gemini CLI uses --resume latest or -r <index>
    # When we have a session_id from a previous call, use --resume latest
    # to continue that conversation (assuming sequential calls)
    args =
      cond do
        # Explicit index takes priority
        session_mode == :resume and is_integer(session_index) ->
          ["-r", to_string(session_index) | args]

        # If we have a session_id, resume latest (our tracked session)
        session_mode == :resume or session_id != nil ->
          ["--resume", "latest" | args]

        # New session
        true ->
          args
      end

    # Output format - always use JSON
    args = args ++ ["-o", "json"]

    # Add the prompt
    args = args ++ [prompt]

    {"gemini", args}
  end

  @impl true
  def parse_output(output) do
    # Remove "Loaded cached credentials." line if present
    lines =
      output
      |> String.trim()
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, "Loaded cached credentials"))
      |> Enum.join("\n")
      |> String.trim()

    case CliBackend.parse_json_output(lines) do
      {:ok, json} ->
        parse_json_response(json)

      {:error, _} ->
        # Fallback: treat as plain text (strip ANSI codes)
        clean = CliBackend.strip_ansi(lines)
        {:ok, CliBackend.build_response(%{text: clean}, @provider)}
    end
  end

  @impl true
  def default_model, do: @default_model

  @impl true
  # Gemini auto-selects
  def available_models, do: [:auto]

  @impl true
  def supports_json_output?, do: true

  @impl true
  def supports_sessions?, do: true

  @impl true
  def session_dir do
    # Gemini stores sessions in ~/.gemini/
    home = System.get_env("HOME") || "~"
    Path.join([home, ".gemini"])
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp parse_json_response(json) when is_map(json) do
    text = json["response"] || ""
    session_id = json["session_id"]

    # Extract model and usage from stats
    {model, usage, tool_stats} = extract_stats(json["stats"])

    response =
      Response.new(
        text: text,
        provider: @provider,
        model: model,
        session_id: session_id,
        usage: usage,
        tool_stats: tool_stats,
        raw_response: json
      )

    {:ok, response}
  end

  defp extract_stats(nil), do: {nil, nil, nil}

  defp extract_stats(stats) when is_map(stats) do
    # Extract model info - Gemini can use multiple models
    {model, usage} = extract_model_usage(stats["models"])
    tool_stats = extract_tool_stats(stats["tools"])

    {model, usage, tool_stats}
  end

  defp extract_model_usage(nil), do: {nil, nil}

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp extract_model_usage(models) when is_map(models) do
    # Get the primary model (first one, or the one with most tokens)
    case Map.to_list(models) do
      [{model_name, model_stats} | _rest] ->
        tokens = model_stats["tokens"] || %{}

        usage = %{
          input_tokens: tokens["input"] || tokens["prompt"] || 0,
          output_tokens: tokens["candidates"] || 0,
          total_tokens: tokens["total"] || 0,
          cached_tokens: tokens["cached"] || 0,
          thought_tokens: tokens["thoughts"] || 0
        }

        {model_name, usage}

      [] ->
        {nil, nil}
    end
  end

  defp extract_tool_stats(nil), do: nil

  defp extract_tool_stats(tools) when is_map(tools) do
    %{
      total_calls: tools["totalCalls"] || 0,
      total_success: tools["totalSuccess"] || 0,
      total_fail: tools["totalFail"] || 0,
      duration_ms: tools["totalDurationMs"] || 0
    }
  end
end
