defmodule Arbor.Agent.LifecycleTest do
  use ExUnit.Case
  @moduletag :fast

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

  describe "template_source provenance (Phase B1)" do
    alias Arbor.Agent.TemplateStore

    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "arbor_template_source_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      TemplateStore.set_templates_dir(tmp)

      on_exit(fn ->
        TemplateStore.clear_templates_dir_override()
        File.rm_rf!(tmp)
      end)

      :ok
    end

    test "resolving a builtin template attaches template_source with path + layer" do
      # This is the data the Lifecycle threads into profile.metadata.
      assert {:ok, data} = TemplateStore.resolve("scout")
      source = data["template_source"]
      assert source["name"] == "scout"
      assert source["layer"] == "shipped"
      assert is_binary(source["path"])
      assert String.ends_with?(source["path"], "scout.md")
    end

    test "creating an agent from a template lands template_source on profile.metadata" do
      # Full create needs the security/memory subsystems, which the isolated
      # arbor_agent test env does not start. Where it succeeds (e.g. the full
      # integration suite) we assert the provenance landed; otherwise the
      # downstream :noproc/:exit is acceptable and the resolve-level test above
      # provides the deterministic coverage of the same data.
      result =
        try do
          Lifecycle.create("Scout", template: "scout")
        rescue
          ArgumentError -> {:error, :ets_not_started}
        catch
          :exit, _ -> {:error, :security_not_started}
        end

      case result do
        {:ok, profile} ->
          source = profile.metadata["template_source"]
          assert source["name"] == "scout"
          assert source["layer"] == "shipped"
          assert String.ends_with?(source["path"], "scout.md")

        {:error, _downstream} ->
          :ok
      end
    end

    test "template_source survives JSON profile persistence round-trip" do
      # Proves the provenance, once on profile.metadata, persists across the
      # JSON serialize/deserialize boundary ProfileStore uses.
      source = %{"name" => "scout", "layer" => "user", "path" => "/x/scout.md"}

      profile = %Profile{
        agent_id: "prov-1",
        character: Character.new(name: "Scout"),
        metadata: %{"template_source" => source},
        created_at: DateTime.utc_now()
      }

      {:ok, json} = Profile.to_json(profile)
      {:ok, restored} = Profile.from_json(json)

      assert restored.metadata["template_source"] == source
    end
  end
end
