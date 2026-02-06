defmodule Arbor.Dashboard.Components.ProposalDiff do
  @moduledoc """
  Component for displaying code diff in proposal visualization.

  Shows proposed code changes with syntax highlighting (basic: +green, -red).
  Includes module name, change type header, and expandable evidence/rationale section.
  """

  use Phoenix.Component

  @doc """
  Renders a proposal diff view.

  ## Attributes

    * `proposal` - The proposal map containing change information (required)
    * `expanded` - Whether the evidence section is expanded (default: false)
    * `id` - Unique identifier for the component (default: "proposal-diff")

  ## Expected proposal structure

      %{
        target_module: Arbor.Demo.Faults.Flood,
        change_type: :fix,
        diff_lines: [
          %{type: :context, content: "def flood_loop(interval, batch) do"},
          %{type: :add, content: "  if Process.info(self(), :message_queue_len) > 1000, do: :stop"},
          %{type: :context, content: "  for _ <- 1..batch do"}
        ],
        evidence: "Message queue overflow detected...",
        rationale: "Adding backpressure check to prevent..."
      }
  """
  attr :proposal, :map, required: true
  attr :expanded, :boolean, default: false
  attr :id, :string, default: "proposal-diff"
  attr :on_toggle, :any, default: nil

  def proposal_diff(assigns) do
    assigns =
      assigns
      |> assign_new(:module_name, fn -> extract_module_name(assigns.proposal) end)
      |> assign_new(:change_type, fn ->
        get_in(assigns.proposal, [:change_type]) || :modification
      end)
      |> assign_new(:diff_lines, fn -> get_in(assigns.proposal, [:diff_lines]) || [] end)
      |> assign_new(:evidence, fn -> extract_evidence(assigns.proposal) end)
      |> assign_new(:rationale, fn -> extract_rationale(assigns.proposal) end)

    ~H"""
    <div class="aw-diff" id={@id}>
      <div class="aw-diff-header">
        <div class="aw-diff-title">
          <span>{change_icon(@change_type)}</span>
          <span>{@module_name}</span>
        </div>
        <div class="aw-diff-meta">
          {format_change_type(@change_type)}
        </div>
      </div>

      <div class="aw-diff-body">
        <%= if @diff_lines == [] do %>
          <div class="aw-diff-line aw-diff-context" style="padding: 1rem; text-align: center;">
            No diff available
          </div>
        <% else %>
          <%= for line <- @diff_lines do %>
            <div class={"aw-diff-line #{line_class(line)}"}>
              {line_prefix(line)}{line_content(line)}
            </div>
          <% end %>
        <% end %>
      </div>

      <%= if @evidence || @rationale do %>
        <div class="aw-diff-expand">
          <%= if @expanded do %>
            <div style="margin-bottom: 0.5rem;">
              <%= if @evidence do %>
                <div style="margin-bottom: 0.5rem;">
                  <strong style="color: var(--aw-text-secondary); font-size: 0.7rem; text-transform: uppercase;">
                    Evidence
                  </strong>
                  <div style="color: var(--aw-text-primary); font-size: 0.8rem; margin-top: 0.25rem;">
                    {@evidence}
                  </div>
                </div>
              <% end %>
              <%= if @rationale do %>
                <div>
                  <strong style="color: var(--aw-text-secondary); font-size: 0.7rem; text-transform: uppercase;">
                    Rationale
                  </strong>
                  <div style="color: var(--aw-text-primary); font-size: 0.8rem; margin-top: 0.25rem;">
                    {@rationale}
                  </div>
                </div>
              <% end %>
            </div>
            <button type="button" class="aw-diff-expand-btn" phx-click={@on_toggle} phx-value-id={@id}>
              Hide details
            </button>
          <% else %>
            <button type="button" class="aw-diff-expand-btn" phx-click={@on_toggle} phx-value-id={@id}>
              Show evidence & rationale
            </button>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp change_icon(:fix), do: "🔧"
  defp change_icon(:add), do: "➕"
  defp change_icon(:remove), do: "➖"
  defp change_icon(:refactor), do: "🔄"
  defp change_icon(_), do: "📝"

  defp format_change_type(:fix), do: "Bug Fix"
  defp format_change_type(:add), do: "Addition"
  defp format_change_type(:remove), do: "Removal"
  defp format_change_type(:refactor), do: "Refactor"
  defp format_change_type(:modification), do: "Modification"
  defp format_change_type(type) when is_atom(type), do: type |> to_string() |> String.capitalize()
  defp format_change_type(type) when is_binary(type), do: String.capitalize(type)
  defp format_change_type(_), do: "Change"

  defp line_class(%{type: :add}), do: "aw-diff-add"
  defp line_class(%{type: :remove}), do: "aw-diff-remove"
  defp line_class(%{type: :context}), do: "aw-diff-context"
  defp line_class(_), do: "aw-diff-context"

  defp line_prefix(%{type: :add}), do: "+ "
  defp line_prefix(%{type: :remove}), do: "- "
  defp line_prefix(_), do: "  "

  defp line_content(%{content: content}), do: content
  defp line_content(line) when is_binary(line), do: line
  defp line_content(_), do: ""

  defp extract_module_name(proposal) do
    case get_in(proposal, [:target_module]) do
      nil -> "Unknown Module"
      mod when is_atom(mod) -> inspect(mod)
      mod when is_binary(mod) -> mod
      _ -> "Unknown Module"
    end
  end

  defp extract_evidence(proposal) do
    get_in(proposal, [:evidence]) || get_in(proposal, [:context, :evidence])
  end

  defp extract_rationale(proposal) do
    get_in(proposal, [:rationale]) ||
      get_in(proposal, [:context, :rationale]) ||
      get_in(proposal, [:description])
  end
end
