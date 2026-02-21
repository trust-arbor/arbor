defmodule Arbor.Contracts.Memory.IntentTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Memory.Intent

  describe "new/2" do
    test "creates an intent with required fields" do
      intent = Intent.new(:think)

      assert intent.type == :think
      assert String.starts_with?(intent.id, "int_")
      assert %DateTime{} = intent.created_at
    end

    test "accepts optional fields" do
      intent =
        Intent.new(:act,
          action: :shell_execute,
          params: %{command: "mix test"},
          reasoning: "Need to run tests",
          goal_id: "goal_123",
          urgency: 80
        )

      assert intent.type == :act
      assert intent.action == :shell_execute
      assert intent.params == %{command: "mix test"}
      assert intent.reasoning == "Need to run tests"
      assert intent.goal_id == "goal_123"
      assert intent.urgency == 80
    end
  end

  describe "action/3" do
    test "creates an action intent" do
      intent = Intent.action(:file_write, %{path: "/tmp/test.txt", content: "hello"})

      assert intent.type == :act
      assert intent.action == :file_write
      assert intent.params == %{path: "/tmp/test.txt", content: "hello"}
    end

    test "accepts additional options" do
      intent = Intent.action(:compile, %{}, goal_id: "goal_build", urgency: 90)

      assert intent.goal_id == "goal_build"
      assert intent.urgency == 90
    end
  end

  describe "think/2" do
    test "creates a thinking intent" do
      intent = Intent.think("Considering options")

      assert intent.type == :think
      assert intent.reasoning == "Considering options"
    end

    test "creates thinking intent without reasoning" do
      intent = Intent.think()

      assert intent.type == :think
      assert intent.reasoning == nil
    end
  end

  describe "wait/1" do
    test "creates a wait intent" do
      intent = Intent.wait()

      assert intent.type == :wait
    end
  end

  describe "reflect/2" do
    test "creates a reflection intent" do
      intent = Intent.reflect("Reviewing past actions")

      assert intent.type == :reflect
      assert intent.reasoning == "Reviewing past actions"
    end
  end

  describe "confidence" do
    test "defaults to 0.5" do
      intent = Intent.new(:act)
      assert intent.confidence == 0.5
    end

    test "accepts custom confidence" do
      intent = Intent.new(:act, confidence: 0.9)
      assert intent.confidence == 0.9
    end

    test "is independent from urgency" do
      intent = Intent.new(:act, confidence: 0.3, urgency: 90)
      assert intent.confidence == 0.3
      assert intent.urgency == 90
    end
  end

  describe "actionable?/1" do
    test "returns true for :act type" do
      intent = Intent.action(:test, %{})
      assert Intent.actionable?(intent)
    end

    test "returns false for other types" do
      for type <- [:think, :wait, :reflect, :internal] do
        intent = Intent.new(type)
        refute Intent.actionable?(intent)
      end
    end
  end

  describe "mental?/1" do
    test "returns true for think, wait, internal, reflect" do
      for type <- [:think, :wait, :internal, :reflect] do
        intent = Intent.new(type)
        assert Intent.mental?(intent), "expected mental? to be true for #{type}"
      end
    end

    test "returns false for :act" do
      intent = Intent.action(:test, %{})
      refute Intent.mental?(intent)
    end
  end

  describe "intent types" do
    test "supports all intent types" do
      for type <- [:think, :act, :wait, :reflect, :internal] do
        intent = Intent.new(type)
        assert intent.type == type
      end
    end
  end

  describe "from_map/1" do
    test "parses confidence from map with atom keys" do
      intent = Intent.from_map(%{type: :act, action: :test, confidence: 0.8})
      assert intent.confidence == 0.8
    end

    test "parses confidence from map with string keys" do
      intent = Intent.from_map(%{"type" => "act", "confidence" => 0.7})
      assert intent.confidence == 0.7
    end

    test "defaults confidence to 0.5 when missing" do
      intent = Intent.from_map(%{type: :think})
      assert intent.confidence == 0.5
    end

    test "handles integer confidence" do
      intent = Intent.from_map(%{type: :act, confidence: 1})
      assert intent.confidence == 1.0
    end
  end

  describe "capability_intent/4" do
    test "creates a capability-described intent" do
      intent = Intent.capability_intent("fs", :read, "/etc/hosts")

      assert intent.type == :act
      assert intent.capability == "fs"
      assert intent.op == :read
      assert intent.target == "/etc/hosts"
      assert intent.action == :read
      assert intent.params.target == "/etc/hosts"
    end

    test "accepts reasoning and other options" do
      intent =
        Intent.capability_intent("shell", :execute, "mix test",
          reasoning: "Need to run tests",
          goal_id: "goal_123",
          urgency: 80
        )

      assert intent.capability == "shell"
      assert intent.op == :execute
      assert intent.target == "mix test"
      assert intent.reasoning == "Need to run tests"
      assert intent.goal_id == "goal_123"
      assert intent.urgency == 80
    end

    test "merges params with target" do
      intent =
        Intent.capability_intent("fs", :write, "/tmp/test.txt",
          params: %{content: "hello"}
        )

      assert intent.params == %{content: "hello", target: "/tmp/test.txt"}
    end
  end

  describe "capability fields in new/2" do
    test "accepts capability, op, target" do
      intent = Intent.new(:act, capability: "memory", op: :recall, target: "recent")

      assert intent.capability == "memory"
      assert intent.op == :recall
      assert intent.target == "recent"
    end

    test "defaults to nil" do
      intent = Intent.new(:think)

      assert intent.capability == nil
      assert intent.op == nil
      assert intent.target == nil
    end
  end

  describe "capability fields in from_map/1" do
    test "parses capability fields from atom keys" do
      intent = Intent.from_map(%{type: :act, capability: "fs", op: :read, target: "/tmp/x"})

      assert intent.capability == "fs"
      assert intent.op == :read
      assert intent.target == "/tmp/x"
    end

    test "parses capability fields from string keys" do
      intent =
        Intent.from_map(%{
          "type" => "act",
          "capability" => "shell",
          "op" => "execute",
          "target" => "ls -la"
        })

      assert intent.capability == "shell"
      assert intent.op == :execute
      assert intent.target == "ls -la"
    end
  end

  describe "capability intent round-trip" do
    test "Intent → JSON → from_map preserves capability fields" do
      original = Intent.capability_intent("fs", :read, "/etc/hosts", reasoning: "check hosts")
      json = Jason.encode!(original)
      decoded = Jason.decode!(json)
      restored = Intent.from_map(decoded)

      assert restored.capability == "fs"
      assert restored.op == :read
      assert restored.target == "/etc/hosts"
      assert restored.reasoning == "check hosts"
      assert restored.type == :act
    end
  end

  describe "Jason encoding" do
    test "encodes intent to JSON" do
      intent = Intent.action(:shell_execute, %{command: "ls"}, urgency: 60)
      json = Jason.encode!(intent)
      decoded = Jason.decode!(json)

      assert decoded["type"] == "act"
      assert decoded["action"] == "shell_execute"
      assert decoded["params"] == %{"command" => "ls"}
      assert decoded["urgency"] == 60
    end

    test "encodes nil action as null" do
      intent = Intent.think()
      json = Jason.encode!(intent)
      decoded = Jason.decode!(json)

      assert decoded["action"] == nil
    end
  end
end
