defmodule Arbor.Contracts.Skill do
  @moduledoc """
  Data structure for reusable prompts and skills.

  A skill represents a reusable prompt template or instruction set that can be
  loaded from multiple sources (skill files, Fabric patterns, raw text) and
  discovered by agents through the `Arbor.Contracts.SkillLibrary` behaviour.

  ## Fields

  - `name` — unique identifier like `"security-perspective"` (required)
  - `description` — what it does and when to use it, max 1024 chars (required)
  - `body` — the actual prompt/instructions text (the skill content below frontmatter)
  - `tags` — searchable tags for discovery, default `[]`
  - `category` — grouping like `"advisory"`, `"fabric"`, `"custom"`
  - `source` — which adapter loaded it: `:skill`, `:fabric`, or `:raw`
  - `path` — filesystem path to the original file
  - `metadata` — any extra frontmatter fields
  """

  use TypedStruct

  @max_description_length 1024

  typedstruct do
    @typedoc "A reusable prompt/skill definition"

    field(:name, String.t(), enforce: true)
    field(:description, String.t(), enforce: true)
    field(:body, String.t(), default: "")
    field(:tags, [String.t()], default: [])
    field(:category, String.t() | nil)
    field(:source, atom(), default: :skill)
    field(:path, String.t() | nil)
    field(:metadata, map(), default: %{})
  end

  @doc """
  Create a new skill from a map of attributes.

  Validates that `name` and `description` are present and non-empty strings.
  Description is limited to #{@max_description_length} characters.

  ## Examples

      iex> Arbor.Contracts.Skill.new(%{name: "code-review", description: "Reviews code for quality"})
      {:ok, %Arbor.Contracts.Skill{name: "code-review", description: "Reviews code for quality", ...}}

      iex> Arbor.Contracts.Skill.new(%{name: "", description: "Reviews code"})
      {:error, {:invalid_field, :name, "must be a non-empty string"}}

  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_required_string(attrs, :name),
         :ok <- validate_required_string(attrs, :description),
         :ok <- validate_description_length(attrs) do
      skill = %__MODULE__{
        name: Map.fetch!(attrs, :name),
        description: Map.fetch!(attrs, :description),
        body: Map.get(attrs, :body, ""),
        tags: Map.get(attrs, :tags, []),
        category: Map.get(attrs, :category),
        source: Map.get(attrs, :source, :skill),
        path: Map.get(attrs, :path),
        metadata: Map.get(attrs, :metadata, %{})
      }

      {:ok, skill}
    end
  end

  # Private validation helpers

  defp validate_required_string(attrs, field) do
    case Map.get(attrs, field) do
      value when is_binary(value) and byte_size(value) > 0 ->
        :ok

      nil ->
        {:error, {:missing_required_field, field}}

      "" ->
        {:error, {:invalid_field, field, "must be a non-empty string"}}

      _other ->
        {:error, {:invalid_field, field, "must be a non-empty string"}}
    end
  end

  defp validate_description_length(attrs) do
    description = Map.get(attrs, :description, "")

    if is_binary(description) and String.length(description) > @max_description_length do
      {:error,
       {:invalid_field, :description,
        "must be at most #{@max_description_length} characters (got #{String.length(description)})"}}
    else
      :ok
    end
  end
end
