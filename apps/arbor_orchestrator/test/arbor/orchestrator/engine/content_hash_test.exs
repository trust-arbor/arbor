defmodule Arbor.Orchestrator.Engine.ContentHashTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.{ContentHash, Context}
  alias Arbor.Orchestrator.Graph.Node

  defmodule IdempotentHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler
    @impl true
    def execute(_n, _c, _g, _o), do: %Arbor.Orchestrator.Engine.Outcome{status: :success}
    @impl true
    def idempotency, do: :idempotent
  end

  defmodule ReadOnlyHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler
    @impl true
    def execute(_n, _c, _g, _o), do: %Arbor.Orchestrator.Engine.Outcome{status: :success}
    @impl true
    def idempotency, do: :read_only
  end

  defmodule SideEffectingHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler
    @impl true
    def execute(_n, _c, _g, _o), do: %Arbor.Orchestrator.Engine.Outcome{status: :success}
    @impl true
    def idempotency, do: :side_effecting
  end

  describe "compute/2" do
    test "returns a hex-encoded SHA-256 hash" do
      node = Node.from_attrs("test", %{"type" => "codergen", "prompt" => "write code"})
      ctx = Context.new()

      hash = ContentHash.compute(node, ctx)
      assert is_binary(hash)
      assert byte_size(hash) == 64
      assert Regex.match?(~r/^[0-9a-f]{64}$/, hash)
    end

    test "same node and context produce same hash" do
      node = Node.from_attrs("test", %{"type" => "codergen", "prompt" => "write code"})
      ctx = Context.new(%{"graph.goal" => "test"})

      hash1 = ContentHash.compute(node, ctx)
      hash2 = ContentHash.compute(node, ctx)
      assert hash1 == hash2
    end

    test "different attrs produce different hash" do
      ctx = Context.new()
      node1 = Node.from_attrs("test", %{"prompt" => "write code"})
      node2 = Node.from_attrs("test", %{"prompt" => "delete code"})

      hash1 = ContentHash.compute(node1, ctx)
      hash2 = ContentHash.compute(node2, ctx)
      assert hash1 != hash2
    end

    test "different context values produce different hash" do
      node = Node.from_attrs("test", %{"type" => "codergen"})
      ctx1 = Context.new(%{"graph.goal" => "goal_a"})
      ctx2 = Context.new(%{"graph.goal" => "goal_b"})

      hash1 = ContentHash.compute(node, ctx1)
      hash2 = ContentHash.compute(node, ctx2)
      assert hash1 != hash2
    end

    test "different node IDs produce different hash" do
      ctx = Context.new()
      node1 = Node.from_attrs("node_a", %{"prompt" => "same"})
      node2 = Node.from_attrs("node_b", %{"prompt" => "same"})

      hash1 = ContentHash.compute(node1, ctx)
      hash2 = ContentHash.compute(node2, ctx)
      assert hash1 != hash2
    end

    test "includes type-specific context keys for codergen" do
      node = Node.from_attrs("test", %{"type" => "codergen"})
      ctx1 = Context.new(%{"last_response" => "code_a"})
      ctx2 = Context.new(%{"last_response" => "code_b"})

      hash1 = ContentHash.compute(node, ctx1)
      hash2 = ContentHash.compute(node, ctx2)
      assert hash1 != hash2
    end

    test "non-relevant context keys don't affect hash" do
      node = Node.from_attrs("test", %{"type" => "start"})
      ctx1 = Context.new(%{"irrelevant" => "value1"})
      ctx2 = Context.new(%{"irrelevant" => "value2"})

      hash1 = ContentHash.compute(node, ctx1)
      hash2 = ContentHash.compute(node, ctx2)
      assert hash1 == hash2
    end
  end

  describe "can_skip?/4" do
    test "allows skip when hash matches, idempotent handler, not side-effecting" do
      node = Node.from_attrs("test", %{"type" => "codergen"})
      assert ContentHash.can_skip?(node, "abc", "abc", IdempotentHandler)
    end

    test "allows skip for read-only handler" do
      node = Node.from_attrs("test", %{"type" => "codergen"})
      assert ContentHash.can_skip?(node, "abc", "abc", ReadOnlyHandler)
    end

    test "denies skip when hashes differ" do
      node = Node.from_attrs("test", %{"type" => "codergen"})
      refute ContentHash.can_skip?(node, "abc", "def", IdempotentHandler)
    end

    test "denies skip for side-effecting handler" do
      node = Node.from_attrs("test", %{"type" => "codergen"})
      refute ContentHash.can_skip?(node, "abc", "abc", SideEffectingHandler)
    end

    test "denies skip for side-effecting node type" do
      node = Node.from_attrs("test", %{"type" => "shell"})
      refute ContentHash.can_skip?(node, "abc", "abc", IdempotentHandler)
    end

    test "denies skip for tool node type" do
      node = Node.from_attrs("test", %{"type" => "tool"})
      refute ContentHash.can_skip?(node, "abc", "abc", IdempotentHandler)
    end
  end
end
