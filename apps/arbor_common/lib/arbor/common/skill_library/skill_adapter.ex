defmodule Arbor.Common.SkillLibrary.SkillAdapter do
  @moduledoc """
  Adapter for reading skills in the SKILL.md / Claude Skills format.

  Parses YAML-like frontmatter delimited by `---` lines, extracting fields
  like `name`, `description`, `tags`, and `category`. Everything after the
  closing `---` is the skill body (prompt/instructions).

  This adapter handles the native skill format used by `.arbor/skills/` and
  `.claude/skills/` directories.

  ## File Format

      ---
      name: security-perspective
      description: Defensive security analysis
      tags: [advisory, security, analysis]
      category: advisory
      ---

      Your prompt content here...

  All parsed skills have `source: :skill`.

  ## Return Value

  `parse/1` returns `{:ok, skill_struct}` when `Arbor.Contracts.Skill` is
  available (runtime bridge), or `{:ok, attrs_map}` as a fallback. Either way,
  the shape contains all the same fields: `name`, `description`, `body`, `tags`,
  `category`, `source`, `path`, and `metadata`.
  """

  @skill_filename "SKILL.md"

  @typedoc "Parsed skill — either `Arbor.Contracts.Skill.t()` or a plain map with the same keys."
  @type parsed_skill :: struct() | map()

  @doc """
  Parse a SKILL.md file into a skill struct or attribute map.

  Reads the file at `path`, splits on `---` frontmatter delimiters, parses
  key-value pairs from the frontmatter, and captures the body.

  When `Arbor.Contracts.Skill` is loaded, returns `{:ok, %Skill{}}`.
  Otherwise returns `{:ok, %{name: ..., description: ..., ...}}`.

  ## Examples

      iex> SkillAdapter.parse("/path/to/advisory/security/SKILL.md")
      {:ok, %{name: "security-perspective", source: :skill, ...}}

      iex> SkillAdapter.parse("/nonexistent/SKILL.md")
      {:error, :enoent}

  """
  @spec parse(String.t()) :: {:ok, parsed_skill()} | {:error, term()}
  def parse(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, frontmatter, body} <- split_frontmatter(content),
         {:ok, fields} <- parse_frontmatter(frontmatter) do
      trimmed_body = String.trim(body)

      attrs = %{
        name: Map.get(fields, "name", name_from_path(path)),
        description: Map.get(fields, "description", ""),
        body: trimmed_body,
        tags: parse_list(Map.get(fields, "tags", [])),
        category: Map.get(fields, "category"),
        source: :skill,
        path: path,
        metadata: extra_fields(fields),
        license: Map.get(fields, "license"),
        compatibility: Map.get(fields, "compatibility"),
        allowed_tools: parse_allowed_tools(Map.get(fields, "allowed-tools")),
        content_hash: compute_content_hash(trimmed_body)
      }

      build_skill(attrs)
    end
  end

  @doc """
  List all SKILL.md file paths found recursively under `dir`.

  Returns a list of absolute paths to files named `#{@skill_filename}`.

  ## Examples

      iex> SkillAdapter.list("/path/to/skills")
      ["/path/to/skills/advisory/security/SKILL.md", ...]

  """
  @spec list(String.t()) :: [String.t()]
  def list(dir) when is_binary(dir) do
    dir
    |> Path.join("**/" <> @skill_filename)
    |> Path.wildcard()
    |> Enum.sort()
  end

  # --- Frontmatter Parsing ---

  @doc false
  @spec split_frontmatter(String.t()) :: {:ok, String.t(), String.t()} | {:error, :no_frontmatter}
  def split_frontmatter(content) do
    case Regex.split(~r/^---\s*$/m, content, parts: 3) do
      # Content starts with ---, so the first element is empty or whitespace
      [before, frontmatter, body] ->
        if String.trim(before) == "" do
          {:ok, frontmatter, body}
        else
          {:error, :no_frontmatter}
        end

      _ ->
        {:error, :no_frontmatter}
    end
  end

  @doc false
  @spec parse_frontmatter(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_frontmatter(text) do
    fields =
      text
      |> String.split("\n")
      |> Enum.reduce(%{}, fn line, acc ->
        case parse_kv_line(String.trim(line)) do
          {key, value} -> Map.put(acc, key, value)
          nil -> acc
        end
      end)

    {:ok, fields}
  end

  # --- Private Helpers ---

  # Build a Skill struct via runtime bridge, falling back to plain map.
  defp build_skill(attrs) do
    if Code.ensure_loaded?(Arbor.Contracts.Skill) and
         function_exported?(Arbor.Contracts.Skill, :new, 1) do
      Arbor.Contracts.Skill.new(attrs)
    else
      {:ok, attrs}
    end
  end

  # Parse a single "key: value" line from frontmatter.
  # Handles simple strings, bracket-delimited lists, and bare values.
  defp parse_kv_line(""), do: nil
  defp parse_kv_line("#" <> _), do: nil

  defp parse_kv_line(line) do
    case String.split(line, ":", parts: 2) do
      [key, value] ->
        key = String.trim(key)
        value = String.trim(value)

        if key != "" do
          {key, parse_value(value)}
        else
          nil
        end

      _ ->
        nil
    end
  end

  # Parse a frontmatter value — handles bracket lists and plain strings.
  defp parse_value("[" <> _ = value) do
    # Bracket list like [advisory, security, analysis]
    value
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_value(value), do: value

  # Normalize tags/lists — if it's already a list, keep it; if string, wrap it.
  defp parse_list(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp parse_list(value) when is_binary(value) and byte_size(value) > 0, do: [value]
  defp parse_list(_), do: []

  # Known frontmatter fields that map to Skill struct fields.
  @known_fields ~w(name description tags category license compatibility allowed-tools)

  # Extract any fields beyond the known set into metadata.
  defp extra_fields(fields) do
    fields
    |> Map.drop(@known_fields)
    |> case do
      empty when map_size(empty) == 0 -> %{}
      metadata -> metadata
    end
  end

  # Parse allowed-tools: space-delimited string → list, or pass through lists.
  defp parse_allowed_tools(nil), do: []
  defp parse_allowed_tools(tools) when is_list(tools), do: Enum.map(tools, &to_string/1)

  defp parse_allowed_tools(tools) when is_binary(tools) do
    tools
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Compute SHA256 content hash of the skill body.
  defp compute_content_hash(body) when is_binary(body) do
    :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
  end

  # Derive a skill name from the file path.
  # e.g., "/path/to/advisory/security/SKILL.md" -> "security"
  defp name_from_path(path) do
    path
    |> Path.dirname()
    |> Path.basename()
  end
end
