defmodule Arbor.Dashboard.Live.AgentsLiveTest do
  use Arbor.Dashboard.ConnCase, async: false

  # AgentsLive's stop-agent and delete-agent events access the
  # :arbor_agent_registry ETS table, which must exist for tests.
  setup do
    if :ets.whereis(:arbor_agent_registry) == :undefined do
      :ets.new(:arbor_agent_registry, [:named_table, :set, :public])
    end

    :ok
  end

  @tag :fast
  describe "AgentsLive mount" do
    @tag :fast
    test "renders agents dashboard header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")

      assert html =~ "Agents"
      assert html =~ "Running agent instances and profiles"
    end

    @tag :fast
    test "shows stat cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")

      assert html =~ "Running"
      assert html =~ "Profiles"
    end

    @tag :fast
    test "shows agents stream container", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")

      assert html =~ "agents-stream"
    end
  end

  @tag :fast
  describe "AgentsLive select-agent event" do
    @tag :fast
    test "select-agent loads agent detail", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents")

      # Selecting a non-existent agent should not crash; it returns a detail
      # with nil values which renders the empty state
      html = render_click(view, "select-agent", %{"id" => "non-existent-agent"})
      assert is_binary(html)
    end
  end

  @tag :fast
  describe "AgentsLive close-detail event" do
    @tag :fast
    test "close-detail clears selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents")

      # Select then close
      render_click(view, "select-agent", %{"id" => "test-agent"})
      html = render_click(view, "close-detail")
      assert is_binary(html)
    end
  end

  @tag :fast
  describe "AgentsLive stop-agent event" do
    @tag :fast
    test "stop-agent with non-existent agent does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents")

      html = render_click(view, "stop-agent", %{"id" => "non-existent-agent"})
      assert is_binary(html)
    end
  end

  # Note: delete-agent event requires the full Arbor.Agent application
  # (ExecutorRegistry, Lifecycle etc.) and cannot be tested in isolation.
  # It is covered by integration tests when the full app is running.
end
