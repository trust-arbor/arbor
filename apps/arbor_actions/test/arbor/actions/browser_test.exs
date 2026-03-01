defmodule Arbor.Actions.BrowserTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Browser

  # All 26 browser action modules
  @session_actions [
    Browser.StartSession,
    Browser.EndSession,
    Browser.GetStatus
  ]

  @navigation_actions [
    Browser.Navigate,
    Browser.Back,
    Browser.Forward,
    Browser.Reload,
    Browser.GetUrl,
    Browser.GetTitle
  ]

  @interaction_actions [
    Browser.Click,
    Browser.Type,
    Browser.Hover,
    Browser.Focus,
    Browser.Scroll,
    Browser.SelectOption
  ]

  @query_actions [
    Browser.Query,
    Browser.GetText,
    Browser.GetAttribute,
    Browser.IsVisible
  ]

  @content_actions [
    Browser.ExtractContent,
    Browser.Screenshot,
    Browser.Snapshot
  ]

  @sync_actions [
    Browser.Wait,
    Browser.WaitForSelector,
    Browser.WaitForNavigation
  ]

  @evaluate_actions [
    Browser.Evaluate
  ]

  @all_actions @session_actions ++
                 @navigation_actions ++
                 @interaction_actions ++
                 @query_actions ++
                 @content_actions ++
                 @sync_actions ++
                 @evaluate_actions

  describe "action count" do
    test "26 browser actions registered" do
      assert length(@all_actions) == 26
    end

    test "facade lists all 26 browser actions" do
      browser_actions = Arbor.Actions.list_actions()[:browser]
      assert length(browser_actions) == 26
    end
  end

  describe "action metadata" do
    test "all actions have browser category" do
      for mod <- @all_actions do
        assert mod.category() == "browser",
               "#{inspect(mod)} has category #{mod.category()}, expected browser"
      end
    end

    test "all actions have browser tag" do
      for mod <- @all_actions do
        assert "browser" in mod.tags(),
               "#{inspect(mod)} missing browser tag"
      end
    end

    test "all action names start with browser_" do
      for mod <- @all_actions do
        assert String.starts_with?(mod.name(), "browser_"),
               "#{inspect(mod)} name #{mod.name()} doesn't start with browser_"
      end
    end

    test "all actions have unique names" do
      names = Enum.map(@all_actions, & &1.name())
      assert length(names) == length(Enum.uniq(names))
    end
  end

  describe "tool schema generation" do
    test "all actions produce valid tool schemas" do
      for mod <- @all_actions do
        tool = mod.to_tool()
        assert is_map(tool), "#{inspect(mod)}.to_tool() should return a map"

        assert Map.has_key?(tool, :name) or Map.has_key?(tool, "name"),
               "#{inspect(mod)} tool missing name"

        assert Map.has_key?(tool, :description) or Map.has_key?(tool, "description"),
               "#{inspect(mod)} tool missing description"
      end
    end
  end

  describe "session extraction" do
    test "get_session finds :browser_session" do
      assert {:ok, :my_session} = Browser.get_session(%{browser_session: :my_session})
    end

    test "get_session finds :session" do
      assert {:ok, :my_session} = Browser.get_session(%{session: :my_session})
    end

    test "get_session checks nested tool_context" do
      context = %{tool_context: %{browser_session: :nested}}
      assert {:ok, :nested} = Browser.get_session(context)
    end

    test "get_session returns error when no session" do
      assert {:error, "No browser session in context"} = Browser.get_session(%{})
    end

    test "get_session handles non-map input" do
      assert {:error, "No browser session in context"} = Browser.get_session(nil)
    end
  end

  describe "missing session error" do
    # Actions that require a session should return the standard error
    @session_required_actions @all_actions -- [Browser.StartSession, Browser.Wait]

    test "session-requiring actions return missing session error" do
      for mod <- @session_required_actions do
        # Build minimal valid params for each action
        params = minimal_params(mod)
        result = mod.run(params, %{})

        assert result == {:error, "No browser session in context"},
               "#{inspect(mod)} should return missing session error, got: #{inspect(result)}"
      end
    end
  end

  describe "SSRF validation on Navigate" do
    test "blocks localhost" do
      result = Browser.Navigate.run(%{url: "http://localhost:8080"}, %{browser_session: :fake})
      assert {:error, msg} = result
      assert msg =~ "Blocked host"
    end

    test "blocks private IPs" do
      result = Browser.Navigate.run(%{url: "http://10.0.0.1/admin"}, %{browser_session: :fake})
      assert {:error, msg} = result
      assert msg =~ "Blocked private IP"
    end

    test "blocks metadata endpoint" do
      result =
        Browser.Navigate.run(%{url: "http://169.254.169.254/latest"}, %{browser_session: :fake})

      assert {:error, msg} = result
      assert msg =~ "Blocked host"
    end

    test "blocks non-http schemes" do
      result = Browser.Navigate.run(%{url: "file:///etc/passwd"}, %{browser_session: :fake})
      assert {:error, msg} = result
      assert msg =~ "Blocked scheme"
    end
  end

  describe "taint roles" do
    test "Navigate has SSRF taint on url" do
      roles = Browser.Navigate.taint_roles()
      assert roles.url == {:control, requires: [:ssrf]}
    end

    test "Click has control taint on selector" do
      roles = Browser.Click.taint_roles()
      assert roles.selector == :control
    end

    test "Type has control on selector and data on text" do
      roles = Browser.Type.taint_roles()
      assert roles.selector == :control
      assert roles.text == :data
    end

    test "Evaluate has command_injection taint on script" do
      roles = Browser.Evaluate.taint_roles()
      assert roles.script == {:control, requires: [:command_injection]}
    end

    test "Query has control taint on selector" do
      roles = Browser.Query.taint_roles()
      assert roles.selector == :control
    end

    test "SelectOption has control on selector, data on value" do
      roles = Browser.SelectOption.taint_roles()
      assert roles.selector == :control
      assert roles.value == :data
    end

    test "WaitForSelector has control on selector" do
      roles = Browser.WaitForSelector.taint_roles()
      assert roles.selector == :control
    end
  end

  describe "format_error" do
    test "passes through strings" do
      assert Browser.format_error("oops") == "oops"
    end

    test "extracts message from struct-like maps" do
      assert Browser.format_error(%{message: "not found"}) == "not found"
    end

    test "inspects other terms" do
      assert Browser.format_error(:timeout) =~ "timeout"
    end
  end

  # Build minimal valid params for each action module
  defp minimal_params(mod) do
    case mod.name() do
      "browser_navigate" -> %{url: "https://example.com"}
      "browser_click" -> %{selector: "#btn"}
      "browser_type" -> %{selector: "#input", text: "hello"}
      "browser_hover" -> %{selector: "#el"}
      "browser_focus" -> %{selector: "#el"}
      "browser_select_option" -> %{selector: "#select", value: "a"}
      "browser_query" -> %{selector: "div"}
      "browser_get_text" -> %{selector: "p"}
      "browser_get_attribute" -> %{selector: "a", attribute: "href"}
      "browser_is_visible" -> %{selector: "#el"}
      "browser_wait_for_selector" -> %{selector: "#el"}
      "browser_evaluate" -> %{script: "1+1"}
      _ -> %{}
    end
  end
end
