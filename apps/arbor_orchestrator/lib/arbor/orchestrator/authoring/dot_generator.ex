defmodule Arbor.Orchestrator.Authoring.DotGenerator do
  @moduledoc """
  LLM interaction for pipeline DOT generation with validate-and-fix loop.

  The core pattern: generate DOT via LLM, parse it, validate it, and if there
  are errors, feed them back to the LLM for correction. Up to 3 fix attempts.

  ## Backend

  The LLM backend is a function `(String.t() -> {:ok, String.t()} | {:error, term()})`.
  This allows plugging in any LLM provider without compile-time dependencies.

  Example using Arbor.AI:

      backend = fn prompt ->
        case Arbor.AI.generate_text(prompt, provider: :anthropic, model: "claude-sonnet-4-5-20250929") do
          {:ok, %{text: text}} -> {:ok, text}
          error -> error
        end
      end

      DotGenerator.generate(conversation, backend)
  """

  alias Arbor.Orchestrator.Authoring.Conversation
  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Validation.Validator

  @pipeline_start_marker "<<PIPELINE_SPEC>>"
  @pipeline_end_marker "<<END_PIPELINE_SPEC>>"
  @max_fix_attempts 3

  @type backend :: (String.t() -> {:ok, String.t()} | {:error, term()})

  @doc """
  Send the conversation to the LLM and parse the response.

  Returns:
  - `{:question, text, conversation}` — LLM is asking a question
  - `{:pipeline, dot_string, conversation}` — LLM produced a pipeline
  - `{:error, reason}` — LLM call failed
  """
  @spec generate(Conversation.t(), backend()) ::
          {:pipeline, String.t(), Conversation.t()}
          | {:question, String.t(), Conversation.t()}
          | {:error, term()}
  def generate(%Conversation{} = conv, backend) when is_function(backend, 1) do
    prompt = Conversation.to_prompt(conv)

    case backend.(prompt) do
      {:ok, response} ->
        conv = Conversation.add_assistant(conv, response)

        case extract_pipeline(response) do
          {:ok, dot_string} ->
            {:pipeline, dot_string, conv}

          :none ->
            {:question, response, conv}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Validate a generated DOT string and auto-fix errors via LLM.

  Parses the DOT, runs validation, and if there are errors, feeds them back
  to the LLM for correction. Repeats up to #{@max_fix_attempts} times.

  Returns:
  - `{:ok, dot_string, graph}` — valid pipeline
  - `{:error, reason}` — failed after max attempts
  """
  @spec validate_and_fix(String.t(), Conversation.t(), backend()) ::
          {:ok, String.t(), Arbor.Orchestrator.Graph.t()} | {:error, term()}
  def validate_and_fix(dot_string, %Conversation{} = conv, backend)
      when is_function(backend, 1) do
    do_validate_and_fix(dot_string, conv, backend, 0)
  end

  @doc """
  Extract a pipeline DOT string from an LLM response.

  Looks for content between <<PIPELINE_SPEC>> and <<END_PIPELINE_SPEC>> markers.
  Also handles markdown code fences as a fallback.
  """
  @spec extract_pipeline(String.t()) :: {:ok, String.t()} | :none
  def extract_pipeline(response) do
    case String.split(response, @pipeline_start_marker, parts: 2) do
      [_, rest] ->
        case String.split(rest, @pipeline_end_marker, parts: 2) do
          [dot_content, _] -> {:ok, String.trim(dot_content)}
          _ -> :none
        end

      _ ->
        # Fallback: try to extract from markdown code fence
        extract_from_code_fence(response)
    end
  end

  # ── Private ──

  defp do_validate_and_fix(_dot_string, _conv, _backend, attempt)
       when attempt >= @max_fix_attempts do
    {:error, "Failed to generate valid pipeline after #{@max_fix_attempts} attempts"}
  end

  defp do_validate_and_fix(dot_string, conv, backend, attempt) do
    case Parser.parse(dot_string) do
      {:ok, graph} ->
        diagnostics = Validator.validate(graph)
        errors = Enum.filter(diagnostics, &(&1.severity == :error))

        if errors == [] do
          {:ok, dot_string, graph}
        else
          error_text =
            errors
            |> Enum.map(fn d -> "- [#{d.rule}] #{d.message}" end)
            |> Enum.join("\n")

          fix_prompt =
            "The generated pipeline has validation errors:\n#{error_text}\n\n" <>
              "Please fix these errors and output the corrected pipeline in a <<PIPELINE_SPEC>> block."

          conv = Conversation.add_user(conv, fix_prompt)

          case generate(conv, backend) do
            {:pipeline, new_dot, new_conv} ->
              do_validate_and_fix(new_dot, new_conv, backend, attempt + 1)

            {:question, _text, _conv} ->
              {:error, "LLM asked a question instead of fixing errors (attempt #{attempt + 1})"}

            {:error, reason} ->
              {:error, reason}
          end
        end

      {:error, parse_error} ->
        fix_prompt =
          "The generated DOT has a parse error: #{parse_error}\n\n" <>
            "Please fix the syntax and output the corrected pipeline in a <<PIPELINE_SPEC>> block."

        conv = Conversation.add_user(conv, fix_prompt)

        case generate(conv, backend) do
          {:pipeline, new_dot, new_conv} ->
            do_validate_and_fix(new_dot, new_conv, backend, attempt + 1)

          {:question, _text, _conv} ->
            {:error,
             "LLM asked a question instead of fixing parse error (attempt #{attempt + 1})"}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp extract_from_code_fence(response) do
    case Regex.run(~r/```(?:dot|graphviz)?\s*\n(.*?)```/s, response) do
      [_, content] ->
        trimmed = String.trim(content)
        if String.starts_with?(trimmed, "digraph"), do: {:ok, trimmed}, else: :none

      _ ->
        :none
    end
  end
end
