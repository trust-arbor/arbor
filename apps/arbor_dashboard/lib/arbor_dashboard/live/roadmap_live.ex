defmodule Arbor.Dashboard.Live.RoadmapLive do
  @moduledoc """
  SDLC pipeline roadmap dashboard.

  Shows a kanban-style view of roadmap items across pipeline stages,
  with priority badges, category labels, and detail modals.
  """

  use Phoenix.LiveView

  import Arbor.Web.Components

  alias Arbor.SDLC.{Config, Pipeline}
  alias Arbor.Web.Helpers

  @impl true
  def mount(_params, _session, socket) do
    subscription_id =
      if connected?(socket) do
        safe_subscribe()
      end

    stages = safe_stages()
    items_by_stage = safe_load_items(stages)
    status = safe_status()
    total = items_by_stage |> Map.values() |> List.flatten() |> length()

    socket =
      socket
      |> assign(
        page_title: "Roadmap",
        stages: stages,
        items_by_stage: items_by_stage,
        selected_item: nil,
        pipeline_status: status,
        total_items: total,
        subscription_id: subscription_id
      )

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if sub_id = socket.assigns[:subscription_id] do
      try do
        Arbor.Signals.unsubscribe(sub_id)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  @impl true
  def handle_info({:signal_received, _signal}, socket) do
    stages = socket.assigns.stages
    items_by_stage = safe_load_items(stages)
    status = safe_status()
    total = items_by_stage |> Map.values() |> List.flatten() |> length()

    socket =
      socket
      |> assign(:items_by_stage, items_by_stage)
      |> assign(:pipeline_status, status)
      |> assign(:total_items, total)

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select-item", %{"path" => path}, socket) do
    item = find_item_by_path(socket.assigns.items_by_stage, path)
    {:noreply, assign(socket, :selected_item, item)}
  end

  def handle_event("close-detail", _params, socket) do
    {:noreply, assign(socket, :selected_item, nil)}
  end

  def handle_event("refresh", _params, socket) do
    stages = socket.assigns.stages
    items_by_stage = safe_load_items(stages)
    status = safe_status()
    total = items_by_stage |> Map.values() |> List.flatten() |> length()

    socket =
      socket
      |> assign(:items_by_stage, items_by_stage)
      |> assign(:pipeline_status, status)
      |> assign(:total_items, total)

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header title="Roadmap" subtitle="SDLC pipeline">
      <:actions>
        <button phx-click="refresh" class="aw-btn aw-btn-default">
          Refresh
        </button>
      </:actions>
    </.dashboard_header>

    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 1rem; margin-top: 1rem;">
      <.stat_card value={@total_items} label="Total items" color={:blue} />
      <.stat_card
        value={if @pipeline_status[:healthy], do: "Healthy", else: "Degraded"}
        label="Pipeline"
        color={if @pipeline_status[:healthy], do: :green, else: :error}
      />
    </div>

    <div style="display: flex; overflow-x: auto; gap: 1rem; margin-top: 1.5rem; padding-bottom: 1rem;">
      <div
        :for={stage <- @stages}
        style="min-width: 260px; max-width: 320px; flex-shrink: 0;"
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
            <div style="display: flex; gap: 0.25rem; flex-wrap: wrap;">
              <.badge label={to_string(item.priority)} color={priority_color(item.priority)} />
              <.badge label={to_string(item.category)} color={:gray} />
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
          <div>
            <strong>Priority:</strong>
            <.badge
              label={to_string(@selected_item.priority)}
              color={priority_color(@selected_item.priority)}
            />
          </div>
          <div>
            <strong>Category:</strong>
            <.badge label={to_string(@selected_item.category)} color={:gray} />
          </div>
          <div>
            <strong>Effort:</strong>
            <span>{@selected_item.effort}</span>
          </div>
          <div :if={@selected_item.id}>
            <strong>ID:</strong>
            <code style="font-size: 0.85em;">{@selected_item.id}</code>
          </div>
        </div>

        <div :if={@selected_item.summary} style="margin-top: 1rem;">
          <strong>Summary:</strong>
          <p style="margin-top: 0.5rem; color: var(--aw-text-muted, #888);">
            {@selected_item.summary}
          </p>
        </div>

        <div :if={@selected_item.why_it_matters} style="margin-top: 1rem;">
          <strong>Why It Matters:</strong>
          <p style="margin-top: 0.5rem; color: var(--aw-text-muted, #888);">
            {@selected_item.why_it_matters}
          </p>
        </div>

        <div :if={@selected_item.acceptance_criteria != []} style="margin-top: 1rem;">
          <strong>Acceptance Criteria:</strong>
          <ul style="margin-top: 0.5rem; padding-left: 1.5rem;">
            <li :for={criterion <- @selected_item.acceptance_criteria} style="margin-bottom: 0.25rem;">
              <span :if={criterion[:completed]} style="color: var(--aw-green, #4caf50);">
                &#10003;
              </span>
              <span :if={!criterion[:completed]} style="color: var(--aw-text-muted, #888);">
                &#9744;
              </span>
              {criterion[:text]}
            </li>
          </ul>
        </div>

        <div :if={@selected_item.definition_of_done != []} style="margin-top: 1rem;">
          <strong>Definition of Done:</strong>
          <ul style="margin-top: 0.5rem; padding-left: 1.5rem;">
            <li :for={dod <- @selected_item.definition_of_done} style="margin-bottom: 0.25rem;">
              <span :if={dod[:completed]} style="color: var(--aw-green, #4caf50);">&#10003;</span>
              <span :if={!dod[:completed]} style="color: var(--aw-text-muted, #888);">&#9744;</span>
              {dod[:text]}
            </li>
          </ul>
        </div>

        <div :if={@selected_item.related_files != []} style="margin-top: 1rem;">
          <strong>Related Files:</strong>
          <ul style="margin-top: 0.5rem; padding-left: 1.5rem; font-size: 0.85em;">
            <li :for={file <- @selected_item.related_files} style="margin-bottom: 0.25rem;">
              <code>{file}</code>
            </li>
          </ul>
        </div>

        <div :if={@selected_item.notes} style="margin-top: 1rem;">
          <strong>Notes:</strong>
          <p style="margin-top: 0.5rem; color: var(--aw-text-muted, #888); white-space: pre-wrap; font-size: 0.9em;">
            {@selected_item.notes}
          </p>
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
  defp stage_label(:discarded), do: "Discarded"
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

  # ── Safe API wrappers ───────────────────────────────────────────────

  defp safe_stages do
    Pipeline.stages()
  rescue
    _ -> [:inbox, :brainstorming, :planned, :in_progress, :completed, :discarded]
  catch
    :exit, _ -> [:inbox, :brainstorming, :planned, :in_progress, :completed, :discarded]
  end

  defp safe_load_items(stages) do
    roadmap_root = safe_roadmap_root()

    if roadmap_root do
      Map.new(stages, fn stage ->
        items = safe_stage_items(stage, roadmap_root)
        {stage, items}
      end)
    else
      Map.new(stages, &{&1, []})
    end
  end

  defp safe_stage_items(stage, roadmap_root) do
    dir = Pipeline.stage_path(stage, roadmap_root)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&(String.ends_with?(&1, ".md") and &1 != "INDEX.md"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.map(&safe_parse_file/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_parse_file(path) do
    case Arbor.SDLC.parse_file(path) do
      {:ok, item} -> item
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_roadmap_root do
    Config.absolute_roadmap_root()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_status do
    Arbor.SDLC.status()
  rescue
    _ -> %{healthy: false}
  catch
    :exit, _ -> %{healthy: false}
  end

  defp safe_subscribe do
    pid = self()

    case Arbor.Signals.subscribe("sdlc.*", fn signal ->
           send(pid, {:signal_received, signal})
           :ok
         end) do
      {:ok, id} -> id
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
