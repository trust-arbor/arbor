defmodule Arbor.AI.Backends.OpencodeCli do
  @moduledoc """
  Opencode CLI backend for LLM text generation.

  Uses the `opencode` command-line tool.
  Supports JSON output for easy parsing.

  ## Usage

      # Basic generation
      {:ok, response} = OpencodeCli.generate_text("Hello")

      # Execute a task
      {:ok, response} = OpencodeCli.generate_text("Explain this code")
  """

  use Arbor.AI.Backends.CliBackend, provider: :opencode

  @default_model "opencode"

  # ============================================================================
  # Callback Implementations
  # ============================================================================

  @impl true
  def build_command(prompt, _opts) do
    # opencode uses: opencode run "message" --format json
    args = ["run", prompt, "--format", "json"]
    {"opencode", args}
  end

  @impl true
  def parse_output(output) do
    trimmed = String.trim(output)

    case CliBackend.parse_json_output(trimmed) do
      {:ok, json} ->
        parse_json_response(json, output)

      {:error, _} ->
        # Fallback: treat as plain text
        {:ok, CliBackend.build_response(%{text: trimmed}, @provider)}
    end
  end

  @impl true
  def default_model, do: @default_model

  @impl true
  def available_models, do: ["opencode"]

  @impl true
  def supports_json_output?, do: true

  @impl true
  def session_dir, do: nil

  # ============================================================================
  # Private Functions
  # ============================================================================

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp parse_json_response(json, raw) when is_map(json) do
    text = json["result"] || json["response"] || json["output"] || ""

    usage =
      case json["usage"] do
        usage when is_map(usage) ->
          %{
            input_tokens: usage["input_tokens"] || usage["prompt_tokens"] || 0,
            output_tokens: usage["output_tokens"] || usage["completion_tokens"] || 0,
            total_tokens: usage["total_tokens"] || 0
          }

        _ ->
          nil
      end

    response =
      Response.new(
        text: text,
        provider: @provider,
        model: json["model"],
        usage: usage,
        raw_response: raw
      )

    {:ok, response}
  end
end
