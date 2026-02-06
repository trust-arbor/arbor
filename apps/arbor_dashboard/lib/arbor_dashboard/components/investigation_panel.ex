defmodule Arbor.Dashboard.Components.InvestigationPanel do
  @moduledoc """
  Component for displaying investigation details in the self-healing demo.

  Shows hypothesis generation, symptoms, confidence levels, and thinking log.
  """

  use Phoenix.Component

  import Arbor.Web.Components, only: [badge: 1]

  @doc """
  Renders an investigation panel.

  ## Attributes

    * `investigation` - The investigation map from Investigation module (required)
    * `expanded` - Whether to show full thinking log (default: false)

  ## Expected investigation structure

      %{
        id: "inv_abc123",
        anomaly: %{skill: :processes, ...},
        symptoms: [%{type: :memory, value: 123, ...}],
        hypotheses: [%{cause: :message_flood, confidence: 0.9, ...}],
        selected_hypothesis: %{...},
        confidence: 0.85,
        thinking_log: ["Started investigation...", ...]
      }
  """
  attr :investigation, :map, required: true
  attr :expanded, :boolean, default: false
  attr :on_toggle, :any, default: nil

  def investigation_panel(assigns) do
    assigns =
      assigns
      |> assign_new(:hypothesis, fn -> assigns.investigation[:selected_hypothesis] end)
      |> assign_new(:symptoms, fn -> assigns.investigation[:symptoms] || [] end)
      |> assign_new(:thinking_log, fn -> assigns.investigation[:thinking_log] || [] end)

    ~H"""
    <div class="aw-investigation-panel">
      <%!-- Header with confidence --%>
      <div class="aw-investigation-header">
        <div style="display: flex; align-items: center; gap: 0.5rem;">
          <span style="font-size: 1.2rem;">🔬</span>
          <span style="font-weight: 600;">Investigation</span>
          <code style="font-size: 0.75rem; color: var(--aw-text-secondary);">
            {@investigation.id}
          </code>
        </div>
        <.badge
          label={"#{Float.round(@investigation.confidence * 100, 0)}% confident"}
          color={confidence_color(@investigation.confidence)}
        />
      </div>

      <%!-- Selected Hypothesis --%>
      <%= if @hypothesis do %>
        <div class="aw-investigation-section">
          <div class="aw-investigation-section-title">Hypothesis</div>
          <div class="aw-hypothesis-card">
            <div style="display: flex; justify-content: space-between; align-items: center;">
              <span style="font-weight: 600; color: var(--aw-text-primary);">
                {format_cause(@hypothesis.cause)}
              </span>
              <.badge
                label={format_action(@hypothesis.suggested_action)}
                color={:primary}
              />
            </div>
            <%= if @hypothesis[:evidence_chain] do %>
              <div style="font-size: 0.8rem; color: var(--aw-text-secondary); margin-top: 0.5rem;">
                <strong>Evidence:</strong>
                <ul style="margin: 0.25rem 0 0 1rem; padding: 0;">
                  <%= for evidence <- @hypothesis.evidence_chain do %>
                    <li>{evidence}</li>
                  <% end %>
                </ul>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <%!-- Symptoms --%>
      <%= if @symptoms != [] do %>
        <div class="aw-investigation-section">
          <div class="aw-investigation-section-title">
            Symptoms ({length(@symptoms)})
          </div>
          <div class="aw-symptoms-grid">
            <%= for symptom <- Enum.take(@symptoms, 6) do %>
              <div class="aw-symptom-card">
                <span class="aw-symptom-type">{symptom_icon(symptom.type)} {symptom.type}</span>
                <span class="aw-symptom-value">{format_symptom_value(symptom)}</span>
              </div>
            <% end %>
          </div>
          <%= if length(@symptoms) > 6 do %>
            <div style="font-size: 0.75rem; color: var(--aw-text-secondary); margin-top: 0.25rem;">
              +{length(@symptoms) - 6} more symptoms
            </div>
          <% end %>
        </div>
      <% end %>

      <%!-- Thinking Log --%>
      <%= if @thinking_log != [] do %>
        <div class="aw-investigation-section">
          <div class="aw-investigation-section-title">
            Thinking Log ({length(@thinking_log)} steps)
          </div>
          <div class="aw-thinking-log">
            <%= if @expanded do %>
              <%= for {entry, idx} <- Enum.with_index(@thinking_log) do %>
                <div class="aw-thinking-entry">
                  <span class="aw-thinking-step">{idx + 1}.</span>
                  <span>{entry}</span>
                </div>
              <% end %>
            <% else %>
              <%= for {entry, idx} <- Enum.take(@thinking_log, 3) |> Enum.with_index() do %>
                <div class="aw-thinking-entry">
                  <span class="aw-thinking-step">{idx + 1}.</span>
                  <span>{entry}</span>
                </div>
              <% end %>
              <%= if length(@thinking_log) > 3 do %>
                <button
                  :if={@on_toggle}
                  type="button"
                  class="aw-thinking-toggle"
                  phx-click={@on_toggle}
                >
                  Show {length(@thinking_log) - 3} more steps
                </button>
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp confidence_color(c) when c >= 0.8, do: :success
  defp confidence_color(c) when c >= 0.6, do: :warning
  defp confidence_color(_), do: :error

  defp format_cause(cause) when is_atom(cause) do
    cause
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_cause(cause) when is_binary(cause), do: String.capitalize(cause)
  defp format_cause(_), do: "Unknown Cause"

  defp format_action(action) when is_atom(action) do
    action
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp format_action(action) when is_binary(action), do: String.capitalize(action)
  defp format_action(_), do: "Investigate"

  defp symptom_icon(:memory), do: "💾"
  defp symptom_icon(:process_info), do: "🔍"
  defp symptom_icon(:scheduler), do: "⚙️"
  defp symptom_icon(:top_by_queue), do: "📬"
  defp symptom_icon(:top_by_memory), do: "📊"
  defp symptom_icon(:gc_stats), do: "🗑️"
  defp symptom_icon(_), do: "📋"

  defp format_symptom_value(%{value: value}) when is_number(value) do
    if value > 1_000_000 do
      "#{Float.round(value / 1_000_000, 1)}M"
    else
      "#{value}"
    end
  end

  defp format_symptom_value(%{value: value}) when is_map(value) do
    "#{map_size(value)} items"
  end

  defp format_symptom_value(%{value: value}) when is_list(value) do
    "#{length(value)} items"
  end

  defp format_symptom_value(_), do: "—"
end
