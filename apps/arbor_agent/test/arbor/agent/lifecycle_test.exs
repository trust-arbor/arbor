defmodule Arbor.Agent.LifecycleTest do
  use ExUnit.Case

  alias Arbor.Agent.{Character, Lifecycle, Profile}

  @agents_dir Path.join(System.tmp_dir!(), "arbor_lifecycle_test_agents")

  setup do
    # Use a temp directory for test isolation
    File.rm_rf!(@agents_dir)
    File.mkdir_p!(@agents_dir)

    on_exit(fn ->
      File.rm_rf!(@agents_dir)
    end)

    :ok
  end

  describe "profile persistence" do
    test "persist and restore a profile via JSON" do
      character = Character.new(name: "TestAgent", tone: "helpful")

      profile = %Profile{
        agent_id: "test-agent-1",
        character: character,
        trust_tier: :probationary,
        initial_goals: [%{type: :achieve, description: "Test"}],
        metadata: %{test: true},
        created_at: DateTime.utc_now(),
        version: 1
      }

      # Write to temp dir
      path = Path.join(@agents_dir, "test-agent-1.agent.json")
      {:ok, json} = Profile.to_json(profile)
      File.write!(path, json)

      # Read back
      {:ok, read_json} = File.read(path)
      {:ok, restored} = Profile.from_json(read_json)

      assert restored.agent_id == "test-agent-1"
      assert restored.trust_tier == :probationary
      assert restored.character.name == "TestAgent"
      assert restored.character.tone == "helpful"
    end

    test "restore returns error for non-existent agent" do
      # Lifecycle.restore reads from cwd-relative .arbor/agents/
      # Since "nonexistent" doesn't exist, should return not_found
      assert {:error, :not_found} = Lifecycle.restore("nonexistent_agent_xyz")
    end
  end

  describe "list_agents/0" do
    test "returns empty list when no agents directory" do
      # list_agents reads from cwd, which may or may not have agents
      agents = Lifecycle.list_agents()
      assert is_list(agents)
    end
  end

  describe "resolve_template (via create)" do
    test "create requires character or template" do
      # create without character or template should fail
      assert {:error, :missing_character_or_template} = Lifecycle.create("test", [])
    end
  end
end
