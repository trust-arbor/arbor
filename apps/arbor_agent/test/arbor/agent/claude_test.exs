defmodule Arbor.Agent.ClaudeTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.Claude
  alias Arbor.Agent.Templates.CliAgent

  describe "CliAgent template" do
    test "defines a character" do
      character = CliAgent.character()
      assert character.name == "CLI Agent"
      assert character.role == "Interactive development agent"
      assert length(character.traits) == 4
      assert length(character.values) == 4
    end

    test "uses established trust tier" do
      assert CliAgent.trust_tier() == :established
    end

    test "defines initial goals" do
      goals = CliAgent.initial_goals()
      assert length(goals) == 3
      assert Enum.any?(goals, &(&1.type == :collaborate))
    end

    test "requires appropriate capabilities" do
      caps = CliAgent.required_capabilities()
      assert length(caps) >= 5

      resources = Enum.map(caps, & &1.resource)
      assert "arbor://fs/read/**" in resources
      assert "arbor://memory/read/**" in resources
      assert "arbor://ai/generate/**" in resources
      assert "arbor://actions/execute/**" in resources
    end

    test "provides metadata" do
      meta = CliAgent.metadata()
      assert meta.session_integration == true
    end
  end

  describe "Claude agent" do
    test "starts with default options" do
      {:ok, agent} = Claude.start_link()
      assert is_pid(agent)

      assert Claude.agent_id(agent) == "claude-code"
      assert Claude.session_id(agent) == nil

      GenServer.stop(agent)
    end

    test "starts with custom id" do
      {:ok, agent} = Claude.start_link(id: "test-claude")
      assert Claude.agent_id(agent) == "test-claude"
      GenServer.stop(agent)
    end

    test "get_thinking returns empty list initially" do
      {:ok, agent} = Claude.start_link()
      assert {:ok, []} = Claude.get_thinking(agent)
      GenServer.stop(agent)
    end

    test "list_actions returns available action categories" do
      actions = Claude.list_actions()

      # Should have action categories if arbor_actions is available
      if map_size(actions) > 0 do
        assert Map.has_key?(actions, :file) or Map.has_key?(actions, :shell)
      end
    end

    test "get_tools returns LLM tool schemas" do
      tools = Claude.get_tools()

      # Should return a list of tool schemas if arbor_actions is available
      assert is_list(tools)

      if tools != [] do
        [first | _] = tools
        assert is_map(first)
        assert Map.has_key?(first, "name") or Map.has_key?(first, :name)
      end
    end
  end

  describe "Claude agent queries" do
    @tag :external
    @tag timeout: 120_000
    test "executes a query and returns response" do
      {:ok, agent} = Claude.start_link(model: :haiku)

      case Claude.query(agent, "What is 2+2?", timeout: 60_000) do
        {:ok, response} ->
          assert is_binary(response.text)
          assert String.contains?(response.text, "4")

        {:error, :cli_not_found} ->
          # CLI not available in CI
          :ok

        {:error, {:transport_closed, _status}} ->
          # Transport issue
          :ok
      end

      GenServer.stop(agent)
    end
  end
end
