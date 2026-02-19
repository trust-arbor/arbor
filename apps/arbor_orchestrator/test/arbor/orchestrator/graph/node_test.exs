defmodule Arbor.Orchestrator.Graph.NodeTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Graph.Node

  describe "from_attrs/2" do
    test "populates all typed fields from attrs map" do
      attrs = %{
        "shape" => "box",
        "type" => "codergen",
        "prompt" => "Write a module",
        "label" => "Generate Code",
        "goal_gate" => "true",
        "max_retries" => "3",
        "retry_target" => "start",
        "fallback_retry_target" => "fallback",
        "timeout" => "30s",
        "llm_model" => "gpt-4",
        "llm_provider" => "openai",
        "reasoning_effort" => "high",
        "allow_partial" => "true",
        "content_hash" => "abc123",
        "fidelity" => "full",
        "class" => "phase-one",
        "fan_out" => "true",
        "simulate" => "true"
      }

      node = Node.from_attrs("test_node", attrs)

      assert node.id == "test_node"
      assert node.attrs == attrs
      assert node.shape == "box"
      assert node.type == "codergen"
      assert node.prompt == "Write a module"
      assert node.label == "Generate Code"
      assert node.goal_gate == true
      assert node.max_retries == 3
      assert node.retry_target == "start"
      assert node.fallback_retry_target == "fallback"
      assert node.timeout == "30s"
      assert node.llm_model == "gpt-4"
      assert node.llm_provider == "openai"
      assert node.reasoning_effort == "high"
      assert node.allow_partial == true
      assert node.content_hash == "abc123"
      assert node.fidelity == "full"
      assert node.class == "phase-one"
      assert node.fan_out == true
      assert node.simulate == "true"
    end

    test "defaults to nil/false for missing attrs" do
      node = Node.from_attrs("minimal", %{})

      assert node.id == "minimal"
      assert node.attrs == %{}
      assert node.shape == "box"
      assert node.type == nil
      assert node.prompt == nil
      assert node.goal_gate == false
      assert node.max_retries == nil
      assert node.allow_partial == false
      assert node.fan_out == false
    end

    test "coerces boolean fields from various truthy values" do
      node_true = Node.from_attrs("t", %{"goal_gate" => true, "fan_out" => 1})
      assert node_true.goal_gate == true
      assert node_true.fan_out == true

      node_false = Node.from_attrs("f", %{"goal_gate" => "false", "fan_out" => 0})
      assert node_false.goal_gate == false
      assert node_false.fan_out == false
    end

    test "parses max_retries as integer" do
      assert Node.from_attrs("n", %{"max_retries" => "5"}).max_retries == 5
      assert Node.from_attrs("n", %{"max_retries" => 3}).max_retries == 3
      assert Node.from_attrs("n", %{"max_retries" => "abc"}).max_retries == nil
      assert Node.from_attrs("n", %{}).max_retries == nil
    end
  end

  describe "skippable?/1" do
    test "start nodes are skippable" do
      assert Node.skippable?(Node.from_attrs("s", %{"shape" => "Mdiamond"}))
    end

    test "exit nodes are skippable" do
      assert Node.skippable?(Node.from_attrs("e", %{"shape" => "Msquare"}))
    end

    test "diamond nodes are skippable" do
      assert Node.skippable?(Node.from_attrs("d", %{"shape" => "diamond"}))
    end

    test "box nodes are not skippable" do
      refute Node.skippable?(Node.from_attrs("b", %{"shape" => "box"}))
    end

    test "nodes without shape are not skippable" do
      refute Node.skippable?(Node.from_attrs("n", %{}))
    end
  end

  describe "side_effecting?/1" do
    test "shell nodes are side-effecting" do
      assert Node.side_effecting?(Node.from_attrs("s", %{"type" => "shell"}))
    end

    test "tool nodes are side-effecting" do
      assert Node.side_effecting?(Node.from_attrs("t", %{"type" => "tool"}))
    end

    test "file.write nodes are side-effecting" do
      assert Node.side_effecting?(Node.from_attrs("f", %{"type" => "file.write"}))
    end

    test "pipeline.run nodes are side-effecting" do
      assert Node.side_effecting?(Node.from_attrs("p", %{"type" => "pipeline.run"}))
    end

    test "codergen nodes are not side-effecting" do
      refute Node.side_effecting?(Node.from_attrs("c", %{"type" => "codergen"}))
    end

    test "nodes without type are not side-effecting" do
      refute Node.side_effecting?(Node.from_attrs("n", %{}))
    end
  end

  describe "classes/1" do
    test "splits comma-separated class string" do
      node = Node.from_attrs("n", %{"class" => "phase-one, security, critical"})
      assert Node.classes(node) == ["phase-one", "security", "critical"]
    end

    test "returns single class as list" do
      node = Node.from_attrs("n", %{"class" => "build"})
      assert Node.classes(node) == ["build"]
    end

    test "returns empty list when no class" do
      node = Node.from_attrs("n", %{})
      assert Node.classes(node) == []
    end

    test "returns empty list for empty class string" do
      node = Node.from_attrs("n", %{"class" => ""})
      assert Node.classes(node) == []
    end
  end

  describe "timeout_ms" do
    test "parses seconds to milliseconds" do
      node = Node.from_attrs("n", %{"timeout" => "30s"})
      assert node.timeout == "30s"
      assert node.timeout_ms == 30_000
    end

    test "parses minutes to milliseconds" do
      node = Node.from_attrs("n", %{"timeout" => "5m"})
      assert node.timeout_ms == 300_000
    end

    test "parses hours to milliseconds" do
      node = Node.from_attrs("n", %{"timeout" => "1h"})
      assert node.timeout_ms == 3_600_000
    end

    test "parses milliseconds directly" do
      node = Node.from_attrs("n", %{"timeout" => "500ms"})
      assert node.timeout_ms == 500
    end

    test "returns nil for unparseable timeout" do
      node = Node.from_attrs("n", %{"timeout" => "forever"})
      assert node.timeout_ms == nil
    end

    test "returns nil when no timeout" do
      node = Node.from_attrs("n", %{})
      assert node.timeout_ms == nil
    end
  end

  describe "attr/3" do
    test "reads from attrs map with string key" do
      node = Node.from_attrs("n", %{"custom_key" => "value"})
      assert Node.attr(node, "custom_key") == "value"
    end

    test "reads from attrs map with atom key (converts to string)" do
      node = Node.from_attrs("n", %{"custom_key" => "value"})
      assert Node.attr(node, :custom_key) == "value"
    end

    test "returns default for missing key" do
      node = Node.from_attrs("n", %{})
      assert Node.attr(node, "missing", "default") == "default"
    end
  end

  describe "content_hash/1" do
    test "produces deterministic SHA-256 hex hash" do
      node = Node.from_attrs("test", %{"type" => "codergen", "prompt" => "hello"})
      hash1 = Node.content_hash(node)
      hash2 = Node.content_hash(node)

      assert hash1 == hash2
      assert byte_size(hash1) == 64
      assert Regex.match?(~r/^[0-9a-f]{64}$/, hash1)
    end

    test "different attrs produce different hashes" do
      node1 = Node.from_attrs("n", %{"prompt" => "hello"})
      node2 = Node.from_attrs("n", %{"prompt" => "world"})

      refute Node.content_hash(node1) == Node.content_hash(node2)
    end

    test "different ids produce different hashes" do
      node1 = Node.from_attrs("a", %{"prompt" => "same"})
      node2 = Node.from_attrs("b", %{"prompt" => "same"})

      refute Node.content_hash(node1) == Node.content_hash(node2)
    end

    test "order of attrs does not affect hash" do
      attrs1 = %{"b" => "2", "a" => "1"}
      attrs2 = %{"a" => "1", "b" => "2"}

      assert Node.content_hash(Node.from_attrs("n", attrs1)) ==
               Node.content_hash(Node.from_attrs("n", attrs2))
    end
  end

  describe "known_attrs/0" do
    test "returns a list of strings" do
      attrs = Node.known_attrs()
      assert is_list(attrs)
      assert Enum.all?(attrs, &is_binary/1)
    end

    test "includes key typed fields" do
      attrs = Node.known_attrs()
      assert "type" in attrs
      assert "prompt" in attrs
      assert "shape" in attrs
      assert "fan_out" in attrs
    end
  end

  describe "backward compatibility" do
    test "bare struct construction still works" do
      node = %Node{id: "x", attrs: %{"shape" => "box"}}
      assert node.id == "x"
      assert node.attrs == %{"shape" => "box"}
      # Typed fields default to nil/false
      assert node.shape == nil
      assert node.goal_gate == false
    end

    test "attr/3 works on both from_attrs and bare structs" do
      bare = %Node{id: "x", attrs: %{"shape" => "box"}}
      rich = Node.from_attrs("x", %{"shape" => "box"})

      assert Node.attr(bare, "shape") == "box"
      assert Node.attr(rich, "shape") == "box"
    end
  end
end
