defmodule Arbor.Common.SkillLibrary.RawAdapter do
  @moduledoc """
  Adapter for reading plain markdown or text files as skills.

  Any `.md` or `.txt` file can be loaded as a skill. The name is derived from
  the filename (without extension, kept in kebab-case), the description from
  the first non-empty line (or first 200 characters), and the body is the full
  file content.

  Unlike `SkillAdapter`, there is no frontmatter parsing — the entire file is
  treated as content. Unlike `FabricAdapter`, there is no fixed directory
  structure — any markdown or text file qualifies.

  ## Examples

      docs/
        architecture-overview.md   <- skill "architecture-overview"
        coding-guidelines.txt      <- skill "coding-guidelines"
        sub/
          SKILL.md                 <- EXCLUDED (belongs to SkillAdapter)
          notes.md                 <- EXCLUDED (subdir has SKILL.md)

  All parsed skills have `source: :raw`, empty tags, and `nil` category.

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
  Parse a `.md` or `.txt` file into a skill struct or attribute map.

  Reads the file at `path`, derives the name from the filename (without
  extension), extracts a description from the first non-empty line, and
  captures the full content as the body.

  When `Arbor.Contracts.Skill` is loaded, returns `{:ok, %Skill{}}`.
  Otherwise returns `{:ok, %{name: ..., description: ..., ...}}`.

  ## Examples

      iex> RawAdapter.parse("/path/to/architecture-overview.md")
      {:ok, %{name: "architecture-overview", source: :raw, ...}}

      iex> RawAdapter.parse("/nonexistent/file.md")
      {:error, :enoent}

  """
  @spec parse(String.t()) :: {:ok, parsed_skill()} | {:error, term()}
  def parse(path) when is_binary(path) do
    with {:ok, content} <- File.read(path) do
      attrs = %{
        name: name_from_path(path),
        description: extract_description(content),
        body: String.trim(content),
        tags: [],
        category: nil,
        source: :raw,
        path: path,
        metadata: %{}
      }

      build_skill(attrs)
    end
  end

  @doc """
  List all `.md` and `.txt` file paths found directly under `dir`.

  Does not recurse into subdirectories that contain a `#{@skill_filename}` —
  those belong to `SkillAdapter`. Files in the top-level `dir` are always
  included. Subdirectories without a `#{@skill_filename}` are not recursed
  into either (flat listing per directory level, excluding skill-owned dirs).

  Returns a sorted list of absolute paths.

  ## Examples

      iex> RawAdapter.list("/path/to/docs")
      ["/path/to/docs/architecture-overview.md", "/path/to/docs/notes.txt"]

  """
  @spec list(String.t()) :: [String.t()]
  def list(dir) when is_binary(dir) do
    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.flat_map(fn entry ->
        full_path = Path.join(dir, entry)

        cond do
          File.dir?(full_path) ->
            # Skip subdirectories that have a SKILL.md (those belong to SkillAdapter)
            if has_skill_file?(full_path) do
              []
            else
              # Include raw files from subdirs without SKILL.md
              list_raw_files(full_path)
            end

          raw_file?(entry) ->
            [full_path]

          true ->
            []
        end
      end)
      |> Enum.sort()
    else
      []
    end
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

  # Derive a skill name from the filename (without extension, preserving kebab-case).
  # e.g., "/path/to/architecture-overview.md" -> "architecture-overview"
  defp name_from_path(path) do
    path
    |> Path.basename()
    |> Path.rootname()
  end

  # Extract a description from the first meaningful line of the file.
  #
  # Strategy:
  # 1. If the first non-empty line is a `# HEADING`, use the heading text.
  # 2. Otherwise, take the first non-empty line (up to 200 chars).
  @spec extract_description(String.t()) :: String.t()
  defp extract_description(content) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> extract_from_lines()
    |> truncate(200)
  end

  defp extract_from_lines([]), do: "Raw document"

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

  # Check if a file has a .md or .txt extension.
  defp raw_file?(filename) do
    ext = Path.extname(filename) |> String.downcase()
    ext in [".md", ".txt"]
  end

  # Check if a directory contains a SKILL.md file.
  defp has_skill_file?(dir) do
    dir
    |> Path.join(@skill_filename)
    |> File.exists?()
  end

  # List .md and .txt files directly inside a directory (non-recursive).
  defp list_raw_files(dir) do
    dir
    |> File.ls!()
    |> Enum.filter(&raw_file?/1)
    |> Enum.map(&Path.join(dir, &1))
  end
end
