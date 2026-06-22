defmodule Arbor.Dashboard.Live.ChatLive.HelpersTest do
  use ExUnit.Case, async: true

  alias Arbor.Dashboard.Live.ChatLive.Helpers, as: H

  @moduletag :fast

  describe "message_style/3 — agent-initiated notification (A1 notify channel)" do
    test "renders distinctly in single-agent mode" do
      style = H.message_style(:notification, nil, false)
      assert style =~ "dashed"
      assert style =~ "italic"
      # not the assistant/user style
      refute style =~ "rgba(74, 255, 158"
    end

    test "stays distinct in group mode (wins over the group-mode catch-all)" do
      style = H.message_style(:notification, nil, true)
      assert style =~ "dashed"
      # the group-mode default is a solid 3px accent, not dashed
      refute style == H.message_style(:assistant, nil, true)
    end

    test "accepts a string role too" do
      assert H.message_style("notification", nil, false) ==
               H.message_style(:notification, nil, false)
    end

    test "normal roles are unaffected" do
      assert H.message_style(:user, nil, false) =~ "margin-left"
      assert H.message_style(:assistant, nil, false) =~ "rgba(74, 255, 158"
    end
  end

  describe "role_label/1 — notification" do
    test "labels an agent-initiated notification with the thought affordance" do
      assert H.role_label(:notification) == "💭 Agent"
      assert H.role_label("notification") == "💭 Agent"
    end

    test "other roles unchanged" do
      assert H.role_label(:user) == "You"
      assert H.role_label(:assistant) == "Agent"
      assert H.role_label(:anything_else) == "System"
    end
  end
end
