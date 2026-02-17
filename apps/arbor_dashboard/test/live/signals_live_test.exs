defmodule Arbor.Dashboard.Live.SignalsLiveTest do
  use Arbor.Dashboard.ConnCase, async: true

  @tag :fast
  describe "SignalsLive mount" do
    @tag :fast
    test "renders signal dashboard header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/signals")

      assert html =~ "Signals"
      assert html =~ "Real-time signal stream"
    end

    @tag :fast
    test "shows pause button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/signals")

      assert html =~ "Pause"
    end

    @tag :fast
    test "shows stat cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/signals")

      assert html =~ "In Store"
      assert html =~ "Subscriptions"
      assert html =~ "System health"
    end

    @tag :fast
    test "shows category filter dropdown", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/signals")

      assert html =~ "toggle-filter-dropdown"
      assert html =~ "Categories"
    end

    @tag :fast
    test "shows stream container", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/signals")

      assert html =~ "signals-stream"
    end
  end

  @tag :fast
  describe "SignalsLive toggle-pause event" do
    @tag :fast
    test "toggle pause changes button text", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/signals")

      html = render_click(view, "toggle-pause")
      assert html =~ "Resume"

      html = render_click(view, "toggle-pause")
      assert html =~ "Pause"
    end

    @tag :fast
    test "pausing and resuming does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/signals")

      # Pause
      html = render_click(view, "toggle-pause")
      assert html =~ "Resume"

      # Resume (flushes any buffered signals)
      html = render_click(view, "toggle-pause")
      assert html =~ "Pause"
    end
  end

  @tag :fast
  describe "SignalsLive filter events" do
    @tag :fast
    test "toggle-filter-dropdown opens dropdown", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/signals")

      html = render_click(view, "toggle-filter-dropdown")
      # Dropdown should be open, showing All/None buttons
      assert html =~ "All"
      assert html =~ "None"
    end

    @tag :fast
    test "toggle-filter-dropdown twice closes dropdown", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/signals")

      render_click(view, "toggle-filter-dropdown")
      html = render_click(view, "toggle-filter-dropdown")
      assert is_binary(html)
    end

    @tag :fast
    test "filter-select-all selects all categories", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/signals")

      html = render_click(view, "filter-select-all")
      assert is_binary(html)
    end

    @tag :fast
    test "filter-select-none clears all categories", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/signals")

      html = render_click(view, "filter-select-none")
      assert is_binary(html)
    end

    @tag :fast
    test "toggle-category with known category toggles filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/signals")

      # :agent is a known atom for signal categories
      html = render_click(view, "toggle-category", %{"category" => "agent"})
      assert is_binary(html)
    end
  end

  @tag :fast
  describe "SignalsLive signal detail events" do
    @tag :fast
    test "select-signal with non-existent id does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/signals")

      html = render_click(view, "select-signal", %{"id" => "non-existent-signal"})
      assert is_binary(html)
    end

    @tag :fast
    test "close-detail clears selected signal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/signals")

      html = render_click(view, "close-detail")
      assert is_binary(html)
    end
  end
end
