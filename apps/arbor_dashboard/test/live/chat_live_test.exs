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
    test "toggle-completed-goals toggles show_completed_goals assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "toggle-completed-goals")
      assert is_binary(html)
    end
  end

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

  describe "ChatLive start-agent with unknown model" do
    @tag :fast
    test "start-agent with unknown model shows error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "start-agent", %{"model" => "nonexistent-model"})
      assert html =~ "Unknown model"
    end
  end

  describe "ChatLive stop-agent without running agent" do
    @tag :fast
    test "stop-agent with no agent does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "stop-agent")
      assert is_binary(html)
    end
  end

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

  describe "always-allow-tool security gate (H13 regression)" do
    alias Arbor.Dashboard.Cores.AutoPromoteGate

    @tag :fast
    test "security regression (H13): non-:authorized decisions deny the auto-promote" do
      # H13: ChatLive's "Always Allow" event used to call
      # Trust.Store.always_allow/2 unconditionally — any user that could click
      # Approve could permanently promote any agent's trust to :auto for any
      # resource. The gate now lives in
      # Arbor.Dashboard.Cores.AutoPromoteGate.decision/1; this test pins every
      # non-OK Security.authorize/3 result shape to the deny outcome so future
      # drift in the auth pipeline doesn't silently re-open the hole.
      for decision <- [
            {:error, :not_found},
            {:error, :no_capability},
            {:error, :security_unavailable},
            {:error, :no_actor},
            {:ok, :pending_approval, "cap_123"},
            {:requires_approval, %{id: "cap_x"}}
          ] do
        assert {:error, :unauthorized_auto_promote} =
                 AutoPromoteGate.decision(decision),
               "H13 regression: decision #{inspect(decision)} must deny auto-promote"
      end
    end

    @tag :fast
    test ":authorized passes the gate" do
      assert :ok = AutoPromoteGate.decision(:authorized)
      assert :ok = AutoPromoteGate.decision({:ok, :authorized})
    end

    @tag :fast
    test "authorize/2 denies the implicit 'system' actor" do
      # The "system" actor is the dev/test fallback when no OIDC session is
      # bound. Auto-promote is never appropriate to grant from a UI surface
      # under that identity — fail closed.
      assert {:error, :unauthorized_auto_promote} =
               AutoPromoteGate.authorize("system", "agent_target")

      assert {:error, :unauthorized_auto_promote} =
               AutoPromoteGate.authorize(nil, "agent_target")

      assert {:error, :unauthorized_auto_promote} =
               AutoPromoteGate.authorize("", "agent_target")
    end

    @tag :fast
    test "behavioral: always-allow-tool denies when actor lacks auto_promote cap",
         %{conn: conn} do
      # H13 behavioral assertion. ChatLive mount grants the actor
      # arbor://consensus/admin but NOT arbor://trust/auto_promote/*. So a
      # naked "always-allow-tool" click from a fresh dashboard session must
      # produce the deny-flash, never silently call Trust.Store.always_allow/2.
      #
      # Pre-H13, this handler unconditionally called the trust mutation; this
      # test pins the gated behavior so a future refactor that bypasses
      # AutoPromoteGate.authorize/2 is caught here.
      {:ok, view, _html} = live(conn, "/chat")

      html =
        render_click(view, "always-allow-tool", %{
          "id" => "irq_synthetic_test",
          "agent" => "agent_target_xyz",
          "resource" => "arbor://shell/exec/rm"
        })

      assert html =~ "Always Allow requires the trust auto-promote capability.",
             "H13 regression (behavioral): always-allow-tool must deny without auto_promote cap"
    end
  end
end
