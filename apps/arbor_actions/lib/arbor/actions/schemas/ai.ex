defmodule Arbor.Actions.Schemas.AI do
  @moduledoc """
  Zoi schemas for AI action parameter validation.

  These schemas provide runtime validation for action parameters when invoked
  via external APIs (HTTP, JSON).
  """

  @valid_providers ~w(anthropic openai gemini ollama lmstudio opencode openrouter qwen)

  @doc """
  Schema for GenerateText action parameters.

  Fields:
  - `prompt` (required) - Text prompt to send
  - `provider` - Provider name
  - `max_tokens` - Maximum tokens (1-100000, default: 1000)
  - `temperature` - Sampling temperature (0.0-2.0, default: 0.7)
  - `system_prompt` - Optional system prompt
  """
  def generate_text_params do
    Zoi.map(
      %{
        "prompt" => Zoi.string() |> Zoi.min(1),
        "provider" => Zoi.enum(@valid_providers) |> Zoi.optional(),
        "max_tokens" => Zoi.integer() |> Zoi.min(1) |> Zoi.max(100_000) |> Zoi.optional(),
        "temperature" => Zoi.number() |> Zoi.min(0.0) |> Zoi.max(2.0) |> Zoi.optional(),
        "system_prompt" => Zoi.string() |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Schema for AnalyzeCode action parameters.

  Fields:
  - `code` (required) - Code to analyze
  - `question` (required) - Analysis question or task
  - `language` - Programming language hint
  - `provider` - Provider name
  - `max_tokens` - Maximum tokens (1-100000, default: 2000)
  """
  def analyze_code_params do
    Zoi.map(
      %{
        "code" => Zoi.string() |> Zoi.min(1),
        "question" => Zoi.string() |> Zoi.min(1),
        "language" => Zoi.string() |> Zoi.optional(),
        "provider" => Zoi.enum(@valid_providers) |> Zoi.optional(),
        "max_tokens" => Zoi.integer() |> Zoi.min(1) |> Zoi.max(100_000) |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Parse and validate parameters against a schema.

  Returns `{:ok, validated_params}` or `{:error, error_details}`.
  """
  def validate(schema, params) do
    case Zoi.parse(schema, params) do
      {:ok, validated} ->
        {:ok, validated}

      {:error, errors} ->
        {:error, format_errors(errors)}
    end
  end

  defp format_errors(errors) do
    Enum.map(errors, fn error ->
      %{
        field: Enum.join(error.path, "."),
        message: error.message
      }
    end)
  end
end
