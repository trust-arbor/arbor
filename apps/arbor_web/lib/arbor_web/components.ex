defmodule Arbor.Web.Components do
  @moduledoc """
  Shared Phoenix function components for Arbor dashboards.

  All components use the `aw-` CSS class prefix and are designed to work
  with the Arbor.Web theme system. Import this module in your LiveViews:

      import Arbor.Web.Components
  """

  use Phoenix.Component

  alias Arbor.Web.Theme

  # ── stat_card ──────────────────────────────────────────────────────

  @doc """
  Renders a stat card with a value, label, and optional color accent.

  ## Attributes

    * `value` - The stat value to display (required)
    * `label` - The label below the value (required)
    * `color` - Color name or status atom for accent (default: :blue)
    * `trend` - Optional trend text (e.g., "+12%")
    * `class` - Additional CSS classes

  ## Examples

      <.stat_card value="42" label="Active agents" />
      <.stat_card value="99.9%" label="Uptime" color={:green} trend="+0.1%" />
  """
  attr :value, :any, required: true
  attr :label, :string, required: true
  attr :color, :atom, default: :blue
  attr :trend, :string, default: nil
  attr :class, :string, default: nil

  def stat_card(assigns) do
    assigns = assign(assigns, :border_class, Theme.border_class(assigns.color))
    assigns = assign(assigns, :text_class, Theme.text_class(assigns.color))

    ~H"""
    <div class={["aw-stat-card", @border_class, @class]}>
      <div class={["aw-stat-value", @text_class]}>
        <%= @value %>
        <span :if={@trend} class="aw-stat-trend"><%= @trend %></span>
      </div>
      <div class="aw-stat-label"><%= @label %></div>
    </div>
    """
  end

  # ── event_card ─────────────────────────────────────────────────────

  @doc """
  Renders an event card with icon, content, and timestamp.

  ## Attributes

    * `icon` - Icon text/emoji to display (required)
    * `title` - Event title (required)
    * `subtitle` - Secondary text (optional)
    * `timestamp` - Timestamp display string (optional)
    * `class` - Additional CSS classes

  ## Examples

      <.event_card icon="🧠" title="Agent thinking" subtitle="agent_1" timestamp="2m ago" />
  """
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :timestamp, :string, default: nil
  attr :class, :string, default: nil

  def event_card(assigns) do
    ~H"""
    <div class={["aw-event-card", @class]}>
      <div class="aw-event-icon"><%= @icon %></div>
      <div class="aw-event-content">
        <span class="aw-event-title"><%= @title %></span>
        <span :if={@subtitle} class="aw-event-subtitle"><%= @subtitle %></span>
      </div>
      <span :if={@timestamp} class="aw-event-time"><%= @timestamp %></span>
    </div>
    """
  end

  # ── badge ──────────────────────────────────────────────────────────

  @doc """
  Renders a status/category badge.

  ## Attributes

    * `label` - Badge text (required)
    * `color` - Color name or status atom (default: :gray)
    * `class` - Additional CSS classes

  ## Examples

      <.badge label="Running" color={:green} />
      <.badge label="Error" color={:error} />
  """
  attr :label, :string, required: true
  attr :color, :atom, default: :gray
  attr :class, :string, default: nil

  def badge(assigns) do
    assigns = assign(assigns, :color_class, Theme.bg_class(assigns.color))

    ~H"""
    <span class={["aw-badge", @color_class, @class]}>
      <%= @label %>
    </span>
    """
  end

  # ── modal ──────────────────────────────────────────────────────────

  @doc """
  Renders a modal dialog with overlay.

  ## Attributes

    * `id` - Unique modal ID (required)
    * `show` - Whether the modal is visible (default: false)
    * `title` - Modal title (optional)
    * `on_cancel` - JS command on cancel/close (optional)

  ## Slots

    * `inner_block` - Modal body content

  ## Examples

      <.modal id="confirm-dialog" show={@show_modal} title="Confirm Action">
        <p>Are you sure?</p>
      </.modal>
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :title, :string, default: nil
  attr :on_cancel, Phoenix.LiveView.JS, default: %Phoenix.LiveView.JS{}

  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      :if={@show}
      id={@id}
      class="aw-modal-overlay"
      phx-click={@on_cancel}
    >
      <div class="aw-modal" phx-click-away={@on_cancel}>
        <div :if={@title} class="aw-modal-header">
          <h3><%= @title %></h3>
          <button type="button" class="aw-modal-close" phx-click={@on_cancel}>
            &times;
          </button>
        </div>
        <div class="aw-modal-body">
          <%= render_slot(@inner_block) %>
        </div>
      </div>
    </div>
    """
  end

  # ── dashboard_header ───────────────────────────────────────────────

  @doc """
  Renders a dashboard page header with title, subtitle, and optional action slot.

  ## Attributes

    * `title` - Page title (required)
    * `subtitle` - Subtitle text (optional)

  ## Slots

    * `actions` - Right-aligned action buttons/controls

  ## Examples

      <.dashboard_header title="Consensus Dashboard" subtitle="Multi-perspective deliberation">
        <:actions>
          <button>Refresh</button>
        </:actions>
      </.dashboard_header>
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil

  slot :actions

  def dashboard_header(assigns) do
    ~H"""
    <div class="aw-dashboard-header">
      <div class="aw-dashboard-header-text">
        <h1 class="aw-dashboard-title"><%= @title %></h1>
        <p :if={@subtitle} class="aw-dashboard-subtitle"><%= @subtitle %></p>
      </div>
      <div :if={@actions != []} class="aw-dashboard-actions">
        <%= render_slot(@actions) %>
      </div>
    </div>
    """
  end

  # ── filter_bar ─────────────────────────────────────────────────────

  @doc """
  Renders a filter controls row.

  ## Slots

    * `inner_block` - Filter controls (dropdowns, inputs, buttons)

  ## Examples

      <.filter_bar>
        <select><option>All</option></select>
        <input type="text" placeholder="Search..." />
      </.filter_bar>
  """
  attr :class, :string, default: nil

  slot :inner_block, required: true

  def filter_bar(assigns) do
    ~H"""
    <div class={["aw-filter-bar", @class]}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  # ── flash_group ────────────────────────────────────────────────────

  @doc """
  Renders flash messages for info, error, and warning kinds.

  ## Attributes

    * `flash` - The flash map from the socket (required)

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div class="aw-flash-group">
      <.flash_message :for={kind <- [:info, :error, :warning]} kind={kind} flash={@flash} />
    </div>
    """
  end

  attr :flash, :map, required: true
  attr :kind, :atom, required: true

  defp flash_message(assigns) do
    ~H"""
    <div
      :if={msg = Phoenix.Flash.get(@flash, @kind)}
      class={"aw-flash aw-flash-#{@kind}"}
      role="alert"
    >
      <p><%= msg %></p>
      <button type="button" class="aw-flash-close" aria-label="close">
        &times;
      </button>
    </div>
    """
  end

  # ── empty_state ────────────────────────────────────────────────────

  @doc """
  Renders a placeholder for empty data states.

  ## Attributes

    * `icon` - Icon/emoji to display (default: "📭")
    * `title` - Main message (required)
    * `hint` - Secondary hint text (optional)

  ## Examples

      <.empty_state title="No events yet" hint="Events will appear here as they occur." />
  """
  attr :icon, :string, default: "📭"
  attr :title, :string, required: true
  attr :hint, :string, default: nil

  def empty_state(assigns) do
    ~H"""
    <div class="aw-empty-state">
      <div class="aw-empty-icon"><%= @icon %></div>
      <p class="aw-empty-title"><%= @title %></p>
      <p :if={@hint} class="aw-empty-hint"><%= @hint %></p>
    </div>
    """
  end

  # ── loading_spinner ────────────────────────────────────────────────

  @doc """
  Renders a loading indicator.

  ## Attributes

    * `label` - Loading text (default: "Loading...")
    * `class` - Additional CSS classes

  ## Examples

      <.loading_spinner />
      <.loading_spinner label="Fetching data..." />
  """
  attr :label, :string, default: "Loading..."
  attr :class, :string, default: nil

  def loading_spinner(assigns) do
    ~H"""
    <div class={["aw-loading", @class]}>
      <div class="aw-spinner"></div>
      <span class="aw-loading-label"><%= @label %></span>
    </div>
    """
  end

  # ── card ───────────────────────────────────────────────────────────

  @doc """
  Renders a generic card wrapper.

  ## Attributes

    * `title` - Optional card title
    * `class` - Additional CSS classes
    * `padding` - Whether to add padding (default: true)

  ## Slots

    * `inner_block` - Card content
    * `header_actions` - Actions in the card header

  ## Examples

      <.card title="Recent Events">
        <ul>...</ul>
      </.card>
  """
  attr :title, :string, default: nil
  attr :class, :string, default: nil
  attr :padding, :boolean, default: true

  slot :inner_block, required: true
  slot :header_actions

  def card(assigns) do
    ~H"""
    <div class={["aw-card", @class]}>
      <div :if={@title || @header_actions != []} class="aw-card-header">
        <h3 :if={@title} class="aw-card-title"><%= @title %></h3>
        <div :if={@header_actions != []} class="aw-card-actions">
          <%= render_slot(@header_actions) %>
        </div>
      </div>
      <div class={if @padding, do: "aw-card-body", else: "aw-card-body-flush"}>
        <%= render_slot(@inner_block) %>
      </div>
    </div>
    """
  end

  # ── nav_link ───────────────────────────────────────────────────────

  @doc """
  Renders a navigation link with active state detection.

  ## Attributes

    * `href` - Link destination (required)
    * `active` - Whether this link is active (default: false)
    * `label` - Link text (required)
    * `icon` - Optional icon text/emoji
    * `class` - Additional CSS classes

  ## Examples

      <.nav_link href="/dashboard" label="Dashboard" active={@current_path == "/dashboard"} />
      <.nav_link href="/events" label="Events" icon="📡" />
  """
  attr :href, :string, required: true
  attr :active, :boolean, default: false
  attr :label, :string, required: true
  attr :icon, :string, default: nil
  attr :class, :string, default: nil

  def nav_link(assigns) do
    ~H"""
    <a href={@href} class={["aw-nav-link", @active && "aw-nav-active", @class]}>
      <span :if={@icon} class="aw-nav-icon"><%= @icon %></span>
      <%= @label %>
    </a>
    """
  end
end
