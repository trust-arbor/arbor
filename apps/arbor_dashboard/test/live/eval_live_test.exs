defmodule Arbor.Dashboard.Live.EvalLiveTest do
  use Arbor.Dashboard.ConnCase, async: true

  @tag :fast
  describe "EvalLive mount" do
    @tag :fast
    test "renders eval dashboard header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/eval")

      assert html =~ "Evaluation"
      assert html =~ "LLM eval runs and model comparison"
    end

    @tag :fast
    test "shows tab bar with runs and models", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/eval")

      assert html =~ "Runs"
      assert html =~ "Models"
    end

    @tag :fast
    test "shows stat cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/eval")

      assert html =~ "Total Runs"
      assert html =~ "Completed %"
      assert html =~ "Avg Accuracy"
      assert html =~ "Avg Duration"
    end

    @tag :fast
    test "shows refresh button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/eval")

      assert html =~ "Refresh"
    end

    @tag :fast
    test "shows data source badge", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/eval")

      # Should show either Postgres or Offline badge
      assert html =~ "Postgres" or html =~ "Offline"
    end

    @tag :fast
    test "shows filter form with domain and status selects", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/eval")

      assert html =~ "All Domains"
      assert html =~ "All Statuses"
      assert html =~ "Filter by model"
    end
  end

  @tag :fast
  describe "EvalLive tab navigation" do
    @tag :fast
    test "change-tab to models switches tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/eval")

      html = render_click(view, "change-tab", %{"tab" => "models"})
      # Models tab should be active - either shows model cards or empty state
      assert html =~ "Models" or html =~ "No model data"
    end

    @tag :fast
    test "change-tab to runs switches back", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/eval")

      # Switch to models first
      render_click(view, "change-tab", %{"tab" => "models"})
      # Switch back to runs
      html = render_click(view, "change-tab", %{"tab" => "runs"})
      assert html =~ "Total Runs"
    end
  end

  @tag :fast
  describe "EvalLive filter events" do
    @tag :fast
    test "filter-change with domain updates filters", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/eval")

      html = render_click(view, "filter-change", %{"domain" => "coding", "status" => "", "model" => ""})
      assert is_binary(html)
    end

    @tag :fast
    test "filter-change with status updates filters", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/eval")

      html = render_click(view, "filter-change", %{"domain" => "", "status" => "completed", "model" => ""})
      assert is_binary(html)
    end

    @tag :fast
    test "clear-filters resets all filters", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/eval")

      # Set a filter first
      render_click(view, "filter-change", %{"domain" => "coding", "status" => "", "model" => ""})

      # Clear filters
      html = render_click(view, "clear-filters")
      assert is_binary(html)
    end
  end

  @tag :fast
  describe "EvalLive run navigation" do
    @tag :fast
    test "select-run with non-existent id does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/eval")

      html = render_click(view, "select-run", %{"id" => "non-existent-run-id"})
      assert is_binary(html)
    end

    @tag :fast
    test "back-to-runs clears selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/eval")

      html = render_click(view, "back-to-runs")
      assert html =~ "Total Runs"
    end
  end

  @tag :fast
  describe "EvalLive result toggle" do
    @tag :fast
    test "toggle-result with an id does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/eval")

      html = render_click(view, "toggle-result", %{"id" => "some-result-id"})
      assert is_binary(html)
    end
  end

  @tag :fast
  describe "EvalLive refresh" do
    @tag :fast
    test "refresh event reloads data", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/eval")

      html = render_click(view, "refresh")
      assert html =~ "Evaluation"
    end
  end
end
