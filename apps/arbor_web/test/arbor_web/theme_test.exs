defmodule Arbor.Web.ThemeTest do
  use ExUnit.Case, async: true

  alias Arbor.Web.Theme

  describe "colors/0" do
    test "returns a map of all named colors" do
      colors = Theme.colors()
      assert is_map(colors)
      assert Map.has_key?(colors, :green)
      assert Map.has_key?(colors, :yellow)
      assert Map.has_key?(colors, :red)
      assert Map.has_key?(colors, :blue)
      assert Map.has_key?(colors, :purple)
      assert Map.has_key?(colors, :orange)
      assert Map.has_key?(colors, :gray)
    end

    test "all colors are hex strings" do
      for {_name, value} <- Theme.colors() do
        assert String.starts_with?(value, "#")
        assert String.length(value) == 7
      end
    end
  end

  describe "color/1" do
    test "returns hex value for known colors" do
      assert Theme.color(:blue) == "#58a6ff"
      assert Theme.color(:green) == "#3fb950"
      assert Theme.color(:red) == "#f85149"
    end

    test "returns gray for unknown colors" do
      assert Theme.color(:nonexistent) == "#8b949e"
    end
  end

  describe "bg_class/1" do
    test "maps status to background class" do
      assert Theme.bg_class(:success) == "aw-bg-green"
      assert Theme.bg_class(:error) == "aw-bg-red"
      assert Theme.bg_class(:warning) == "aw-bg-yellow"
      assert Theme.bg_class(:info) == "aw-bg-blue"
    end

    test "maps color name directly" do
      assert Theme.bg_class(:purple) == "aw-bg-purple"
      assert Theme.bg_class(:orange) == "aw-bg-orange"
    end

    test "falls back to gray for unknown" do
      assert Theme.bg_class(:nope) == "aw-bg-gray"
    end
  end

  describe "text_class/1" do
    test "maps status to text class" do
      assert Theme.text_class(:error) == "aw-text-red"
      assert Theme.text_class(:running) == "aw-text-green"
    end

    test "maps color name directly" do
      assert Theme.text_class(:purple) == "aw-text-purple"
    end
  end

  describe "border_class/1" do
    test "maps status to border class" do
      assert Theme.border_class(:warning) == "aw-border-yellow"
      assert Theme.border_class(:healthy) == "aw-border-green"
    end

    test "maps color name directly" do
      assert Theme.border_class(:green) == "aw-border-green"
    end
  end

  describe "resolve_color_name/1" do
    test "resolves status atoms to color names" do
      assert Theme.resolve_color_name(:success) == :green
      assert Theme.resolve_color_name(:error) == :red
      assert Theme.resolve_color_name(:warning) == :yellow
      assert Theme.resolve_color_name(:info) == :blue
      assert Theme.resolve_color_name(:pending) == :yellow
      assert Theme.resolve_color_name(:failed) == :red
      assert Theme.resolve_color_name(:running) == :green
      assert Theme.resolve_color_name(:unknown) == :gray
    end

    test "passes through color names" do
      assert Theme.resolve_color_name(:green) == :green
      assert Theme.resolve_color_name(:blue) == :blue
      assert Theme.resolve_color_name(:purple) == :purple
    end

    test "defaults to gray for unrecognized atoms" do
      assert Theme.resolve_color_name(:nope) == :gray
    end
  end
end
