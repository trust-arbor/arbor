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

  describe "intent types" do
    test "supports all intent types" do
      for type <- [:think, :act, :wait, :reflect, :internal] do
        intent = Intent.new(type)
        assert intent.type == type
      end
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
