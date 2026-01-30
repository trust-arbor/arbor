defmodule Arbor.AI.Backends.QwenCli do
  @moduledoc """
  Qwen CLI backend for LLM text generation.

  Uses the `qwen` command-line tool with subscription-based pricing.
  Good for boilerplate generation, structured output, and standalone utilities.

  ## Session Management

  - Continue session: `--continue`
  - Resume specific: `-r <id>`

  ## Output

  Qwen supports JSON output with `-o json`, returning an array with result objects.

  ## Usage

      # Basic generation
      {:ok, response} = QwenCli.generate_text("Generate a utility function")

      # Continue session
      {:ok, response} = QwenCli.generate_text("Add tests", new_session: false)
  """

  use Arbor.AI.Backends.CliBackend, provider: :qwen_cli

  @default_model :qwen_code

  # ============================================================================
  # Callback Implementations
  # ============================================================================

  @impl true
  def build_command(prompt, opts) do
    session_mode = CliBackend.session_mode(nil, opts)
    session_id = Keyword.get(opts, :session_id)

    args = []

    # Session handling
    args =
      case {session_mode, session_id} do
        {:resume, nil} ->
          ["--continue" | args]

        {:resume, id} when is_binary(id) ->
          ["-r", id | args]

        {:new, _} ->
          args
      end

    # Output format - use JSON
    args = args ++ ["-o", "json"]

    # Add the prompt
    args = args ++ [prompt]

    {"qwen", args}
  end

  @impl true
  def parse_output(output) do
    trimmed = String.trim(output)

    case CliBackend.parse_json_output(trimmed) do
      {:ok, json} ->
        parse_json_response(json)

      {:error, _} ->
        clean = CliBackend.strip_ansi(trimmed)
        {:ok, CliBackend.build_response(%{text: clean}, @provider)}
    end
  end

  @impl true
  def default_model, do: @default_model

  @impl true
  def available_models, do: [:qwen_code]

  @impl true
  def supports_json_output?, do: true

  @impl true
  def supports_sessions?, do: true

  @impl true
  def session_dir do
    home = System.get_env("HOME") || "~"
    Path.join([home, ".qwen"])
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Qwen JSON output is an array:
  # [
  #   {"type":"system","session_id":"...","tools":[...],...},
  #   {"type":"assistant","session_id":"...","message":{...}},
  #   {"type":"result","session_id":"...","result":"Hello!","usage":{...},"stats":{...}}
  # ]
  defp parse_json_response(json) when is_list(json) do
    result_obj =
      Enum.find(json, fn obj ->
        is_map(obj) && obj["type"] == "result"
      end)

    case result_obj do
      %{"result" => text} = obj ->
        build_result_response(text, obj, json)

      _ ->
        {:ok, CliBackend.build_response(%{text: ""}, @provider)}
    end
  end

  defp parse_json_response(json) when is_map(json) do
    text = json["result"] || json["response"] || ""

    response =
      Response.new(
        text: text,
        provider: @provider,
        model: json["model"],
        raw_response: json
      )

    {:ok, response}
  end

  defp build_result_response(text, obj, json) do
    usage = extract_usage(obj["usage"], obj["stats"])
    model = extract_model_from_stats(obj["stats"])

    response =
      Response.new(
        text: text || "",
        provider: @provider,
        model: model,
        session_id: obj["session_id"],
        usage: usage,
        timing: %{
          duration_ms: obj["duration_ms"],
          duration_api_ms: obj["duration_api_ms"]
        },
        raw_response: json
      )

    {:ok, response}
  end

  defp extract_usage(u, _stats) when is_map(u) do
    %{
      input_tokens: u["input_tokens"] || 0,
      output_tokens: u["output_tokens"] || 0,
      total_tokens: u["total_tokens"] || 0,
      cache_read_tokens: u["cache_read_input_tokens"] || 0
    }
  end

  defp extract_usage(_, stats), do: extract_usage_from_stats(stats)

  defp extract_model_from_stats(stats) do
    case first_model_entry(stats) do
      {name, _stats} -> name
      nil -> nil
    end
  end

  defp extract_usage_from_stats(stats) do
    case first_model_entry(stats) do
      {_name, model_stats} ->
        tokens = model_stats["tokens"] || %{}

        %{
          input_tokens: tokens["prompt"] || 0,
          output_tokens: tokens["candidates"] || 0,
          total_tokens: tokens["total"] || 0,
          cached_tokens: tokens["cached"] || 0
        }

      nil ->
        nil
    end
  end

  defp first_model_entry(nil), do: nil

  defp first_model_entry(%{"models" => models}) when is_map(models) do
    case Map.to_list(models) do
      [entry | _] -> entry
      [] -> nil
    end
  end

  defp first_model_entry(_), do: nil
end
