defmodule Arbor.Contracts.Security.ReflexTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.Reflex

  describe "new/4" do
    test "creates a reflex with required fields" do
      reflex = Reflex.new("Test reflex", :pattern, {:pattern, ~r/test/})

      assert reflex.name == "Test reflex"
      assert reflex.type == :pattern
      assert {:pattern, regex} = reflex.trigger
      assert Regex.source(regex) == "test"
      assert reflex.response == :block
      assert reflex.enabled == true
      assert String.starts_with?(reflex.id, "rfx_")
    end

    test "accepts optional fields" do
      reflex =
        Reflex.new("Custom", :action, {:action, :dangerous},
          response: :warn,
          message: "Warning issued",
          priority: 90,
          enabled: false
        )

      assert reflex.response == :warn
      assert reflex.message == "Warning issued"
      assert reflex.priority == 90
      assert reflex.enabled == false
    end
  end

  describe "pattern/3" do
    test "creates a pattern-based reflex" do
      reflex = Reflex.pattern("Block rm -rf", ~r/rm\s+-rf/)

      assert reflex.type == :pattern
      assert {:pattern, regex} = reflex.trigger
      assert Regex.source(regex) == "rm\\s+-rf"
    end
  end

  describe "action/3" do
    test "creates an action-blocking reflex" do
      reflex = Reflex.action("Block sudo", :sudo)

      assert reflex.type == :action
      assert reflex.trigger == {:action, :sudo}
    end
  end

  describe "path/3" do
    test "creates a path-blocking reflex" do
      reflex = Reflex.path("Block SSH keys", "~/.ssh/*")

      assert reflex.type == :path
      assert reflex.trigger == {:path, "~/.ssh/*"}
    end
  end

  describe "custom/3" do
    test "creates a custom reflex" do
      check_fn = fn context -> Map.get(context, :dangerous, false) end
      reflex = Reflex.custom("Custom check", check_fn)

      assert reflex.type == :custom
      assert {:custom, ^check_fn} = reflex.trigger
    end
  end

  describe "matches?/2" do
    test "returns false when reflex is disabled" do
      reflex = Reflex.pattern("Test", ~r/test/, enabled: false)
      refute Reflex.matches?(reflex, %{command: "test"})
    end

    test "matches pattern trigger against command" do
      reflex = Reflex.pattern("Block rm", ~r/rm\s+-rf/)

      assert Reflex.matches?(reflex, %{command: "rm -rf /"})
      refute Reflex.matches?(reflex, %{command: "ls -la"})
    end

    test "matches action trigger against action atom" do
      reflex = Reflex.action("Block sudo", :sudo)

      assert Reflex.matches?(reflex, %{action: :sudo})
      refute Reflex.matches?(reflex, %{action: :shell_execute})
    end

    test "matches path trigger against file path" do
      reflex = Reflex.path("Block env files", "**/.env*")

      assert Reflex.matches?(reflex, %{path: "/app/.env"})
      assert Reflex.matches?(reflex, %{path: "/app/.env.local"})
      refute Reflex.matches?(reflex, %{path: "/app/config.exs"})
    end

    test "matches custom trigger with function" do
      check_fn = fn context -> context[:secret] == true end
      reflex = Reflex.custom("Block secrets", check_fn)

      assert Reflex.matches?(reflex, %{secret: true})
      refute Reflex.matches?(reflex, %{secret: false})
      refute Reflex.matches?(reflex, %{})
    end

    test "returns false when context lacks required key" do
      reflex = Reflex.pattern("Test", ~r/test/)
      refute Reflex.matches?(reflex, %{not_command: "test"})
    end
  end

  describe "enable/1 and disable/1" do
    test "enable sets enabled to true" do
      reflex = Reflex.pattern("Test", ~r/test/, enabled: false)
      enabled = Reflex.enable(reflex)

      assert enabled.enabled == true
    end

    test "disable sets enabled to false" do
      reflex = Reflex.pattern("Test", ~r/test/)
      disabled = Reflex.disable(reflex)

      assert disabled.enabled == false
    end
  end

  describe "reflex types" do
    test "supports all reflex types" do
      assert Reflex.pattern("P", ~r/x/).type == :pattern
      assert Reflex.action("A", :x).type == :action
      assert Reflex.path("F", "*").type == :path
      assert Reflex.custom("C", fn _ -> true end).type == :custom
    end
  end

  describe "response types" do
    test "supports all response types" do
      for response <- [:block, :warn, :log] do
        reflex = Reflex.pattern("Test", ~r/test/, response: response)
        assert reflex.response == response
      end
    end
  end

  describe "Jason encoding" do
    test "encodes pattern reflex to JSON" do
      reflex = Reflex.pattern("Block rm", ~r/rm\s+-rf/, priority: 100)
      json = Jason.encode!(reflex)
      decoded = Jason.decode!(json)

      assert decoded["name"] == "Block rm"
      assert decoded["type"] == "pattern"
      assert decoded["trigger"]["type"] == "pattern"
      assert decoded["trigger"]["value"] == "rm\\s+-rf"
      assert decoded["priority"] == 100
    end

    test "encodes action reflex to JSON" do
      reflex = Reflex.action("Block sudo", :sudo)
      json = Jason.encode!(reflex)
      decoded = Jason.decode!(json)

      assert decoded["trigger"]["type"] == "action"
      assert decoded["trigger"]["value"] == "sudo"
    end

    test "encodes custom reflex with placeholder" do
      reflex = Reflex.custom("Custom", fn _ -> true end)
      json = Jason.encode!(reflex)
      decoded = Jason.decode!(json)

      assert decoded["trigger"]["type"] == "custom"
      assert decoded["trigger"]["value"] == "<function>"
    end
  end
end
