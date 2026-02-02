defmodule Arbor.AI.Backends.OpencodeCli do
  @moduledoc """
  OpenCode CLI backend for LLM text generation.

  Uses the `opencode` command-line tool with FREE Grok Code Fast 1 model.
  This is the "always available" fallback for budget-conscious routing.

  ## Session Management

  - Continue session: `--continue`
  - Specific session: `-s <session_id>`

  ## Models

  Default is `opencode/glm-4.7-free` (free), but other models may be available.

  ## Usage

      # Basic generation (uses free Grok model)
      {:ok, response} = OpencodeCli.generate_text("Fix this typo")

      # Continue previous session
      {:ok, response} = OpencodeCli.generate_text("What else?", new_session: false)
  """

  use Arbor.AI.Backends.CliBackend, provider: :opencode_cli

  @default_model "opencode/glm-4.7-free"

  # ============================================================================
  # Callback Implementations
  # ============================================================================

  @impl true
  def build_command(prompt, opts) do
    model = Keyword.get(opts, :model, @default_model)
    session_mode = CliBackend.session_mode(nil, opts)
    session_id = Keyword.get(opts, :session_id)

    # Base command: opencode run "<prompt>"
    args = ["run", prompt]

    # Model selection
    args = args ++ ["--model", model]

    # JSON output format
    args = args ++ ["--format", "json"]

    # Session handling
    args =
      case {session_mode, session_id} do
        {:resume, nil} ->
          args ++ ["--continue"]

        {:resume, id} when is_binary(id) ->
          args ++ ["-s", id]

        {:new, _} ->
          args
      end

    {"opencode", args}
  end

  @impl true
  def parse_output(output) do
    # OpenCode with --format json outputs NDJSON (newline-delimited JSON)
    # Event types:
    # {"type":"step_start","sessionID":"ses_...","part":{...}}
    # {"type":"text","sessionID":"...","part":{"text":"Hello",...}}
    # {"type":"step_finish","sessionID":"...","part":{"tokens":{input,output,reasoning,cache},"cost":0}}
    trimmed = String.trim(output)
    parse_ndjson_response(trimmed)
  end

  @impl true
  def default_model, do: @default_model

  @impl true
  def available_models, do: ["opencode/glm-4.7-free"]

  @impl true
  def supports_json_output?, do: true

  @impl true
  def supports_sessions?, do: true

  @impl true
  def session_dir do
    home = System.get_env("HOME") || "~"
    Path.join([home, ".opencode"])
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp parse_ndjson_response(output) do
    events = CliBackend.decode_ndjson(output)

    session_id = CliBackend.find_event_value(events, "step_start", "sessionID")

    text =
      CliBackend.collect_event_text(
        events,
        fn
          %{"type" => "text"} -> true
          _ -> false
        end,
        fn %{"part" => %{"text" => t}} -> t end
      )

    usage =
      CliBackend.extract_from_event(events, "step_finish", &extract_usage/1)

    response =
      Response.new(
        text: text,
        provider: @provider,
        model: @default_model,
        session_id: session_id,
        usage: usage,
        raw_response: events
      )

    {:ok, response}
  end

  defp extract_usage(event) do
    tokens = get_in(event, ["part", "tokens"]) || %{}
    base = build_token_usage(tokens)

    case get_in(event, ["part", "cost"]) do
      nil -> base
      cost -> Map.put(base, :cost_usd, cost)
    end
  end

  defp build_token_usage(tokens) do
    cache = tokens["cache"] || %{}
    input = tokens["input"] || 0
    output = tokens["output"] || 0

    %{
      input_tokens: input,
      output_tokens: output,
      reasoning_tokens: tokens["reasoning"] || 0,
      cache_read_tokens: cache["read"] || 0,
      cache_write_tokens: cache["write"] || 0,
      total_tokens: input + output
    }
  end
end
