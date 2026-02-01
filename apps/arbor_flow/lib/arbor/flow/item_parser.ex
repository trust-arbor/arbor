defmodule Arbor.Flow.ItemParser do
  @moduledoc """
  Pure markdown parser and serializer for workflow items.

  This module parses markdown files into plain maps and serializes maps back
  to markdown. It is round-trip safe: `parse |> serialize |> parse` produces
  identical data (modulo whitespace normalization).

  ## Markdown Format

  Items follow this structure:

  ```markdown
  # Title

  **Created:** 2026-02-01
  **Priority:** high
  **Category:** feature

  ## Summary

  Brief description of the item...

  ## Why It Matters

  Explanation of importance...

  ## Acceptance Criteria

  - [x] Completed criterion
  - [ ] Pending criterion

  ## Definition of Done

  - [ ] First done item
  - [ ] Second done item

  ## Related Files

  - `path/to/file.ex`
  - `another/file.ex`

  ## Notes

  Free-form notes...
  ```

  ## Usage

  ```elixir
  # Parse from file
  {:ok, item_map} = ItemParser.parse_file("roadmap/0-inbox/feature.md")

  # Parse from string
  item_map = ItemParser.parse(markdown_content)

  # Serialize to markdown
  markdown = ItemParser.serialize(item_map)

  # Round-trip safe
  item_map == ItemParser.parse(ItemParser.serialize(item_map))
  ```

  ## Output Map Structure

  The parsed map contains:

  - `:title` - String
  - `:created_at` - Date or nil
  - `:priority` - atom (:critical, :high, :medium, :low, :someday) or nil
  - `:category` - atom (:feature, :bug, etc.) or nil
  - `:summary` - String or nil
  - `:why_it_matters` - String or nil
  - `:acceptance_criteria` - List of %{text: String, completed: boolean}
  - `:definition_of_done` - List of %{text: String, completed: boolean}
  - `:depends_on` - List of Strings (item IDs)
  - `:blocks` - List of Strings (item IDs)
  - `:related_files` - List of Strings (file paths)
  - `:notes` - String or nil
  - `:raw_content` - Original markdown string
  - `:content_hash` - SHA-256 hash (16 hex chars) of raw_content
  """

  @valid_priorities ~w(critical high medium low someday)
  @valid_categories ~w(feature refactor bug infrastructure idea research documentation)

  @doc """
  Parse a markdown file into an item map.

  Returns `{:ok, map}` on success, `{:error, reason}` on failure.
  """
  @spec parse_file(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_file(path) do
    case File.read(path) do
      {:ok, content} ->
        item = parse(content)
        {:ok, Map.put(item, :path, path)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parse markdown content into an item map.

  Always succeeds - missing fields become nil or empty lists.
  """
  @spec parse(String.t()) :: map()
  def parse(content) when is_binary(content) do
    lines = String.split(content, "\n")

    %{
      title: extract_title(lines),
      created_at: extract_date(content, "Created"),
      priority: extract_priority(content),
      category: extract_category(content),
      summary: extract_section(content, "Summary"),
      why_it_matters: extract_section(content, "Why It Matters"),
      acceptance_criteria: extract_checklist(content, "Acceptance Criteria"),
      definition_of_done: extract_checklist(content, "Definition of Done"),
      depends_on: extract_depends_on(content),
      blocks: extract_blocks(content),
      related_files: extract_related_files(content),
      notes: extract_section(content, "Notes"),
      raw_content: content,
      content_hash: compute_hash(content)
    }
  end

  @doc """
  Serialize an item map to markdown.

  Produces well-formatted markdown that round-trips through parse.
  """
  @spec serialize(map()) :: String.t()
  def serialize(%{} = item) do
    sections = [
      serialize_title(item),
      "",
      serialize_metadata(item),
      serialize_section("Summary", item[:summary]),
      serialize_section("Why It Matters", item[:why_it_matters]),
      serialize_checklist_section("Acceptance Criteria", item[:acceptance_criteria]),
      serialize_checklist_section("Definition of Done", item[:definition_of_done]),
      serialize_dependencies(item),
      serialize_related_files(item[:related_files]),
      serialize_section("Notes", item[:notes])
    ]

    sections
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.trim()
    |> Kernel.<>("\n")
  end

  # =============================================================================
  # Parsing Functions
  # =============================================================================

  defp extract_title(lines) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/^#\s+(.+)$/, String.trim(line)) do
        [_, title] -> String.trim(title)
        nil -> nil
      end
    end)
  end

  defp extract_date(content, field) do
    case Regex.run(~r/\*\*#{field}:\*\*\s*(\d{4}-\d{2}-\d{2})/i, content) do
      [_, date_str] ->
        case Date.from_iso8601(date_str) do
          {:ok, date} -> date
          _ -> nil
        end

      nil ->
        nil
    end
  end

  defp extract_priority(content) do
    case Regex.run(~r/\*\*Priority:\*\*\s*(\w+)/i, content) do
      [_, priority_str] ->
        priority = String.downcase(priority_str)

        if priority in @valid_priorities do
          String.to_existing_atom(priority)
        else
          nil
        end

      nil ->
        nil
    end
  rescue
    # If the atom doesn't exist, return nil
    ArgumentError -> nil
  end

  defp extract_category(content) do
    case Regex.run(~r/\*\*Category:\*\*\s*(\w+)/i, content) do
      [_, category_str] ->
        category = String.downcase(category_str)

        if category in @valid_categories do
          String.to_existing_atom(category)
        else
          nil
        end

      nil ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp extract_section(content, section_name) do
    # Match from section header to next section header (## ) or end
    pattern = ~r/##\s+#{Regex.escape(section_name)}\s*\n(.*?)(?=\n##\s|\z)/s

    case Regex.run(pattern, content) do
      [_, section_content] ->
        trimmed = String.trim(section_content)
        if trimmed == "", do: nil, else: trimmed

      nil ->
        nil
    end
  end

  defp extract_checklist(content, section_name) do
    section = extract_section(content, section_name)

    if section do
      Regex.scan(~r/- \[([ xX])\]\s*(.+)/, section)
      |> Enum.map(fn [_, checked, text] ->
        %{
          text: String.trim(text),
          completed: checked != " "
        }
      end)
    else
      []
    end
  end

  defp extract_depends_on(content) do
    section = extract_section(content, "Dependencies") || extract_section(content, "Depends On")

    if section do
      extract_item_references(section, "Depends on")
    else
      []
    end
  end

  defp extract_blocks(content) do
    section = extract_section(content, "Dependencies") || extract_section(content, "Blocks")

    if section do
      extract_item_references(section, "Blocks")
    else
      []
    end
  end

  defp extract_item_references(section, prefix) do
    # Match lines like "- Depends on: item_abc123" or "- Blocks: item_xyz"
    pattern = ~r/-\s*#{Regex.escape(prefix)}:\s*(.+)/i

    Regex.scan(pattern, section)
    |> Enum.map(fn [_, ref] -> String.trim(ref) end)
  end

  defp extract_related_files(content) do
    section = extract_section(content, "Related Files")

    if section do
      Regex.scan(~r/- `([^`]+)`/, section)
      |> Enum.map(fn [_, path] -> path end)
    else
      []
    end
  end

  defp compute_hash(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  # =============================================================================
  # Serialization Functions
  # =============================================================================

  defp serialize_title(%{title: nil}), do: "# [Untitled]"
  defp serialize_title(%{title: title}), do: "# #{title}"

  defp serialize_metadata(item) do
    parts = []

    parts =
      case item[:created_at] do
        %Date{} = date -> ["**Created:** #{Date.to_iso8601(date)}" | parts]
        _ -> ["**Created:** #{Date.to_iso8601(Date.utc_today())}" | parts]
      end

    parts =
      if item[:priority] do
        ["**Priority:** #{item[:priority]}" | parts]
      else
        parts
      end

    parts =
      if item[:category] do
        ["**Category:** #{item[:category]}" | parts]
      else
        parts
      end

    [Enum.reverse(parts) |> Enum.join("\n"), ""]
  end

  defp serialize_section(_name, nil), do: nil
  defp serialize_section(_name, ""), do: nil

  defp serialize_section(name, content) do
    ["## #{name}", "", content, ""]
  end

  defp serialize_checklist_section(_name, nil), do: nil
  defp serialize_checklist_section(_name, []), do: nil

  defp serialize_checklist_section(name, criteria) when is_list(criteria) do
    items =
      Enum.map(criteria, fn
        %{text: text, completed: completed} ->
          checkbox = if completed, do: "[x]", else: "[ ]"
          "- #{checkbox} #{text}"

        text when is_binary(text) ->
          "- [ ] #{text}"
      end)

    ["## #{name}", "" | items] ++ [""]
  end

  defp serialize_dependencies(item) do
    depends_on = item[:depends_on] || []
    blocks = item[:blocks] || []

    if depends_on == [] and blocks == [] do
      nil
    else
      lines = ["## Dependencies", ""]

      lines =
        lines ++
          Enum.map(depends_on, fn ref ->
            "- Depends on: #{ref}"
          end)

      lines =
        lines ++
          Enum.map(blocks, fn ref ->
            "- Blocks: #{ref}"
          end)

      lines ++ [""]
    end
  end

  defp serialize_related_files(nil), do: nil
  defp serialize_related_files([]), do: nil

  defp serialize_related_files(files) when is_list(files) do
    items = Enum.map(files, &"- `#{&1}`")
    ["## Related Files", "" | items] ++ [""]
  end
end
