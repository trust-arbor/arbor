defmodule Arbor.Dashboard.Cores.ChannelsCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Dashboard.Cores.ChannelsCore

  @moduletag :fast

  describe "show_channel/1" do
    test "shapes a channel with type color and formatted timestamp" do
      channel = %{
        channel_id: "ch_001",
        name: "general",
        type: :public,
        member_count: 12,
        created_at: ~U[2026-04-07 14:30:00Z]
      }

      result = ChannelsCore.show_channel(channel)
      assert result.channel_id == "ch_001"
      assert result.name == "general"
      assert result.type == :public
      assert result.type_color == :green
      assert result.member_count == 12
      assert result.created_at_label == "2026-04-07 14:30"
    end

    test "tolerates missing fields with defaults" do
      result = ChannelsCore.show_channel(%{})
      assert result.name == "—"
      assert result.type_color == :gray
      assert result.member_count == 0
      assert result.created_at_label == ""
    end

    test "falls back to :id when :channel_id is absent" do
      result = ChannelsCore.show_channel(%{id: "alt_id", type: :public})
      assert result.channel_id == "alt_id"
    end
  end

  describe "count_stats/1" do
    test "counts total and public channels" do
      channels = [
        %{type: :public},
        %{type: :public},
        %{type: :private},
        %{type: :dm}
      ]

      assert ChannelsCore.count_stats(channels) == {4, 2}
    end

    test "returns zeros for empty or non-list" do
      assert ChannelsCore.count_stats([]) == {0, 0}
      assert ChannelsCore.count_stats(nil) == {0, 0}
    end
  end

  describe "type_color/1" do
    test "maps known types" do
      assert ChannelsCore.type_color(:public) == :green
      assert ChannelsCore.type_color(:private) == :purple
      assert ChannelsCore.type_color(:dm) == :blue
      assert ChannelsCore.type_color(:ops_room) == :yellow
      assert ChannelsCore.type_color(:group) == :gray
    end

    test "unknown types default to gray" do
      assert ChannelsCore.type_color(:weird) == :gray
      assert ChannelsCore.type_color(nil) == :gray
    end
  end

  describe "format_datetime/1" do
    test "formats DateTime as YYYY-MM-DD HH:MM" do
      assert ChannelsCore.format_datetime(~U[2026-04-07 14:30:00Z]) == "2026-04-07 14:30"
    end

    test "handles nil and other input" do
      assert ChannelsCore.format_datetime(nil) == ""
      assert ChannelsCore.format_datetime("garbage") == "garbage"
    end
  end
end
