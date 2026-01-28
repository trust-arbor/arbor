defmodule Arbor.AI.Backends.CodexCli do
  @moduledoc """
  Codex CLI backend for LLM text generation (OpenAI).

  Uses the `codex` command-line tool for GPT models.
  This is OpenAI's CLI agent, similar to Claude Code.

  ## Usage

      # Basic generation
      {:ok, response} = CodexCli.generate_text("Hello")

      # Execute a task
      {:ok, response} = CodexCli.generate_text("Explain this code")
  """

  use Arbor.AI.Backends.CliBackend, provider: :openai

  @default_model "gpt-4o"

  # ============================================================================
  # Callback Implementations
  # ============================================================================

  @impl true
  def build_command(prompt, _opts) do
    # codex uses: codex e "message" --skip-git-repo-check
    args = ["e", prompt, "--skip-git-repo-check"]
    {"codex", args}
  end

  @impl true
  def parse_output(output) do
    # Codex outputs a header block with metadata before the response
    # Example:
    # model: gpt-5.2-codex
    # ...
    # tokens used
    # 875
    # Hello there friend
    trimmed = String.trim(output)

    # Extract model from header
    model =
      case Regex.run(~r/^model:\s*(.+)$/m, trimmed) do
        [_, model_name] -> model_name
        _ -> nil
      end

    # Extract token count if available
    usage =
      case Regex.run(~r/tokens used\n(\d+)\n/, trimmed) do
        [_, tokens] ->
          total = String.to_integer(tokens)
          %{input_tokens: 0, output_tokens: total, total_tokens: total}

        _ ->
          nil
      end

    # Extract just the final response after the tokens line
    text =
      case String.split(trimmed, ~r/tokens used\n\d+\n/, parts: :infinity) do
        [_header | [response | _]] -> String.trim(response)
        _ -> trimmed
      end

    response =
      Response.new(
        text: text,
        provider: @provider,
        model: model,
        usage: usage,
        raw_response: output
      )

    {:ok, response}
  end

  @impl true
  def default_model, do: @default_model

  @impl true
  def available_models, do: ["gpt-4o", "gpt-4-turbo", "gpt-4"]

  @impl true
  def supports_json_output?, do: false

  @impl true
  def session_dir, do: nil
end
