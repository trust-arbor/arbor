defmodule Arbor.Web.ComponentsTest do
  use ExUnit.Case, async: true

  import Arbor.Web.TestHelpers

  alias Arbor.Web.Components

  describe "stat_card/1" do
    test "renders value and label" do
      html = render_component(&Components.stat_card/1, %{value: "42", label: "Active agents"})
      assert html =~ "aw-stat-card"
      assert html =~ "42"
      assert html =~ "Active agents"
    end

    test "renders with color accent" do
      html = render_component(&Components.stat_card/1, %{value: "99%", label: "Uptime", color: :green})
      assert html =~ "aw-border-green"
      assert html =~ "aw-text-green"
    end

    test "renders with trend" do
      html = render_component(&Components.stat_card/1, %{value: "42", label: "Count", trend: "+12%"})
      assert html =~ "aw-stat-trend"
      assert html =~ "+12%"
    end

    test "omits trend when nil" do
      html = render_component(&Components.stat_card/1, %{value: "42", label: "Count"})
      refute html =~ "aw-stat-trend"
    end

    test "accepts custom class" do
      html = render_component(&Components.stat_card/1, %{value: "1", label: "Test", class: "my-class"})
      assert html =~ "my-class"
    end
  end

  describe "event_card/1" do
    test "renders icon, title, and timestamp" do
      html =
        render_component(&Components.event_card/1, %{
          icon: "🧠",
          title: "Agent thinking",
          timestamp: "2m ago"
        })

      assert html =~ "aw-event-card"
      assert html =~ "🧠"
      assert html =~ "Agent thinking"
      assert html =~ "2m ago"
    end

    test "renders with subtitle" do
      html =
        render_component(&Components.event_card/1, %{
          icon: "⚡",
          title: "Action",
          subtitle: "agent_1"
        })

      assert html =~ "aw-event-subtitle"
      assert html =~ "agent_1"
    end

    test "omits subtitle when nil" do
      html = render_component(&Components.event_card/1, %{icon: "•", title: "Test"})
      refute html =~ "aw-event-subtitle"
    end

    test "omits timestamp when nil" do
      html = render_component(&Components.event_card/1, %{icon: "•", title: "Test"})
      refute html =~ "aw-event-time"
    end
  end

  describe "badge/1" do
    test "renders label with default color" do
      html = render_component(&Components.badge/1, %{label: "Status"})
      assert html =~ "aw-badge"
      assert html =~ "Status"
      assert html =~ "aw-bg-gray"
    end

    test "renders with color" do
      html = render_component(&Components.badge/1, %{label: "Running", color: :green})
      assert html =~ "aw-bg-green"
    end

    test "maps status to color" do
      html = render_component(&Components.badge/1, %{label: "Error", color: :error})
      assert html =~ "aw-bg-red"
    end
  end

  describe "empty_state/1" do
    test "renders title and default icon" do
      html = render_component(&Components.empty_state/1, %{title: "No events yet"})
      assert html =~ "aw-empty-state"
      assert html =~ "No events yet"
      assert html =~ "📭"
    end

    test "renders with custom icon and hint" do
      html =
        render_component(&Components.empty_state/1, %{
          title: "Empty",
          icon: "🔍",
          hint: "Try searching."
        })

      assert html =~ "🔍"
      assert html =~ "Try searching."
      assert html =~ "aw-empty-hint"
    end

    test "omits hint when nil" do
      html = render_component(&Components.empty_state/1, %{title: "Empty"})
      refute html =~ "aw-empty-hint"
    end
  end

  describe "loading_spinner/1" do
    test "renders with default label" do
      html = render_component(&Components.loading_spinner/1, %{})
      assert html =~ "aw-loading"
      assert html =~ "aw-spinner"
      assert html =~ "Loading..."
    end

    test "renders with custom label" do
      html = render_component(&Components.loading_spinner/1, %{label: "Fetching data..."})
      assert html =~ "Fetching data..."
    end
  end

  describe "nav_link/1" do
    test "renders link with label" do
      html = render_component(&Components.nav_link/1, %{href: "/dashboard", label: "Dashboard"})
      assert html =~ "aw-nav-link"
      assert html =~ "href=\"/dashboard\""
      assert html =~ "Dashboard"
    end

    test "renders active state" do
      html =
        render_component(&Components.nav_link/1, %{
          href: "/events",
          label: "Events",
          active: true
        })

      assert html =~ "aw-nav-active"
    end

    test "renders with icon" do
      html =
        render_component(&Components.nav_link/1, %{
          href: "/events",
          label: "Events",
          icon: "📡"
        })

      assert html =~ "aw-nav-icon"
      assert html =~ "📡"
    end

    test "omits icon when nil" do
      html = render_component(&Components.nav_link/1, %{href: "/", label: "Home"})
      refute html =~ "aw-nav-icon"
    end
  end

  describe "flash_group/1" do
    test "renders flash group container" do
      html = render_component(&Components.flash_group/1, %{flash: %{}})
      assert html =~ "aw-flash-group"
    end

    test "renders info flash message" do
      html = render_component(&Components.flash_group/1, %{flash: %{"info" => "Success!"}})
      assert html =~ "aw-flash-info"
      assert html =~ "Success!"
    end

    test "renders error flash message" do
      html = render_component(&Components.flash_group/1, %{flash: %{"error" => "Something broke"}})
      assert html =~ "aw-flash-error"
      assert html =~ "Something broke"
    end
  end

  describe "dashboard_header/1" do
    test "renders title" do
      html = render_component(&Components.dashboard_header/1, %{title: "My Dashboard", actions: []})
      assert html =~ "aw-dashboard-header"
      assert html =~ "My Dashboard"
    end

    test "renders subtitle" do
      html =
        render_component(&Components.dashboard_header/1, %{
          title: "Dashboard",
          subtitle: "Overview",
          actions: []
        })

      assert html =~ "aw-dashboard-subtitle"
      assert html =~ "Overview"
    end

    test "omits subtitle when nil" do
      html = render_component(&Components.dashboard_header/1, %{title: "Dashboard", actions: []})
      refute html =~ "aw-dashboard-subtitle"
    end
  end
end
