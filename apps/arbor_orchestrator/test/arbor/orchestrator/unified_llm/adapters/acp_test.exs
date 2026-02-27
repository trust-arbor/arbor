defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.AcpTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.Acp
  alias Arbor.Orchestrator.UnifiedLLM.{Message, Request}

  @moduletag :fast

  describe "provider/0" do
    test "returns acp" do
      assert Acp.provider() == "acp"
    end
  end

  describe "available?/0" do
    test "returns false when pool is not running" do
      # In test env, AcpPool is not started by default
      refute Acp.available?()
    end
  end

  describe "resolve_agent (via complete)" do
    # We can't fully test complete without a running pool, but we can test
    # the error path which confirms agent resolution ran.

    test "returns pool_not_available when pool isn't running" do
      request = %Request{
        provider: "acp",
        model: "sonnet",
        messages: [Message.new(:user, "hello")],
        provider_options: %{"agent" => "claude"}
      }

      assert {:error, :pool_not_available} = Acp.complete(request)
    end

    test "works with atom agent key" do
      request = %Request{
        provider: "acp",
        model: "sonnet",
        messages: [Message.new(:user, "hello")],
        provider_options: %{agent: :gemini}
      }

      assert {:error, :pool_not_available} = Acp.complete(request)
    end

    test "defaults agent when provider_options is empty" do
      request = %Request{
        provider: "acp",
        model: "sonnet",
        messages: [Message.new(:user, "hello")],
        provider_options: %{}
      }

      assert {:error, :pool_not_available} = Acp.complete(request)
    end

    test "defaults agent when provider_options is nil" do
      request = %Request{
        provider: "acp",
        model: "sonnet",
        messages: [Message.new(:user, "hello")]
      }

      assert {:error, :pool_not_available} = Acp.complete(request)
    end
  end

  describe "runtime_contract/0" do
    test "returns a valid contract" do
      contract = Acp.runtime_contract()
      assert contract.provider == "acp"
      assert contract.display_name == "ACP (Agent Communication Protocol)"
      assert contract.type == :cli
    end
  end

  describe "available_agents/0" do
    test "returns a list" do
      agents = Acp.available_agents()
      assert is_list(agents)
    end
  end
end
