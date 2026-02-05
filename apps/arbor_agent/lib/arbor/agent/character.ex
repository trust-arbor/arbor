defmodule Arbor.Agent.Character do
  @moduledoc """
  Lightweight personality schema for agents.

  Captures identity, personality, voice, knowledge, and instructions.
  Rendered to system prompts for LLM interaction via `to_system_prompt/1`.

  This is NOT a memory system — Arbor's memory architecture handles all
  dynamic memory (knowledge graphs, working memory, embeddings, consolidation).
  Character knowledge is static/definitional: facts that define who the agent
  *is*, not what it has learned.
  """

  use TypedStruct

  typedstruct do
    field(:name, String.t(), enforce: true)
    field(:description, String.t(), default: nil)

    # Identity — who the character is
    field(:role, String.t(), default: nil)
    field(:background, String.t(), default: nil)

    # Personality — how they behave
    # Each trait: %{name: "curious", intensity: 0.9}
    field(:traits, [map()], default: [])
    field(:values, [String.t()], default: [])
    field(:quirks, [String.t()], default: [])

    # Voice — how they communicate
    field(:tone, String.t(), default: nil)
    field(:style, String.t(), default: nil)

    # Knowledge — permanent definitional facts (NOT dynamic memory)
    # Each: %{content: "...", category: "skills"}
    field(:knowledge, [map()], default: [])

    # Instructions — behavioral guidance for LLM
    field(:instructions, [String.t()], default: [])
  end

  @doc """
  Create a new character from a keyword list or map.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: struct!(__MODULE__, attrs)
  def new(attrs) when is_map(attrs), do: struct!(__MODULE__, Map.to_list(attrs))

  @doc """
  Render character to a system prompt string for LLM consumption.

  Produces markdown-formatted sections: Identity, Personality, Voice,
  Knowledge, Instructions. Nil/empty sections are omitted.
  """
  @spec to_system_prompt(t()) :: String.t()
  def to_system_prompt(%__MODULE__{} = char) do
    [
      render_header(char),
      render_identity(char),
      render_personality(char),
      render_voice(char),
      render_knowledge(char.knowledge),
      render_instructions(char.instructions)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  @doc """
  Converts the character to a plain map for serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = char) do
    Map.from_struct(char)
  end

  @doc """
  Builds a Character from a plain map (e.g., from JSON deserialization).
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    attrs =
      map
      |> Enum.map(fn {k, v} -> {to_atom_key(k), v} end)
      |> Enum.into(%{})

    struct!(__MODULE__, attrs)
  end

  # -- Private render helpers --

  defp render_header(%{name: name, description: nil}), do: "# Character: #{name}"

  defp render_header(%{name: name, description: desc}),
    do: "# Character: #{name}\n\n#{desc}"

  defp render_identity(%{role: nil, background: nil}), do: nil

  defp render_identity(char) do
    lines = []
    lines = if char.role, do: ["**Role:** #{char.role}" | lines], else: lines
    lines = if char.background, do: ["**Background:** #{char.background}" | lines], else: lines

    "## Identity\n\n" <> (lines |> Enum.reverse() |> Enum.join("\n"))
  end

  defp render_personality(%{traits: [], values: [], quirks: []}), do: nil

  defp render_personality(char) do
    sections = []

    sections =
      if char.traits != [] do
        trait_lines =
          Enum.map(char.traits, fn trait ->
            level = intensity_label(trait[:intensity] || trait["intensity"])
            "- **#{trait[:name] || trait["name"]}** (#{level})"
          end)

        ["**Traits:**\n" <> Enum.join(trait_lines, "\n") | sections]
      else
        sections
      end

    sections =
      if char.values != [] do
        value_lines = Enum.map(char.values, &"- #{&1}")
        ["**Values:**\n" <> Enum.join(value_lines, "\n") | sections]
      else
        sections
      end

    sections =
      if char.quirks != [] do
        quirk_lines = Enum.map(char.quirks, &"- #{&1}")
        ["**Quirks:**\n" <> Enum.join(quirk_lines, "\n") | sections]
      else
        sections
      end

    "## Personality\n\n" <> (sections |> Enum.reverse() |> Enum.join("\n\n"))
  end

  defp render_voice(%{tone: nil, style: nil}), do: nil

  defp render_voice(char) do
    lines = []
    lines = if char.tone, do: ["**Tone:** #{char.tone}" | lines], else: lines
    lines = if char.style, do: ["**Style:** #{char.style}" | lines], else: lines

    "## Voice\n\n" <> (lines |> Enum.reverse() |> Enum.join("\n"))
  end

  defp render_knowledge([]), do: nil

  defp render_knowledge(knowledge) do
    lines =
      Enum.map(knowledge, fn item ->
        category = item[:category] || item["category"]
        content = item[:content] || item["content"]

        if category do
          "- [#{category}] #{content}"
        else
          "- #{content}"
        end
      end)

    "## Knowledge\n\n" <> Enum.join(lines, "\n")
  end

  defp render_instructions([]), do: nil

  defp render_instructions(instructions) do
    lines = Enum.map(instructions, &"- #{&1}")
    "## Instructions\n\n" <> Enum.join(lines, "\n")
  end

  defp intensity_label(intensity) when is_number(intensity) do
    cond do
      intensity >= 0.7 -> "high"
      intensity >= 0.4 -> "moderate"
      true -> "low"
    end
  end

  defp intensity_label(_), do: "moderate"

  defp to_atom_key(key) when is_atom(key), do: key
  defp to_atom_key(key) when is_binary(key), do: String.to_existing_atom(key)
end
