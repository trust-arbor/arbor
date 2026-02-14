defmodule Arbor.Common.SkillLibrary.FabricAdapter do
  @moduledoc """
  Adapter for reading Fabric patterns as skills.

  Fabric patterns live in `patterns/*/system.md` — each directory is a pattern
  name and `system.md` contains the system prompt.

  Unlike SKILL.md files, Fabric patterns have no YAML frontmatter. The name is
  derived from the parent directory, the description from the first paragraph or
  `# HEADING` line, and the body is the full file content.

  ## File Format

      patterns/
        extract_wisdom/
          system.md    <- "# IDENTITY and PURPOSE\\nYou extract..."
        review_code/
          system.md    <- "# Code Review Task\\n..."

  All parsed skills have `source: :fabric`.

  ## Tags

  Tags are derived from the directory path segments between the patterns root
  and the pattern directory itself. For example, a pattern at
  `patterns/security/analyze_threat_report/system.md` would get tags
  `["security", "analyze_threat_report"]`.

  ## Return Value

  `parse/1` returns `{:ok, skill_struct}` when `Arbor.Contracts.Skill` is
  available (runtime bridge), or `{:ok, attrs_map}` as a fallback. Either way,
  the shape contains all the same fields: `name`, `description`, `body`, `tags`,
  `category`, `source`, `path`, and `metadata`.
  """

  @pattern_filename "system.md"

  @typedoc "Parsed skill — either `Arbor.Contracts.Skill.t()` or a plain map with the same keys."
  @type parsed_skill :: struct() | map()

  @doc """
  Parse a Fabric `system.md` file into a skill struct or attribute map.

  Reads the file at `path`, derives the name from the parent directory,
  extracts a description from the first heading or paragraph, and captures
  the full content as the body.

  When `Arbor.Contracts.Skill` is loaded, returns `{:ok, %Skill{}}`.
  Otherwise returns `{:ok, %{name: ..., description: ..., ...}}`.

  ## Examples

      iex> FabricAdapter.parse("/path/to/patterns/extract_wisdom/system.md")
      {:ok, %{name: "extract_wisdom", source: :fabric, ...}}

      iex> FabricAdapter.parse("/nonexistent/system.md")
      {:error, :enoent}

  """
  @spec parse(String.t()) :: {:ok, parsed_skill()} | {:error, term()}
  def parse(path) when is_binary(path) do
    with {:ok, content} <- File.read(path) do
      attrs = %{
        name: name_from_path(path),
        description: extract_description(content),
        body: String.trim(content),
        tags: tags_from_path(path),
        category: "fabric",
        source: :fabric,
        path: path,
        metadata: %{}
      }

      build_skill(attrs)
    end
  end

  @doc """
  List all Fabric pattern `system.md` file paths found under `dir`.

  Expects the Fabric directory layout where patterns live in
  `patterns/*/system.md`. If `dir` itself is the `patterns/` directory,
  it searches `dir/*/#{@pattern_filename}`. Otherwise it searches
  `dir/**/#{@pattern_filename}`.

  Returns a sorted list of absolute paths.

  ## Examples

      iex> FabricAdapter.list("/path/to/fabric/patterns")
      ["/path/to/fabric/patterns/analyze_prose/system.md", ...]

  """
  @spec list(String.t()) :: [String.t()]
  def list(dir) when is_binary(dir) do
    dir
    |> Path.join("**/" <> @pattern_filename)
    |> Path.wildcard()
    |> Enum.sort()
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

  # Derive a pattern name from the file path.
  # e.g., "/path/to/patterns/extract_wisdom/system.md" -> "extract_wisdom"
  defp name_from_path(path) do
    path
    |> Path.dirname()
    |> Path.basename()
  end

  # Extract a description from the first meaningful content in the file.
  #
  # Strategy:
  # 1. If the file starts with a `# HEADING`, use the heading text.
  # 2. Otherwise, take the first non-empty paragraph (up to 200 chars).
  @spec extract_description(String.t()) :: String.t()
  defp extract_description(content) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> extract_from_lines()
    |> truncate(200)
  end

  # If the first non-empty line is a heading, use it (without the `#` prefix).
  # Otherwise, take the first non-empty line as the description.
  defp extract_from_lines([]), do: "Fabric pattern"

  defp extract_from_lines(["#" <> rest | lines]) do
    heading = String.trim(rest)

    if heading == "" do
      extract_from_lines(lines)
    else
      heading
    end
  end

  defp extract_from_lines([first | _]), do: first

  # Truncate a string to `max` characters, appending "..." if truncated.
  defp truncate(str, max) when byte_size(str) <= max, do: str

  defp truncate(str, max) do
    String.slice(str, 0, max - 3) <> "..."
  end

  # Derive tags from the directory path segments.
  #
  # Finds the "patterns" directory in the path and collects all segments
  # between it and the pattern's own directory (inclusive).
  #
  # Examples:
  #   "~/.config/fabric/patterns/extract_wisdom/system.md"
  #     -> ["extract_wisdom"]
  #
  #   "~/.config/fabric/patterns/security/analyze_threat/system.md"
  #     -> ["security", "analyze_threat"]
  @spec tags_from_path(String.t()) :: [String.t()]
  defp tags_from_path(path) do
    parts =
      path
      |> Path.dirname()
      |> Path.split()

    case find_patterns_index(parts) do
      nil ->
        # No "patterns" directory found — just use the immediate parent dir
        [List.last(parts) || "fabric"]

      idx ->
        # Everything after "patterns" up to (but not including) the filename
        parts
        |> Enum.drop(idx + 1)
        |> case do
          [] -> ["fabric"]
          segments -> segments
        end
    end
  end

  # Find the index of the "patterns" directory in a list of path segments.
  defp find_patterns_index(parts) do
    Enum.find_index(parts, &(&1 == "patterns"))
  end
end
