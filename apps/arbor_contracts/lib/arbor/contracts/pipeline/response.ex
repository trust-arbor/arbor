defmodule Arbor.Contracts.Pipeline.Response do
  @moduledoc """
  Normalized response from the LLM pipeline.

  This is the single contract between the orchestrator (producer) and all
  consumers (dashboard, agents, logging). Every LLM pipeline output must
  be normalized into this struct before crossing an app boundary.

  ## Normalization

  `normalize/1` handles all known input shapes:
  - Plain strings → `%Response{content: string}`
  - Maps with `:text` or `"text"` keys → extracts text
  - Nested maps `%{text: %{text: "..."}}` → deep extracts
  - Nil → empty response
  - Already a `%Response{}` → passthrough

  ## Usage

      # At the source (ToolLoop, LlmHandler)
      response = Response.normalize(raw_output)

      # In consumers (ChatLive, APIAgent)
      %Response{content: text} = response

      # Safe rendering in templates
      {response.content}  # Always a binary, never a map
  """

  alias Arbor.Contracts.Security.Taint

  @taint_fields [:level, :sensitivity, :sanitizations, :confidence, :source, :chain]

  @type t :: %__MODULE__{
          content: String.t(),
          tool_history: [map()],
          tool_rounds: non_neg_integer(),
          usage: map(),
          finish_reason: atom() | nil,
          content_parts: [map()],
          raw: map() | nil,
          discovered_tools: [String.t()],
          metadata: map(),
          taint: Taint.t() | nil
        }

  @enforce_keys [:content]
  defstruct content: "",
            tool_history: [],
            tool_rounds: 0,
            usage: %{},
            finish_reason: nil,
            content_parts: [],
            raw: nil,
            discovered_tools: [],
            metadata: %{},
            taint: nil

  @doc """
  Normalize any LLM pipeline output into a `%Response{}`.

  Handles all known formats from ToolLoop, LlmHandler, APIAgent, and Session.
  """
  @spec normalize(term()) :: t()
  def normalize(%__MODULE__{} = response) do
    %{response | taint: normalize_taint(response.taint)}
  end

  def normalize(text) when is_binary(text) do
    %__MODULE__{content: text}
  end

  def normalize(%{text: %{text: inner}} = map) when is_binary(inner) do
    # Nested map: %{text: %{text: "...", tool_rounds: 0, tool_history: []}}
    from_map(map, inner)
  end

  def normalize(%{text: text} = map) when is_binary(text) do
    from_map(map, text)
  end

  def normalize(%{"text" => %{"text" => inner}} = map) when is_binary(inner) do
    from_map(map, inner)
  end

  def normalize(%{"text" => text} = map) when is_binary(text) do
    from_map(map, text)
  end

  # Map with :content key (from Session path)
  def normalize(%{content: content} = map) when is_binary(content) do
    from_map(map, content)
  end

  def normalize(%{"content" => content} = map) when is_binary(content) do
    from_map(map, content)
  end

  # Map with text as a nested map (the recurring ToolLoop format)
  def normalize(%{text: %{} = inner_map}) do
    text = Map.get(inner_map, :text) || Map.get(inner_map, "text", "")
    text = if is_binary(text), do: text, else: ""

    %__MODULE__{
      content: text,
      tool_rounds: Map.get(inner_map, :tool_rounds, 0) || 0,
      tool_history: Map.get(inner_map, :tool_history, []) || [],
      taint: get_taint(inner_map)
    }
  end

  # Map without a recognizable text field
  def normalize(%{} = map) do
    %__MODULE__{
      content: "",
      metadata: map
    }
  end

  def normalize(nil), do: %__MODULE__{content: ""}
  def normalize(_other), do: %__MODULE__{content: ""}

  @doc """
  Extract just the content string. Useful as a quick accessor.
  """
  @spec content(t() | term()) :: String.t()
  def content(%__MODULE__{content: c}), do: c
  def content(text) when is_binary(text), do: text
  def content(_), do: ""

  # Build a Response from a map, extracting known fields
  defp from_map(map, text) do
    %__MODULE__{
      content: text,
      tool_history: get_list(map, :tool_history, "tool_history"),
      tool_rounds: get_int(map, :tool_rounds, "tool_rounds"),
      usage: get_map(map, :usage, "usage"),
      finish_reason: Map.get(map, :finish_reason) || Map.get(map, "finish_reason"),
      content_parts: get_list(map, :content_parts, "content_parts"),
      raw: Map.get(map, :raw) || Map.get(map, "raw"),
      discovered_tools: get_list(map, :discovered_tools, "discovered_tools"),
      metadata: Map.get(map, :metadata) || Map.get(map, "metadata", %{}),
      taint: get_taint(map)
    }
  end

  # Taint is a process-local typed field, not a JSON decoding surface. Reject
  # ambiguous keys, plain maps, forged struct shapes, and invalid dimensions.
  defp get_taint(map) do
    case {Map.fetch(map, :taint), Map.fetch(map, "taint")} do
      {{:ok, taint}, :error} -> normalize_taint(taint)
      {:error, {:ok, taint}} -> normalize_taint(taint)
      _missing_or_ambiguous -> nil
    end
  end

  defp normalize_taint(nil), do: nil

  defp normalize_taint(%Taint{} = taint) do
    if exact_valid_taint?(taint), do: taint, else: nil
  end

  defp normalize_taint(_malformed), do: nil

  defp exact_valid_taint?(taint) do
    map_size(taint) == length(@taint_fields) + 1 and
      Enum.sort(Map.keys(taint)) == Enum.sort([:__struct__ | @taint_fields]) and
      taint.level in Taint.levels() and
      taint.sensitivity in Taint.sensitivities() and
      is_integer(taint.sanitizations) and taint.sanitizations in 0..255 and
      taint.confidence in Taint.confidences() and
      (is_nil(taint.source) or is_binary(taint.source)) and
      is_list(taint.chain) and Enum.all?(taint.chain, &is_binary/1)
  end

  defp get_list(map, atom_key, string_key) do
    case Map.get(map, atom_key) || Map.get(map, string_key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp get_int(map, atom_key, string_key) do
    case Map.get(map, atom_key) || Map.get(map, string_key) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp get_map(map, atom_key, string_key) do
    case Map.get(map, atom_key) || Map.get(map, string_key) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end
end

# Implement Phoenix.HTML.Safe so templates can never crash on this struct
if Code.ensure_loaded?(Phoenix.HTML.Safe) do
  defimpl Phoenix.HTML.Safe, for: Arbor.Contracts.Pipeline.Response do
    def to_iodata(%{content: content}) when is_binary(content) do
      # Use Phoenix.HTML.Engine.html_escape or manual escaping
      # since Plug.HTML may not be available at Level 0
      content
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
      |> String.replace("\"", "&quot;")
      |> String.replace("'", "&#39;")
    end

    def to_iodata(_), do: ""
  end
end
