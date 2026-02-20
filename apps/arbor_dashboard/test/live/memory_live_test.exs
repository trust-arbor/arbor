defmodule Arbor.Dashboard.Live.MemoryLiveTest do
  use Arbor.Dashboard.ConnCase, async: true

  @tag :fast
  describe "MemoryLive mount without agent_id" do
    @tag :fast
    test "renders memory viewer header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/memory")

      assert html =~ "Memory Viewer"
      assert html =~ "Select an agent to inspect"
    end

    @tag :fast
    test "shows agent selector card", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/memory")

      assert html =~ "Select Agent"
    end

    @tag :fast
    test "refresh without agent reloads agent list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/memory")

      html = render_click(view, "refresh")
      assert html =~ "Memory Viewer"
    end
  end

  @tag :fast
  describe "MemoryLive mount with agent_id" do
    @tag :fast
    test "renders memory viewer with agent context", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/memory/test-agent-123")

      assert html =~ "Memory Viewer"
      assert html =~ "test-agent-123"
    end

    @tag :fast
    test "shows tab bar with all tabs", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/memory/test-agent-123")

      assert html =~ "Working Memory"
      assert html =~ "Identity"
      assert html =~ "Goals"
      assert html =~ "Knowledge"
      assert html =~ "Preferences"
      assert html =~ "Proposals"
      assert html =~ "Code"
    end

    @tag :fast
    test "shows refresh button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/memory/test-agent-123")

      assert html =~ "Refresh"
    end
  end

  @tag :fast
  describe "MemoryLive tab navigation" do
    @tag :fast
    test "change-tab to identity", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/memory/test-agent-123")

      html = render_click(view, "change-tab", %{"tab" => "identity"})
      assert is_binary(html)
    end

    @tag :fast
    test "change-tab to goals", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/memory/test-agent-123")

      html = render_click(view, "change-tab", %{"tab" => "goals"})
      assert is_binary(html)
    end

    @tag :fast
    test "change-tab to knowledge", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/memory/test-agent-123")

      html = render_click(view, "change-tab", %{"tab" => "knowledge"})
      assert is_binary(html)
    end

    @tag :fast
    test "change-tab to working_memory", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/memory/test-agent-123")

      html = render_click(view, "change-tab", %{"tab" => "working_memory"})
      assert is_binary(html)
    end

    @tag :fast
    test "change-tab to preferences", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/memory/test-agent-123")

      html = render_click(view, "change-tab", %{"tab" => "preferences"})
      assert is_binary(html)
    end

    @tag :fast
    test "change-tab to proposals", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/memory/test-agent-123")

      html = render_click(view, "change-tab", %{"tab" => "proposals"})
      assert is_binary(html)
    end

    @tag :fast
    test "change-tab to code", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/memory/test-agent-123")

      html = render_click(view, "change-tab", %{"tab" => "code"})
      assert is_binary(html)
    end

    @tag :fast
    test "change-tab back to working_memory", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/memory/test-agent-123")

      render_click(view, "change-tab", %{"tab" => "identity"})
      html = render_click(view, "change-tab", %{"tab" => "working_memory"})
      assert is_binary(html)
    end
  end

  @tag :fast
  describe "MemoryLive section toggle" do
    @tag :fast
    test "toggle-section thoughts expands/collapses", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/memory/test-agent-123")

      # Expand
      html = render_click(view, "toggle-section", %{"section" => "thoughts"})
      assert is_binary(html)

      # Collapse
      html = render_click(view, "toggle-section", %{"section" => "thoughts"})
      assert is_binary(html)
    end

    @tag :fast
    test "toggle-section concerns", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/memory/test-agent-123")

      html = render_click(view, "toggle-section", %{"section" => "concerns"})
      assert is_binary(html)
    end

    @tag :fast
    test "toggle-section curiosity", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/memory/test-agent-123")

      html = render_click(view, "toggle-section", %{"section" => "curiosity"})
      assert is_binary(html)
    end

    @tag :fast
    test "toggle-section goals", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/memory/test-agent-123")

      html = render_click(view, "toggle-section", %{"section" => "goals"})
      assert is_binary(html)
    end

    @tag :fast
    test "toggle-section proposals", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/memory/test-agent-123")

      html = render_click(view, "toggle-section", %{"section" => "proposals"})
      assert is_binary(html)
    end

    @tag :fast
    test "toggle-section kg", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/memory/test-agent-123")

      html = render_click(view, "toggle-section", %{"section" => "kg"})
      assert is_binary(html)
    end
  end

  describe "MemoryLive refresh with agent" do
    @tag :fast
    test "refresh reloads current tab data", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/memory/test-agent-123")

      html = render_click(view, "refresh")
      assert html =~ "Memory Viewer"
    end
  end
end
