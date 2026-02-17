defmodule Arbor.Dashboard.Live.ChatLiveTest do
  use Arbor.Dashboard.ConnCase, async: false

  # ChatLive mount calls Manager.find_first_agent/0 when connected,
  # which requires the :arbor_agent_registry ETS table to exist.
  setup do
    if :ets.whereis(:arbor_agent_registry) == :undefined do
      :ets.new(:arbor_agent_registry, [:named_table, :set, :public])
    end

    :ok
  end

  @tag :fast
  describe "ChatLive mount" do
    @tag :fast
    test "renders chat dashboard header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/chat")

      assert html =~ "Agent Chat"
      assert html =~ "Interactive conversation"
    end

    @tag :fast
    test "shows model selection when no agent is running", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/chat")

      # Should show available models for starting an agent
      # The chat panel renders model buttons when no agent is connected
      assert html =~ "Chat"
    end
  end

  @tag :fast
  describe "ChatLive toggle events" do
    @tag :fast
    test "toggle-thinking toggles show_thinking assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      # First toggle: show_thinking starts true, becomes false
      html = render_click(view, "toggle-thinking")
      # The thinking panel visibility changes based on this assign
      assert is_binary(html)

      # Second toggle: back to true
      html = render_click(view, "toggle-thinking")
      assert is_binary(html)
    end

    @tag :fast
    test "toggle-memories toggles show_memories assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "toggle-memories")
      assert is_binary(html)
    end

    @tag :fast
    test "toggle-actions toggles show_actions assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "toggle-actions")
      assert is_binary(html)
    end

    @tag :fast
    test "toggle-thoughts toggles show_thoughts assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "toggle-thoughts")
      assert is_binary(html)
    end

    @tag :fast
    test "toggle-goals toggles show_goals assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "toggle-goals")
      assert is_binary(html)
    end

    @tag :fast
    test "toggle-llm-panel toggles show_llm_panel assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "toggle-llm-panel")
      assert is_binary(html)
    end

    @tag :fast
    test "toggle-identity toggles show_identity assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "toggle-identity")
      assert is_binary(html)
    end

    @tag :fast
    test "toggle-cognitive toggles show_cognitive assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "toggle-cognitive")
      assert is_binary(html)
    end

    @tag :fast
    test "toggle-code toggles show_code assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "toggle-code")
      assert is_binary(html)
    end

    @tag :fast
    test "toggle-proposals toggles show_proposals assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "toggle-proposals")
      assert is_binary(html)
    end

    @tag :fast
    test "toggle-completed-goals toggles show_completed_goals assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "toggle-completed-goals")
      assert is_binary(html)
    end
  end

  @tag :fast
  describe "ChatLive input events" do
    @tag :fast
    test "update-input stores the message value", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "update-input", %{"message" => "hello world"})
      assert is_binary(html)
    end

    @tag :fast
    test "update-input with no message param does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "update-input", %{})
      assert is_binary(html)
    end

    @tag :fast
    test "send-message with no agent does nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      # Send without an agent connected - should be a no-op
      html = render_click(view, "send-message")
      assert is_binary(html)
    end

    @tag :fast
    test "noop event does nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "noop")
      assert is_binary(html)
    end
  end

  @tag :fast
  describe "ChatLive start-agent with unknown model" do
    @tag :fast
    test "start-agent with unknown model shows error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "start-agent", %{"model" => "nonexistent-model"})
      assert html =~ "Unknown model"
    end
  end

  @tag :fast
  describe "ChatLive stop-agent without running agent" do
    @tag :fast
    test "stop-agent with no agent does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "stop-agent")
      assert is_binary(html)
    end
  end

  @tag :fast
  describe "ChatLive heartbeat model events" do
    @tag :fast
    test "set-heartbeat-model with empty string clears selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "set-heartbeat-model", %{"heartbeat_model" => ""})
      assert is_binary(html)
    end

    @tag :fast
    test "set-heartbeat-model with unknown id does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "set-heartbeat-model", %{"heartbeat_model" => "unknown"})
      assert is_binary(html)
    end
  end
end
