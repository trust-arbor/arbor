defmodule Arbor.AI.Backends.QwenCli do
  @moduledoc """
  Qwen CLI backend for LLM text generation.

  Uses the `qwen` command-line tool for Alibaba's Qwen models.
  Supports JSON output for easy parsing.

  ## Usage

      # Basic generation
      {:ok, response} = QwenCli.generate_text("Hello")

      # Execute a task
      {:ok, response} = QwenCli.generate_text("Explain this code")
  """

  use Arbor.AI.Backends.CliBackend, provider: :qwen

  @default_model "qwen"

  # ============================================================================
  # Callback Implementations
  # ============================================================================

  @impl true
  def build_command(prompt, _opts) do
    # qwen uses: qwen -o json "prompt"
    args = ["-o", "json", prompt]
    {"qwen", args}
  end

  @impl true
  def parse_output(output) do
    # Qwen JSON output is an array of objects, find the "result" type
    # Format: [{"type":"system",...},{"type":"assistant",...},{"type":"result","result":"Hello!","stats":{...}}]
    trimmed = String.trim(output)

    case CliBackend.parse_json_output(trimmed) do
      {:ok, json_array} when is_list(json_array) ->
        parse_json_array(json_array, output)

      {:ok, json} when is_map(json) ->
        parse_json_response(json, output)

      {:error, _} ->
        # Fallback: treat as plain text
        {:ok, CliBackend.build_response(%{text: trimmed}, @provider)}
    end
  end

  @impl true
  def default_model, do: @default_model

  @impl true
  def available_models, do: ["qwen"]

  @impl true
  def supports_json_output?, do: true

  @impl true
  def session_dir, do: nil

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp parse_json_array(json_array, raw) do
    # Find the result object
    result_obj = Enum.find(json_array, fn obj -> obj["type"] == "result" end)

    case result_obj do
      %{"result" => text} = obj ->
        {model, usage} = extract_stats(obj)

        response =
          Response.new(
            text: text || "",
            provider: @provider,
            model: model,
            usage: usage,
            raw_response: raw
          )

        {:ok, response}

      _ ->
        # No result object found, return raw
        {:ok, CliBackend.build_response(%{text: Enum.join(json_array, "\n")}, @provider)}
    end
  end

  defp parse_json_response(json, raw) do
    text = json["result"] || json["response"] || ""

    {model, usage} = extract_stats(json)

    response =
      Response.new(
        text: text,
        provider: @provider,
        model: model,
        usage: usage,
        raw_response: raw
      )

    {:ok, response}
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp extract_stats(%{"stats" => stats}) when is_map(stats) do
    {model, model_stats} =
      case stats["models"] do
        models when is_map(models) ->
          models |> Enum.at(0) || {nil, nil}

        _ ->
          {nil, nil}
      end

    usage =
      case model_stats do
        %{"tokens" => tokens} when is_map(tokens) ->
          %{
            input_tokens: tokens["prompt"] || 0,
            output_tokens: tokens["candidates"] || 0,
            total_tokens: tokens["total"] || 0,
            cached_tokens: tokens["cached"] || 0
          }

        _ ->
          nil
      end

    {model, usage}
  end

  defp extract_stats(%{"usage" => usage}) when is_map(usage) do
    normalized = %{
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0,
      total_tokens: usage["total_tokens"] || 0,
      cached_tokens: usage["cache_read_input_tokens"] || 0
    }

    {nil, normalized}
  end

  defp extract_stats(_), do: {nil, nil}
end
