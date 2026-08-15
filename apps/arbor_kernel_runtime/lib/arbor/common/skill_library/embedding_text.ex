defmodule Arbor.Common.SkillLibrary.EmbeddingText do
  @moduledoc """
  Canonical skill text used for write-time embedding generation.

  Stable format (no path, license, provenance, taint, or content_hash):

      name: <name>
      description: <description>
      category: <category or empty>
      tags: <sorted tags joined by ", ">

      <body trimmed>
  """

  @doc "Build the canonical embedding text for a skill struct or map."
  @spec for_skill(map() | struct()) :: String.t()
  def for_skill(skill) when is_map(skill) do
    name = field(skill, :name, "")
    description = field(skill, :description, "")
    category = field(skill, :category, "") || ""
    body = field(skill, :body, "") || ""

    tags =
      skill
      |> field(:tags, [])
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.sort()
      |> Enum.join(", ")

    """
    name: #{name}
    description: #{description}
    category: #{category}
    tags: #{tags}

    #{String.trim(body)}
    """
    |> String.trim()
  end

  defp field(skill, key, default) do
    Map.get(skill, key) || Map.get(skill, Atom.to_string(key)) || default
  end
end
