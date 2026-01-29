defmodule Arbor.AI.Backends.CodexCli do
  @moduledoc """
  Codex CLI backend for LLM text generation (OpenAI).

  Uses the `codex` command-line tool (GPT-5.2) with subscription-based pricing.
  Strong for complex multi-file changes, debugging, and algorithms.

  ## Session Management

  - Resume last session: `resume --last`
  - Specific session: Requires TUI picker (not programmatic)

  ## Models

  - Default: GPT-5.2 (via subscription)
  - OSS option: `gpt-oss-120b-heretic-v2-hi-mlx` (local, slower)

  ## Usage

      # Basic generation
      {:ok, response} = CodexCli.generate_text("Debug this function")

      # Resume last session
      {:ok, response} = CodexCli.generate_text("Continue", new_session: false)

      # Force new session
      {:ok, response} = CodexCli.generate_text("New project", new_session: true)
  """

  use Arbor.AI.Backends.CliBackend, provider: :codex_cli

  @default_model :gpt5
  @oss_model "gpt-oss-120b-heretic-v2-hi-mlx"

  # ============================================================================
  # Callback Implementations
  # ============================================================================

  @impl true
  def build_command(prompt, opts) do
    model = Keyword.get(opts, :model, @default_model)
    session_mode = CliBackend.session_mode(nil, opts)

    use_oss = model == :oss || model == @oss_model

    # Base command structure depends on session mode
    args =
      case session_mode do
        :resume ->
          ["e", "resume", "--last"]

        :new ->
          ["e"]
      end

    args = args ++ ["--skip-git-repo-check"]

    # OSS model requires special flags
    args =
      if use_oss do
        args ++ ["--oss", "--model", @oss_model]
      else
        args
      end

    # JSON output for better parsing
    args = args ++ ["--json"]

    # Add the prompt
    args = args ++ [prompt]

    {"codex", args}
  end

  @impl true
  def parse_output(output) do
    trimmed = String.trim(output)

    # Codex with --json outputs NDJSON (newline-delimited JSON)
    # Each line is a separate JSON object with different event types:
    # {"type":"thread.started","thread_id":"..."}
    # {"type":"turn.started"}
    # {"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"..."}}
    # {"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Hello"}}
    # {"type":"turn.completed","usage":{input_tokens, cached_input_tokens, output_tokens}}
    parse_ndjson_response(trimmed)
  end

  @impl true
  def default_model, do: @default_model

  @impl true
  def available_models, do: [:gpt5, :oss]

  @impl true
  def supports_json_output?, do: true

  @impl true
  def supports_sessions?, do: true

  @impl true
  def session_dir do
    home = System.get_env("HOME") || "~"
    Path.join([home, ".codex"])
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp parse_ndjson_response(output) do
    events = CliBackend.decode_ndjson(output)

    thread_id = CliBackend.find_event_value(events, "thread.started", "thread_id")

    text =
      CliBackend.collect_event_text(
        events,
        fn
          %{"type" => "item.completed", "item" => %{"type" => "agent_message"}} -> true
          _ -> false
        end,
        fn %{"item" => %{"text" => t}} -> t end,
        "\n"
      )

    usage =
      CliBackend.extract_from_event(events, "turn.completed", fn event ->
        u = event["usage"] || %{}

        %{
          input_tokens: u["input_tokens"] || 0,
          output_tokens: u["output_tokens"] || 0,
          cached_input_tokens: u["cached_input_tokens"] || 0,
          total_tokens: (u["input_tokens"] || 0) + (u["output_tokens"] || 0)
        }
      end)

    response =
      Response.new(
        text: text,
        provider: @provider,
        model: @default_model,
        session_id: thread_id,
        usage: usage,
        raw_response: events
      )

    {:ok, response}
  end
end
