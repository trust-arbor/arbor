defmodule Arbor.Agent.LifecycleTest do
  use ExUnit.Case
  @moduletag :fast

  # Lifecycle.create/2 and destroy/2 need an actor authority since ddf05e470.
  # One actor for the module: every grant spends the run's audit journal budget
  # (see Arbor.Agent.LifecycleActorFixture). creation_topology/1 reopens it.
  setup_all do
    {:ok, principal} = Arbor.Agent.open_lifecycle_actor_fixture()
    on_exit(fn -> Arbor.Agent.close_lifecycle_actor_fixture(principal) end)

    {:ok, lifecycle_principal: principal}
  end

  alias Arbor.Agent.{Character, Lifecycle, Profile}
  alias Arbor.Agent.Test.TrustTopology

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

    setup :creation_topology

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

    test "creating an agent from a template lands template_source on profile.metadata", %{
      lifecycle_actor: actor
    } do
      # This used to accept any downstream error because a full create could not
      # run in the isolated arbor_agent env (and since ddf05e470 it passed on the
      # authority denial alone). The describe now provides trust, the profiles
      # store and a caller-owned actor, so the provenance assertion always runs.
      assert {:ok, profile} =
               Lifecycle.create("Scout", template: "scout", actor_authority: actor.authority)

      source = profile.metadata["template_source"]
      assert source["name"] == "scout"
      assert source["layer"] == "shipped"
      assert String.ends_with?(source["path"], "scout.md")

      assert :ok = Lifecycle.destroy(profile.agent_id, actor_authority: actor.authority)
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

  # A full create needs trust (presets), the profiles store, and since
  # ddf05e470 a caller-owned actor authority opened in this test process.
  # Scoped to the describe that creates, so list_agents/0 tests are unaffected.
  defp creation_topology(%{lifecycle_principal: principal}) do
    TrustTopology.ensure_owned!()

    if Process.whereis(:arbor_agent_profiles) == nil do
      start_supervised!(
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore,
           name: :arbor_agent_profiles, backend: nil, write_mode: :sync},
          id: :arbor_agent_profiles
        )
      )
    end

    # The actor's authority must be owned by the test process that creates.
    {:ok, actor} = Arbor.Agent.reopen_lifecycle_actor_fixture(principal)

    {:ok, lifecycle_actor: actor}
  end
end
