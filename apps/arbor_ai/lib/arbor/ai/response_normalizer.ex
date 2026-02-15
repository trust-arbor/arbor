defmodule Arbor.AI.ResponseNormalizer do
  @moduledoc """
  Normalizes LLM responses from various providers into a consistent format.

  Extracted from `Arbor.AI` — handles response normalization, text extraction,
  usage parsing, and thinking block extraction for all supported providers.
  """

  alias Arbor.AI.Response

  @doc """
  Normalize a CLI response to contract format.
  """
  def normalize_response(%Response{} = response) do
    %{
      text: response.text || "",
      thinking: response.thinking,
      usage: response.usage || %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      model: response.model,
      provider: response.provider
    }
  end

  def normalize_response(response) when is_map(response) do
    %{
      text: response[:text] || response["text"] || "",
      thinking: response[:thinking] || response["thinking"],
      usage: response[:usage] || response["usage"] || %{},
      model: response[:model] || response["model"],
      provider: response[:provider] || response["provider"]
    }
  end

  @doc """
  Format an API response into the standard response map.
  """
  def format_api_response(response, provider, model) do
    %{
      text: extract_text(response),
      thinking: extract_thinking(response),
      usage: extract_usage(response),
      model: model,
      provider: provider
    }
  end

  @doc """
  Format a tool-calling response into the standard response map.
  """
  def format_tools_response(result, provider, model) do
    %{
      text: result[:text] || "",
      thinking: nil,
      usage: result[:usage] || %{},
      model: model,
      provider: provider,
      tool_calls: result[:tool_calls] || [],
      turns: result[:turns],
      type: result[:type]
    }
  end

  # ── Text Extraction ───────────────────────────────────────────────

  @doc false
  def extract_text(response) when is_binary(response), do: response

  def extract_text(response) when is_struct(response) do
    extract_text(Map.from_struct(response))
  end

  def extract_text(response) when is_map(response) do
    extract_text_from_map(response)
  end

  def extract_text(_response), do: ""

  defp extract_text_from_map(%{text: text}) when is_binary(text), do: text
  defp extract_text_from_map(%{content: content}) when is_binary(content), do: content

  defp extract_text_from_map(%{message: %{content: content}}) when is_binary(content),
    do: content

  defp extract_text_from_map(%{message: message}) when is_struct(message) do
    message
    |> Map.from_struct()
    |> Map.get(:content, [])
    |> extract_content_parts()
  end

  defp extract_text_from_map(_), do: ""

  defp extract_content_parts(parts) when is_list(parts) do
    Enum.map_join(parts, "", &extract_content_part/1)
  end

  defp extract_content_parts(_), do: ""

  defp extract_content_part(part) when is_struct(part) do
    part |> Map.from_struct() |> Map.get(:text, "")
  end

  defp extract_content_part(part) when is_binary(part), do: part
  defp extract_content_part(_), do: ""

  # ── Usage Extraction ──────────────────────────────────────────────

  @doc false
  def extract_usage(response) when is_map(response) do
    usage = Map.get(response, :usage) || %{}

    %{
      input_tokens: Map.get(usage, :input_tokens, 0),
      output_tokens: Map.get(usage, :output_tokens, 0),
      cache_read_input_tokens: Map.get(usage, :cache_read_input_tokens, 0),
      total_tokens:
        Map.get(usage, :total_tokens) ||
          Map.get(usage, :input_tokens, 0) + Map.get(usage, :output_tokens, 0)
    }
  end

  def extract_usage(_),
    do: %{input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0, total_tokens: 0}

  # ── Thinking Block Extraction ─────────────────────────────────────

  @doc false
  def extract_thinking(response) when is_struct(response) do
    response
    |> Map.from_struct()
    |> extract_thinking()
  end

  def extract_thinking(%{message: message}) when is_struct(message) do
    message
    |> Map.from_struct()
    |> Map.get(:content, [])
    |> extract_thinking_blocks()
  end

  def extract_thinking(%{message: %{content: content}}) when is_list(content) do
    extract_thinking_blocks(content)
  end

  def extract_thinking(_), do: nil

  defp extract_thinking_blocks(parts) when is_list(parts) do
    thinking_blocks =
      parts
      |> Enum.filter(&thinking_block?/1)
      |> Enum.map(&normalize_thinking_block/1)

    case thinking_blocks do
      [] -> nil
      blocks -> blocks
    end
  end

  defp extract_thinking_blocks(_), do: nil

  defp thinking_block?(%{type: :thinking}), do: true
  defp thinking_block?(%{type: "thinking"}), do: true

  defp thinking_block?(part) when is_struct(part) do
    part |> Map.from_struct() |> thinking_block?()
  end

  defp thinking_block?(_), do: false

  defp normalize_thinking_block(part) when is_struct(part) do
    part |> Map.from_struct() |> normalize_thinking_block()
  end

  defp normalize_thinking_block(%{thinking: text} = block) do
    %{
      text: text,
      signature: Map.get(block, :signature)
    }
  end

  defp normalize_thinking_block(%{text: text} = block) do
    %{
      text: text,
      signature: Map.get(block, :signature)
    }
  end

  defp normalize_thinking_block(_), do: nil
end
