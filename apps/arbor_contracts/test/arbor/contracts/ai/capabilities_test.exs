defmodule Arbor.Contracts.AI.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.AI.Capabilities

  describe "new/1" do
    test "creates struct with defaults" do
      caps = Capabilities.new()
      assert caps.streaming == false
      assert caps.tool_calls == false
      assert caps.thinking == false
      assert caps.vision == false
      assert caps.max_context == nil
    end

    test "accepts keyword list" do
      caps = Capabilities.new(streaming: true, thinking: true, max_context: 200_000)
      assert caps.streaming == true
      assert caps.thinking == true
      assert caps.max_context == 200_000
      assert caps.vision == false
    end

    test "accepts map with atom keys" do
      caps = Capabilities.new(%{streaming: true, tool_calls: true})
      assert caps.streaming == true
      assert caps.tool_calls == true
    end

    test "accepts map with string keys" do
      caps = Capabilities.new(%{"streaming" => true, "vision" => true})
      assert caps.streaming == true
      assert caps.vision == true
    end
  end

  describe "supports?/2" do
    test "returns true for enabled boolean flags" do
      caps = Capabilities.new(streaming: true, thinking: true)
      assert Capabilities.supports?(caps, :streaming)
      assert Capabilities.supports?(caps, :thinking)
    end

    test "returns false for disabled boolean flags" do
      caps = Capabilities.new(streaming: true)
      refute Capabilities.supports?(caps, :vision)
      refute Capabilities.supports?(caps, :tool_calls)
    end

    test "supports max_context when set" do
      caps = Capabilities.new(max_context: 128_000)
      assert Capabilities.supports?(caps, :max_context)
    end

    test "does not support max_context when nil" do
      caps = Capabilities.new()
      refute Capabilities.supports?(caps, :max_context)
    end

    test "supports max_output when set" do
      caps = Capabilities.new(max_output: 16_000)
      assert Capabilities.supports?(caps, :max_output)
    end
  end

  describe "satisfies?/2" do
    test "returns true when all requirements met" do
      caps = Capabilities.new(streaming: true, tool_calls: true, thinking: true)
      assert Capabilities.satisfies?(caps, [:streaming, :tool_calls])
      assert Capabilities.satisfies?(caps, [:thinking])
    end

    test "returns false when any requirement not met" do
      caps = Capabilities.new(streaming: true)
      refute Capabilities.satisfies?(caps, [:streaming, :vision])
    end

    test "returns true for empty requirements" do
      caps = Capabilities.new()
      assert Capabilities.satisfies?(caps, [])
    end
  end

  describe "enabled/1" do
    test "returns list of enabled flags" do
      caps = Capabilities.new(streaming: true, vision: true, embeddings: true)
      enabled = Capabilities.enabled(caps)
      assert :streaming in enabled
      assert :vision in enabled
      assert :embeddings in enabled
      refute :thinking in enabled
    end

    test "returns empty list when nothing enabled" do
      caps = Capabilities.new()
      assert Capabilities.enabled(caps) == []
    end
  end

  describe "flags/0" do
    test "returns all boolean capability flag names" do
      flags = Capabilities.flags()
      assert :streaming in flags
      assert :tool_calls in flags
      assert :thinking in flags
      assert :vision in flags
      assert :embeddings in flags
      assert length(flags) == 9
    end
  end
end
