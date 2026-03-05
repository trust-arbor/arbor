defmodule Arbor.Dashboard.Live.RoadmapLive do
  @moduledoc """
  Roadmap dashboard.

  Shows a kanban-style view of roadmap items across pipeline stages,
  with priority badges, category labels, and detail modals.
  Reads directly from `.arbor/roadmap/` markdown files.
  """

  use Phoenix.LiveView
  use Arbor.Dashboard.Live.SignalSubscription

  import Arbor.Web.Components

  alias Arbor.Web.Helpers

  @stages [:inbox, :brainstorming, :planned, :in_progress, :completed]
  @stage_dirs %{
    inbox: "0-inbox",
    brainstorming: "1-brainstorming",
    planned: "2-planned",
    in_progress: "3-in-progress",
    completed: "5-completed"
  }

  @impl true
  def mount(_params, _session, socket) do
    items_by_stage = load_items()
    total = items_by_stage |> Map.values() |> List.flatten() |> length()

    socket =
      socket
      |> assign(
        page_title: "Roadmap",
        stages: @stages,
        items_by_stage: items_by_stage,
        selected_item: nil,
        total_items: total
      )

    socket = subscribe_signals(socket, "sdlc.*", &reload_roadmap/1)

    {:ok, socket}
  end

  defp reload_roadmap(socket) do
    items_by_stage = load_items()
    total = items_by_stage |> Map.values() |> List.flatten() |> length()

    assign(socket,
      items_by_stage: items_by_stage,
      total_items: total
    )
  end

  @impl true
  def handle_event("select-item", %{"path" => path}, socket) do
    item = find_item_by_path(socket.assigns.items_by_stage, path)
    {:noreply, assign(socket, :selected_item, item)}
  end

  def handle_event("close-detail", _params, socket) do
    {:noreply, assign(socket, :selected_item, nil)}
  end

  def handle_event("refresh", _params, socket) do
    items_by_stage = load_items()
    total = items_by_stage |> Map.values() |> List.flatten() |> length()

    socket =
      socket
      |> assign(:items_by_stage, items_by_stage)
      |> assign(:total_items, total)

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header title="Roadmap" subtitle="Pipeline stages">
      <:actions>
        <button phx-click="refresh" class="aw-btn aw-btn-default">
          Refresh
        </button>
      </:actions>
    </.dashboard_header>

    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 1rem; margin-top: 1rem;">
      <.stat_card value={@total_items} label="Total items" color={:blue} />
    </div>

    <div style="display: flex; overflow-x: auto; gap: 1rem; margin-top: 1rem; padding-bottom: 1rem;">
      <div
        :for={stage <- @stages}
        style="min-width: 200px; width: 20%; flex-shrink: 0;"
      >
        <div style="display: flex; align-items: center; gap: 0.5rem; margin-bottom: 0.75rem; padding: 0.5rem; background: var(--aw-bg-secondary, #1a1a1a); border-radius: 4px;">
          <strong>{stage_label(stage)}</strong>
          <.badge label={to_string(length(Map.get(@items_by_stage, stage, [])))} color={:gray} />
        </div>

        <div style="display: flex; flex-direction: column; gap: 0.5rem;">
          <div
            :for={item <- Map.get(@items_by_stage, stage, [])}
            phx-click="select-item"
            phx-value-path={item.path}
            style="border: 1px solid var(--aw-border, #333); border-radius: 4px; padding: 0.75rem; cursor: pointer; background: var(--aw-bg-primary, #111);"
          >
            <div style="font-weight: 600; margin-bottom: 0.5rem; font-size: 0.9em;">
              {Helpers.truncate(item.title, 60)}
            </div>
            <div
              :if={item.priority || item.category}
              style="display: flex; gap: 0.25rem; flex-wrap: wrap;"
            >
              <.badge
                :if={item.priority}
                label={to_string(item.priority)}
                color={priority_color(item.priority)}
              />
              <.badge :if={item.category} label={to_string(item.category)} color={:gray} />
            </div>
          </div>
        </div>

        <div
          :if={Map.get(@items_by_stage, stage, []) == []}
          style="padding: 1rem; text-align: center; color: var(--aw-text-muted, #888); font-size: 0.85em; border: 1px dashed var(--aw-border, #333); border-radius: 4px;"
        >
          No items
        </div>
      </div>
    </div>

    <.modal
      :if={@selected_item}
      id="item-detail"
      show={@selected_item != nil}
      title={@selected_item.title}
      on_cancel={Phoenix.LiveView.JS.push("close-detail")}
    >
      <div class="aw-item-detail">
        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 0.75rem; margin-bottom: 1rem;">
          <div :if={@selected_item.priority}>
            <strong>Priority:</strong>
            <.badge
              label={to_string(@selected_item.priority)}
              color={priority_color(@selected_item.priority)}
            />
          </div>
          <div :if={@selected_item.category}>
            <strong>Category:</strong>
            <.badge label={to_string(@selected_item.category)} color={:gray} />
          </div>
          <div :if={@selected_item.effort}>
            <strong>Effort:</strong>
            <span>{@selected_item.effort}</span>
          </div>
        </div>

        <div :if={@selected_item[:summary]} style="margin-top: 1rem;">
          <strong>Summary:</strong>
          <p style="margin-top: 0.5rem; color: var(--aw-text-muted, #888);">
            {@selected_item.summary}
          </p>
        </div>

        <div :if={@selected_item[:content]} style="margin-top: 1rem;">
          <strong>Content:</strong>
          <pre style="margin-top: 0.5rem; color: var(--aw-text-muted, #888); white-space: pre-wrap; font-size: 0.9em;">
            {@selected_item.content}
          </pre>
        </div>
      </div>
    </.modal>
    """
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp stage_label(:inbox), do: "Inbox"
  defp stage_label(:brainstorming), do: "Brainstorming"
  defp stage_label(:planned), do: "Planned"
  defp stage_label(:in_progress), do: "In Progress"
  defp stage_label(:completed), do: "Completed"
  defp stage_label(stage), do: stage |> to_string() |> String.capitalize()

  defp priority_color(:critical), do: :error
  defp priority_color(:high), do: :purple
  defp priority_color(:medium), do: :blue
  defp priority_color(:low), do: :gray
  defp priority_color(:someday), do: :gray
  defp priority_color(_), do: :gray

  defp find_item_by_path(items_by_stage, path) do
    items_by_stage
    |> Map.values()
    |> List.flatten()
    |> Enum.find(&(&1.path == path))
  end

  # ── Data loading ───────────────────────────────────────────────────

  defp load_items do
    root = roadmap_root()

    Map.new(@stages, fn stage ->
      dir = Path.join(root, Map.fetch!(@stage_dirs, stage))
      items = load_stage_items(dir)
      {stage, items}
    end)
  rescue
    _ -> Map.new(@stages, &{&1, []})
  end

  defp load_stage_items(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&(String.ends_with?(&1, ".md") and &1 != "INDEX.md"))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.map(&parse_roadmap_file/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp parse_roadmap_file(path) do
    case File.read(path) do
      {:ok, content} ->
        metadata = parse_frontmatter(content)
        title = metadata[:title] || path |> Path.basename(".md") |> humanize_filename()

        %{
          path: path,
          title: title,
          priority: safe_atom(metadata[:priority]),
          category: safe_atom(metadata[:category]),
          effort: metadata[:effort],
          summary: metadata[:summary],
          content: content |> String.slice(0, 2000)
        }

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp parse_frontmatter(content) do
    lines = String.split(content, "\n")

    # Extract title from first markdown heading
    title =
      Enum.find_value(lines, fn line ->
        case Regex.run(~r/^#\s+(.+)$/, String.trim(line)) do
          [_, title] -> String.trim(title)
          _ -> nil
        end
      end)

    # Extract **Key:** Value patterns from content
    extract = fn key ->
      Enum.find_value(lines, fn line ->
        pattern = ~r/\*\*#{Regex.escape(key)}:\*\*\s*(.+)/i

        case Regex.run(pattern, String.trim(line)) do
          [_, value] -> String.trim(value)
          _ -> nil
        end
      end)
    end

    %{
      title: title,
      priority: extract.("Priority"),
      category: extract.("Category"),
      effort: extract.("Effort"),
      summary: extract.("Summary")
    }
  end

  defp humanize_filename(name) do
    name
    |> String.replace(~r/[-_]/, " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp safe_atom(nil), do: nil

  defp safe_atom(value) when is_binary(value) do
    value |> String.downcase() |> String.trim() |> String.to_existing_atom()
  rescue
    _ -> nil
  end

  defp roadmap_root do
    root = ".arbor/roadmap"

    if Path.type(root) == :absolute do
      root
    else
      Path.join(File.cwd!(), root)
    end
  end
end
