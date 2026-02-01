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
  **Type:** research
  **Effort:** medium
  **Depends On:** other-item.md, another.md
  **Blocks:** downstream.md

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
  - `:type` - String or nil (processor routing hint)
  - `:effort` - atom (:small, :medium, :large, :ongoing) or nil
  - `:summary` - String or nil
  - `:why_it_matters` - String or nil
  - `:acceptance_criteria` - List of %{text: String, completed: boolean}
  - `:definition_of_done` - List of %{text: String, completed: boolean}
  - `:depends_on` - List of Strings (filenames)
  - `:blocks` - List of Strings (filenames)
  - `:related_files` - List of Strings (file paths)
  - `:notes` - String or nil
  - `:metadata` - Map of unknown frontmatter key-value pairs
  - `:raw_content` - Original markdown string
  - `:content_hash` - SHA-256 hash (16 hex chars) of raw_content
  """

  @valid_priorities ~w(critical high medium low someday)
  @valid_categories ~w(feature refactor bug infrastructure idea research documentation content)
  @valid_efforts ~w(small medium large ongoing)

  @known_frontmatter_keys [
    "created",
    "priority",
    "category",
    "type",
    "effort",
    "depends on",
    "blocks"
  ]

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
  Unknown `**Key:** value` frontmatter is captured in `:metadata`.
  """
  @spec parse(String.t()) :: map()
  def parse(content) when is_binary(content) do
    lines = String.split(content, "\n")
    frontmatter = extract_all_frontmatter(content)

    %{
      title: extract_title(lines),
      created_at: parse_date(frontmatter["created"]),
      priority: parse_priority(frontmatter["priority"]),
      category: parse_category(frontmatter["category"]),
      type: frontmatter["type"],
      effort: parse_effort(frontmatter["effort"]),
      depends_on: parse_comma_list(frontmatter["depends on"]),
      blocks: parse_comma_list(frontmatter["blocks"]),
      summary: extract_section(content, "Summary"),
      why_it_matters: extract_section(content, "Why It Matters"),
      acceptance_criteria: extract_checklist(content, "Acceptance Criteria"),
      definition_of_done: extract_checklist(content, "Definition of Done"),
      related_files: extract_related_files(content),
      notes: extract_section(content, "Notes"),
      metadata: extract_metadata(frontmatter),
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
      serialize_frontmatter(item),
      serialize_section("Summary", item[:summary]),
      serialize_section("Why It Matters", item[:why_it_matters]),
      serialize_checklist_section("Acceptance Criteria", item[:acceptance_criteria]),
      serialize_checklist_section("Definition of Done", item[:definition_of_done]),
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

  defp extract_all_frontmatter(content) do
    # Extract all **Key:** value pairs between title and first ## section
    # First, get the frontmatter region (between # Title and first ## Section)
    frontmatter_region =
      case Regex.run(~r/^#\s+[^\n]+\n(.*?)(?=\n##\s|\z)/s, content) do
        [_, region] -> region
        nil -> content
      end

    Regex.scan(~r/\*\*([^*]+):\*\*\s*(.+)/, frontmatter_region)
    |> Map.new(fn [_, key, value] ->
      {String.downcase(String.trim(key)), String.trim(value)}
    end)
  end

  defp parse_date(nil), do: nil

  defp parse_date(date_str) do
    case Date.from_iso8601(String.trim(date_str)) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_priority(nil), do: nil

  defp parse_priority(priority_str) do
    priority = String.downcase(String.trim(priority_str))

    if priority in @valid_priorities do
      String.to_existing_atom(priority)
    else
      nil
    end
  rescue
    ArgumentError -> nil
  end

  defp parse_category(nil), do: nil

  defp parse_category(category_str) do
    category = String.downcase(String.trim(category_str))

    if category in @valid_categories do
      String.to_existing_atom(category)
    else
      nil
    end
  rescue
    ArgumentError -> nil
  end

  defp parse_effort(nil), do: nil

  defp parse_effort(effort_str) do
    effort = String.downcase(String.trim(effort_str))

    if effort in @valid_efforts do
      String.to_existing_atom(effort)
    else
      nil
    end
  rescue
    ArgumentError -> nil
  end

  defp parse_comma_list(nil), do: []

  defp parse_comma_list(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_metadata(frontmatter) do
    frontmatter
    |> Map.drop(@known_frontmatter_keys)
    |> case do
      empty when map_size(empty) == 0 -> %{}
      metadata -> metadata
    end
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

  defp serialize_frontmatter(item) do
    fields = [
      format_created(item),
      format_field(item[:priority], "Priority"),
      format_field(item[:category], "Category"),
      format_field(item[:type], "Type"),
      format_field(item[:effort], "Effort"),
      format_list_field(item[:depends_on], "Depends On"),
      format_list_field(item[:blocks], "Blocks")
    ]

    metadata_fields =
      (item[:metadata] || %{})
      |> Enum.map(fn {key, value} ->
        title_key =
          key |> to_string() |> String.split(" ") |> Enum.map_join(" ", &String.capitalize/1)

        "**#{title_key}:** #{value}"
      end)

    all_fields = (fields ++ metadata_fields) |> Enum.reject(&is_nil/1)
    [Enum.join(all_fields, "\n"), ""]
  end

  defp format_created(item) do
    case item[:created_at] do
      %Date{} = date -> "**Created:** #{Date.to_iso8601(date)}"
      _ -> "**Created:** #{Date.to_iso8601(Date.utc_today())}"
    end
  end

  defp format_field(nil, _label), do: nil
  defp format_field(value, label), do: "**#{label}:** #{value}"

  defp format_list_field(nil, _label), do: nil
  defp format_list_field([], _label), do: nil
  defp format_list_field(items, label), do: "**#{label}:** #{Enum.join(items, ", ")}"

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

  defp serialize_related_files(nil), do: nil
  defp serialize_related_files([]), do: nil

  defp serialize_related_files(files) when is_list(files) do
    items = Enum.map(files, &"- `#{&1}`")
    ["## Related Files", "" | items] ++ [""]
  end
end
