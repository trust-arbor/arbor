defmodule Arbor.Flow.IndexManager do
  @moduledoc """
  Manages INDEX.md files for workflow directories.

  The INDEX.md file provides a human-readable overview of items across
  pipeline stages, organized by priority and status.

  ## INDEX.md Structure

  ```markdown
  # Workflow Index

  _Last updated: 2026-02-01T12:00:00Z_

  ## Active Work

  ### In Progress
  - 🟠 **[Feature Title](3-in_progress/feature.md)** - Brief summary

  ### Blocked
  _None_

  ## Planned

  ### Critical
  - 🔴 **[Critical Item](2-planned/critical.md)** - Summary

  ### High Priority
  - 🟠 **[High Item](2-planned/high.md)** - Summary

  ### Medium Priority
  _None_

  ### Low Priority
  _None_

  ### Someday
  _None_

  ## Recently Completed

  - ✅ **[Done Item](4-completed/done.md)** - Completed 2026-02-01
  ```

  ## Usage

  ```elixir
  # Refresh the index from directory contents
  :ok = IndexManager.refresh("/path/to/roadmap")

  # Get the priority order of planned items
  {:ok, items} = IndexManager.get_priority_order("/path/to/roadmap")
  ```
  """

  alias Arbor.Flow.ItemParser

  @priority_order [:critical, :high, :medium, :low, :someday]
  @priority_emoji %{
    critical: "🔴",
    high: "🟠",
    medium: "🟡",
    low: "🟢",
    someday: "⚪"
  }

  @type refresh_opts :: [
          stages: [atom()],
          stage_dirs: %{atom() => String.t()},
          completed_limit: non_neg_integer()
        ]

  @default_stage_dirs %{
    inbox: "0-inbox",
    brainstorming: "1-brainstorming",
    planned: "2-planned",
    in_progress: "3-in_progress",
    completed: "4-completed",
    installed: "5-installed",
    blocked: "6-blocked",
    discarded: "8-discarded"
  }

  @doc """
  Refresh the INDEX.md file by scanning directory contents.

  ## Options

  - `:stages` - List of stages to include (default: all)
  - `:stage_dirs` - Map of stage atoms to directory names
  - `:completed_limit` - Max completed items to show (default: 20)
  """
  @spec refresh(String.t(), refresh_opts()) :: :ok | {:error, term()}
  def refresh(base_path, opts \\ []) do
    stage_dirs = Keyword.get(opts, :stage_dirs, @default_stage_dirs)
    completed_limit = Keyword.get(opts, :completed_limit, 20)

    # Scan each stage directory
    in_progress = scan_stage(base_path, stage_dirs[:in_progress])
    blocked = scan_stage(base_path, stage_dirs[:blocked])
    planned = scan_stage(base_path, stage_dirs[:planned])
    completed = scan_stage(base_path, stage_dirs[:completed]) |> Enum.take(completed_limit)
    installed = scan_stage(base_path, stage_dirs[:installed]) |> Enum.take(10)
    inbox = scan_stage(base_path, stage_dirs[:inbox])
    brainstorming = scan_stage(base_path, stage_dirs[:brainstorming])

    # Generate the index content
    content =
      generate_index_content(%{
        in_progress: in_progress,
        blocked: blocked,
        planned: planned,
        completed: completed,
        installed: installed,
        inbox: inbox,
        brainstorming: brainstorming,
        base_path: base_path
      })

    # Write the index file
    index_path = Path.join(base_path, "INDEX.md")
    File.write(index_path, content)
  end

  @doc """
  Get the priority-ordered list of planned items.

  Returns items from the planned stage, sorted by priority (critical first).
  """
  @spec get_priority_order(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def get_priority_order(base_path, opts \\ []) do
    stage_dirs = Keyword.get(opts, :stage_dirs, @default_stage_dirs)
    planned_dir = stage_dirs[:planned]

    case scan_stage(base_path, planned_dir) do
      items when is_list(items) ->
        sorted = sort_by_priority(items)
        {:ok, sorted}
    end
  end

  @doc """
  Get the next highest priority planned item.
  """
  @spec get_next_item(String.t(), keyword()) ::
          {:ok, map()} | {:error, :no_items}
  def get_next_item(base_path, opts \\ []) do
    {:ok, items} = get_priority_order(base_path, opts)

    case items do
      [item | _] -> {:ok, item}
      [] -> {:error, :no_items}
    end
  end

  @doc """
  Parse the INDEX.md file to extract the planned items in order.

  This is useful when the index has been manually edited and represents
  the authoritative order.
  """
  @spec parse_index(String.t()) :: {:ok, [map()]} | {:error, term()}
  def parse_index(base_path) do
    index_path = Path.join(base_path, "INDEX.md")

    case File.read(index_path) do
      {:ok, content} ->
        items = parse_planned_section(content, base_path)
        {:ok, items}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp scan_stage(_base_path, nil), do: []

  defp scan_stage(base_path, stage_dir) do
    full_path = Path.join(base_path, stage_dir)

    case File.ls(full_path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.reject(&(&1 == "INDEX.md"))
        |> Enum.map(&Path.join(full_path, &1))
        |> Enum.map(&ItemParser.parse_file/1)
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, item} -> item end)

      {:error, _} ->
        []
    end
  end

  defp sort_by_priority(items) do
    Enum.sort_by(items, fn item ->
      priority = item[:priority] || :medium
      priority_weight(priority)
    end)
  end

  defp priority_weight(:critical), do: 0
  defp priority_weight(:high), do: 1
  defp priority_weight(:medium), do: 2
  defp priority_weight(:low), do: 3
  defp priority_weight(:someday), do: 4
  defp priority_weight(_), do: 2

  defp generate_index_content(data) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    sections = [
      "# Workflow Index",
      "",
      "_Last updated: #{now}_",
      "",
      generate_active_section(data.in_progress, data.blocked, data.base_path),
      generate_planned_section(data.planned, data.base_path),
      generate_pipeline_section("Inbox", data.inbox, data.base_path),
      generate_pipeline_section("Brainstorming", data.brainstorming, data.base_path),
      generate_completed_section(data.completed, data.installed, data.base_path)
    ]

    sections
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp generate_active_section(in_progress, blocked, base_path) do
    [
      "## Active Work",
      "",
      "### In Progress",
      format_item_list(in_progress, base_path),
      "",
      "### Blocked",
      format_item_list(blocked, base_path),
      ""
    ]
  end

  defp generate_planned_section(items, base_path) do
    grouped = Enum.group_by(items, fn item -> item[:priority] || :medium end)

    sections =
      @priority_order
      |> Enum.flat_map(fn priority ->
        priority_items = Map.get(grouped, priority, [])
        header = priority_header(priority)

        [
          "### #{header}",
          format_item_list(priority_items, base_path),
          ""
        ]
      end)

    ["## Planned", "" | sections]
  end

  defp generate_pipeline_section(name, items, base_path) do
    [
      "## #{name}",
      "",
      format_item_list(items, base_path),
      ""
    ]
  end

  defp generate_completed_section(completed, installed, base_path) do
    [
      "## Recently Completed",
      "",
      format_completed_list(completed, base_path),
      "",
      "## Recently Installed",
      "",
      format_completed_list(installed, base_path),
      ""
    ]
  end

  defp format_item_list([], _base_path), do: "_None_"

  defp format_item_list(items, base_path) do
    items
    |> Enum.map(&format_item_line(&1, base_path))
    |> Enum.join("\n")
  end

  defp format_item_line(item, base_path) do
    emoji = @priority_emoji[item[:priority]] || "🟡"
    title = item[:title] || "Untitled"
    relative_path = relative_path(item[:path], base_path)
    summary = truncate_summary(item[:summary])

    if summary do
      "- #{emoji} **[#{title}](#{relative_path})** - #{summary}"
    else
      "- #{emoji} **[#{title}](#{relative_path})**"
    end
  end

  defp format_completed_list([], _base_path), do: "_None_"

  defp format_completed_list(items, base_path) do
    items
    |> Enum.map(&format_completed_line(&1, base_path))
    |> Enum.join("\n")
  end

  defp format_completed_line(item, base_path) do
    title = item[:title] || "Untitled"
    relative_path = relative_path(item[:path], base_path)
    date = format_date(item[:created_at])

    "- ✅ **[#{title}](#{relative_path})**#{date}"
  end

  defp format_date(nil), do: ""
  defp format_date(%Date{} = date), do: " - #{Date.to_iso8601(date)}"
  defp format_date(_), do: ""

  defp relative_path(nil, _base), do: ""

  defp relative_path(path, base) do
    Path.relative_to(path, base)
  end

  defp truncate_summary(nil), do: nil
  defp truncate_summary(""), do: nil

  defp truncate_summary(summary) do
    summary
    |> String.split(~r/[.!?]\s/, parts: 2)
    |> List.first()
    |> String.slice(0, 100)
    |> String.trim()
  end

  defp priority_header(:critical), do: "Critical"
  defp priority_header(:high), do: "High Priority"
  defp priority_header(:medium), do: "Medium Priority"
  defp priority_header(:low), do: "Low Priority"
  defp priority_header(:someday), do: "Someday"

  defp parse_planned_section(content, base_path) do
    # Look for the "## Planned" section
    case extract_section(content, "## Planned") do
      nil ->
        []

      section ->
        parse_item_links(section, base_path)
    end
  end

  defp extract_section(content, header) do
    pattern = ~r/#{Regex.escape(header)}\s*\n(.*?)(?=\n##\s|\z)/s

    case Regex.run(pattern, content) do
      [_, section] -> String.trim(section)
      nil -> nil
    end
  end

  defp parse_item_links(section, base_path) do
    # Parse lines like: - 🟡 **[Title](path)** - Description
    # Note: /u flag required for Unicode emoji matching
    Regex.scan(
      ~r/- (?:([🔴🟠🟡🟢⚪✅])\s+)?\*\*\[([^\]]+)\]\(([^)]+)\)\*\*(?:\s*-\s*(.+))?/u,
      section
    )
    |> Enum.map(fn
      [_, emoji, title, path | rest] ->
        description = List.first(rest)
        full_path = Path.join(base_path, path)

        %{
          priority: emoji_to_priority(emoji),
          title: title,
          path: full_path,
          description: description && String.trim(description)
        }
    end)
  end

  defp emoji_to_priority("🔴"), do: :critical
  defp emoji_to_priority("🟠"), do: :high
  defp emoji_to_priority("🟡"), do: :medium
  defp emoji_to_priority("🟢"), do: :low
  defp emoji_to_priority("⚪"), do: :someday
  defp emoji_to_priority(_), do: :medium
end
