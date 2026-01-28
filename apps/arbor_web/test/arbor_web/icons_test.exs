defmodule Arbor.Web.IconsTest do
  use ExUnit.Case, async: true

  alias Arbor.Web.Icons

  describe "event_icon/1" do
    test "returns icon for known event types" do
      assert Icons.event_icon(:thinking) == "🧠"
      assert Icons.event_icon(:speaking) == "💬"
      assert Icons.event_icon(:acting) == "⚡"
      assert Icons.event_icon(:error) == "❌"
      assert Icons.event_icon(:success) == "✅"
      assert Icons.event_icon(:started) == "🚀"
      assert Icons.event_icon(:spawned) == "🌱"
      assert Icons.event_icon(:handoff) == "🤝"
    end

    test "returns bullet for unknown event types" do
      assert Icons.event_icon(:unknown_type) == "•"
    end
  end

  describe "category_icon/1" do
    test "returns icon for known categories" do
      assert Icons.category_icon(:consensus) == "🗳"
      assert Icons.category_icon(:security) == "🔒"
      assert Icons.category_icon(:agent) == "🤖"
      assert Icons.category_icon(:web) == "🌐"
      assert Icons.category_icon(:system) == "⚙️"
    end

    test "returns package icon for unknown categories" do
      assert Icons.category_icon(:unknown) == "📦"
    end
  end

  describe "perspective_icon/1" do
    test "returns icon for known perspectives" do
      assert Icons.perspective_icon(:security) == "🛡"
      assert Icons.perspective_icon(:performance) == "⚡"
      assert Icons.perspective_icon(:reliability) == "🏗"
      assert Icons.perspective_icon(:innovation) == "💡"
    end

    test "returns search icon for unknown perspectives" do
      assert Icons.perspective_icon(:unknown) == "🔍"
    end
  end

  describe "status_icon/1" do
    test "returns icon for known statuses" do
      assert Icons.status_icon(:ok) == "✅"
      assert Icons.status_icon(:running) == "🟢"
      assert Icons.status_icon(:warning) == "🟡"
      assert Icons.status_icon(:error) == "🔴"
      assert Icons.status_icon(:pending) == "⏳"
      assert Icons.status_icon(:offline) == "⚫"
    end

    test "returns question mark for unknown statuses" do
      assert Icons.status_icon(:unknown_status) == "❓"
    end
  end

  describe "collection accessors" do
    test "event_icons/0 returns map" do
      icons = Icons.event_icons()
      assert is_map(icons)
      assert map_size(icons) > 0
    end

    test "category_icons/0 returns map" do
      icons = Icons.category_icons()
      assert is_map(icons)
      assert map_size(icons) > 0
    end

    test "perspective_icons/0 returns map" do
      icons = Icons.perspective_icons()
      assert is_map(icons)
      assert map_size(icons) > 0
    end

    test "status_icons/0 returns map" do
      icons = Icons.status_icons()
      assert is_map(icons)
      assert map_size(icons) > 0
    end
  end
end
