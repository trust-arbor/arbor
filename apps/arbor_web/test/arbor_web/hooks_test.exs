defmodule Arbor.Web.HooksTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Web.Hooks

  describe "hook_name/1" do
    test "returns JS hook name for :scroll_to_bottom" do
      assert Hooks.hook_name(:scroll_to_bottom) == "ScrollToBottom"
    end

    test "returns JS hook name for :clear_on_submit" do
      assert Hooks.hook_name(:clear_on_submit) == "ClearOnSubmit"
    end

    test "returns JS hook name for :event_timeline" do
      assert Hooks.hook_name(:event_timeline) == "EventTimeline"
    end

    test "returns JS hook name for :resizable_panel" do
      assert Hooks.hook_name(:resizable_panel) == "ResizablePanel"
    end

    test "returns JS hook name for :node_hexagon" do
      assert Hooks.hook_name(:node_hexagon) == "NodeHexagon"
    end

    test "raises KeyError for unknown hook key" do
      assert_raise KeyError, fn ->
        Hooks.hook_name(:nonexistent_hook)
      end
    end

    test "raises FunctionClauseError for non-atom input" do
      assert_raise FunctionClauseError, fn ->
        Hooks.hook_name("scroll_to_bottom")
      end
    end
  end

  describe "all/0" do
    test "returns a map of all hooks" do
      hooks = Hooks.all()
      assert is_map(hooks)
      assert map_size(hooks) == 5
    end

    test "contains all expected hook keys" do
      hooks = Hooks.all()

      expected_keys = [:scroll_to_bottom, :clear_on_submit, :event_timeline, :resizable_panel, :node_hexagon]

      for key <- expected_keys do
        assert Map.has_key?(hooks, key), "Expected hook key #{inspect(key)} to be present"
      end
    end

    test "all values are strings" do
      hooks = Hooks.all()

      for {_key, value} <- hooks do
        assert is_binary(value)
      end
    end

    test "all values are PascalCase JS hook names" do
      hooks = Hooks.all()

      for {_key, value} <- hooks do
        assert value =~ ~r/^[A-Z][a-zA-Z]+$/,
               "Expected #{inspect(value)} to be PascalCase"
      end
    end

    test "hook_name/1 returns same values as all/0 map entries" do
      for {key, value} <- Hooks.all() do
        assert Hooks.hook_name(key) == value
      end
    end
  end

  describe "names/0" do
    test "returns a list of JS hook name strings" do
      names = Hooks.names()
      assert is_list(names)
      assert length(names) == 5
    end

    test "contains all expected hook names" do
      names = Hooks.names()

      expected = ["ScrollToBottom", "ClearOnSubmit", "EventTimeline", "ResizablePanel", "NodeHexagon"]

      for name <- expected do
        assert name in names, "Expected #{inspect(name)} to be in names list"
      end
    end

    test "all entries are strings" do
      for name <- Hooks.names() do
        assert is_binary(name)
      end
    end

    test "names match values from all/0" do
      names = Hooks.names()
      values = Map.values(Hooks.all())

      assert Enum.sort(names) == Enum.sort(values)
    end
  end
end
