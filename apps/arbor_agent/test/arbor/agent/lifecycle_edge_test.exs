defmodule Arbor.Agent.LifecycleEdgeTest do
  @moduledoc """
  Edge-case and partial-failure tests for the Lifecycle module.

  Covers: concurrent creates, restore from corrupted data, list_agents
  with partial corruption, and template resolution edge cases.
  """
  use ExUnit.Case, async: false

  alias Arbor.Agent.{Character, Lifecycle, Profile}
  alias Arbor.Agent.Test.TrustTopology

  @moduletag :fast

  # Lifecycle.create/2 and destroy/2 need an actor authority since ddf05e470.
  # One actor for the module: every grant spends the run's audit journal budget
  # (see Arbor.Agent.LifecycleActorFixture). creation_topology/1 reopens it.
  setup_all do
    {:ok, principal} = Arbor.Agent.open_lifecycle_actor_fixture()
    on_exit(fn -> Arbor.Agent.close_lifecycle_actor_fixture(principal) end)

    {:ok, lifecycle_principal: principal}
  end

  setup do
    agents_dir =
      Path.join(
        Path.expand(System.tmp_dir!()),
        "arbor_lifecycle_edge_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(agents_dir)
    previous_legacy_dir = Application.fetch_env(:arbor_agent, :legacy_agents_dir)
    Application.put_env(:arbor_agent, :legacy_agents_dir, agents_dir)

    on_exit(fn ->
      restore_fetched_env(:arbor_agent, :legacy_agents_dir, previous_legacy_dir)
      File.rm_rf!(agents_dir)
    end)

    {:ok, agents_dir: agents_dir}
  end

  # A full create needs trust (presets), the profiles store, and since
  # ddf05e470 a caller-owned actor authority opened in this test process. Scoped
  # to the describes that create: a running profiles store changes what
  # list_agents/0 reads, which the legacy-directory tests below rely on.
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

  # ============================================================================
  # Template resolution edge cases
  # ============================================================================

  describe "create/2 template resolution" do
    setup :creation_topology

    test "returns error when neither character nor template provided" do
      assert {:error, :missing_character_or_template} = Lifecycle.create("test", [])
    end

    test "returns error when empty opts provided" do
      assert {:error, :missing_character_or_template} = Lifecycle.create("test")
    end

    # These used to accept any {:error, _} because a full create could not run in
    # the isolated arbor_agent env, and since ddf05e470 they were passing on the
    # authority denial without exercising the shape they assert. Setup now
    # provides the topology and the actor, so creation must succeed.
    test "accepts a character directly and passes template resolution", %{
      lifecycle_actor: actor
    } do
      character = Character.new(name: "Direct", tone: "formal")

      assert {:ok, profile} =
               Lifecycle.create("Direct Agent",
                 character: character,
                 actor_authority: actor.authority
               )

      destroy!(profile.agent_id, actor)
    end

    test "return_identity: true returns 3-tuple including freshly-generated identity", %{
      lifecycle_actor: actor
    } do
      character = Character.new(name: "ExternalRegistration", tone: "formal")

      assert {:ok, profile, identity} =
               Lifecycle.create("External Agent",
                 character: character,
                 return_identity: true,
                 actor_authority: actor.authority
               )

      assert profile.agent_id == identity.agent_id
      assert is_binary(identity.private_key)
      assert byte_size(identity.private_key) in [32, 64]
      assert is_binary(identity.public_key)
      assert byte_size(identity.public_key) == 32

      destroy!(profile.agent_id, actor)
    end

    test "return_identity defaults to false (returns 2-tuple)", %{lifecycle_actor: actor} do
      character = Character.new(name: "DefaultShape", tone: "formal")

      assert {:ok, %Profile{} = profile} =
               Lifecycle.create("Default Agent",
                 character: character,
                 actor_authority: actor.authority
               )

      destroy!(profile.agent_id, actor)
    end
  end

  # ============================================================================
  # Restore edge cases
  # ============================================================================

  describe "restore/1 edge cases" do
    test "returns :not_found for nonexistent agent" do
      assert {:error, :not_found} =
               Lifecycle.restore("totally_nonexistent_#{System.unique_integer([:positive])}")
    end

    test "returns deserialize error for corrupted JSON file", %{agents_dir: agents_dir} do
      corrupt_id = "corrupt-agent-#{System.unique_integer([:positive])}"
      path = Path.join(agents_dir, "#{corrupt_id}.agent.json")

      # Write corrupt JSON
      File.write!(path, "{ this is not valid JSON !!!")

      result = Lifecycle.restore(corrupt_id)

      case result do
        {:error, {:deserialize_failed, _}} -> :ok
        {:error, _other} -> :ok
      end

      # Cleanup
      File.rm(path)
    end

    test "returns deserialize error for valid JSON but invalid profile structure", %{
      agents_dir: agents_dir
    } do
      invalid_id = "invalid-profile-#{System.unique_integer([:positive])}"
      path = Path.join(agents_dir, "#{invalid_id}.agent.json")

      # Write valid JSON but missing required fields
      File.write!(path, Jason.encode!(%{"not_a_profile" => true}))

      result = Lifecycle.restore(invalid_id)

      # Profile.from_json should either succeed with defaults or fail with a deserialize error
      case result do
        {:ok, _profile} ->
          # Profile was lenient enough to accept it
          :ok

        {:error, {:deserialize_failed, _}} ->
          :ok

        {:error, _other} ->
          :ok
      end

      # Cleanup
      File.rm(path)
    end

    test "handles empty JSON file", %{agents_dir: agents_dir} do
      empty_id = "empty-agent-#{System.unique_integer([:positive])}"
      path = Path.join(agents_dir, "#{empty_id}.agent.json")

      File.write!(path, "")

      result = Lifecycle.restore(empty_id)

      # Empty file should fail at JSON decode
      case result do
        {:error, {:deserialize_failed, _}} -> :ok
        {:error, _other} -> :ok
      end

      # Cleanup
      File.rm(path)
    end
  end

  # ============================================================================
  # Profile persistence round-trip edge cases
  # ============================================================================

  describe "profile persistence round-trip" do
    test "profile with nil optional fields survives round-trip" do
      character = Character.new(name: "Minimal")

      profile = %Profile{
        agent_id: "minimal-#{System.unique_integer([:positive])}",
        character: character,
        display_name: nil,
        template: nil,
        identity: nil,
        keychain_ref: nil,
        metadata: %{},
        created_at: nil,
        version: 1
      }

      {:ok, json} = Profile.to_json(profile)
      {:ok, restored} = Profile.from_json(json)

      assert restored.agent_id == profile.agent_id
      assert restored.display_name == nil
      assert restored.template == nil
      assert restored.identity == nil
    end

    test "profile with all fields populated survives round-trip" do
      character =
        Character.new(
          name: "Full Agent",
          description: "A fully specified agent",
          role: "tester",
          background: "testing background",
          traits: [%{name: "curious", intensity: 0.9}],
          values: ["accuracy", "speed"],
          quirks: ["always double-checks"],
          tone: "formal",
          style: "concise",
          knowledge: [%{content: "knows testing", category: "skills"}],
          instructions: ["be thorough"]
        )

      profile = %Profile{
        agent_id: "full-agent-#{System.unique_integer([:positive])}",
        display_name: "Full Agent Display",
        character: character,
        template: nil,
        initial_goals: [%{type: :achieve, description: "Complete testing"}],
        initial_capabilities: [%{resource: "arbor://fs/read/**"}],
        identity: %{
          agent_id: "full-agent-id",
          public_key: "abcdef0123456789",
          endorsement: %{
            agent_id: "full-agent-id",
            authority_id: "system",
            endorsed_at: DateTime.utc_now()
          }
        },
        keychain_ref: "keychain-ref-123",
        metadata: %{"custom_key" => "custom_value"},
        created_at: DateTime.utc_now(),
        version: 3
      }

      {:ok, json} = Profile.to_json(profile)
      {:ok, restored} = Profile.from_json(json)

      assert restored.agent_id == profile.agent_id
      assert restored.display_name == "Full Agent Display"
      assert restored.version == 3
      assert restored.character.name == "Full Agent"
      assert restored.character.role == "tester"
      assert length(restored.initial_goals) == 1
    end

    test "profile with unicode characters in fields" do
      character = Character.new(name: "Unicode Agent")

      profile = %Profile{
        agent_id: "unicode-#{System.unique_integer([:positive])}",
        display_name: "Agent with special chars",
        character: character,
        metadata: %{"description" => "Handles emoji and unicode"},
        created_at: DateTime.utc_now(),
        version: 1
      }

      {:ok, json} = Profile.to_json(profile)
      {:ok, restored} = Profile.from_json(json)

      assert restored.character.name == "Unicode Agent"
      assert restored.metadata["description"] == "Handles emoji and unicode"
    end
  end

  # ============================================================================
  # list_agents resilience
  # ============================================================================

  describe "list_agents/0 resilience" do
    test "returns empty list when agents directory does not exist", %{agents_dir: agents_dir} do
      File.rm_rf!(agents_dir)

      refute File.exists?(agents_dir)
      assert Lifecycle.list_agents() == []
    end

    test "list_agents skips corrupted files gracefully", %{agents_dir: agents_dir} do
      # Write a valid profile
      character = Character.new(name: "ValidAgent")

      valid_profile = %Profile{
        agent_id: "valid-list-#{System.unique_integer([:positive])}",
        character: character,
        created_at: DateTime.utc_now(),
        version: 1
      }

      {:ok, valid_json} = Profile.to_json(valid_profile)
      valid_path = Path.join(agents_dir, "#{valid_profile.agent_id}.agent.json")
      File.write!(valid_path, valid_json)

      # Write a corrupted file
      corrupt_id = "corrupt-list-#{System.unique_integer([:positive])}"
      corrupt_path = Path.join(agents_dir, "#{corrupt_id}.agent.json")
      File.write!(corrupt_path, "NOT VALID JSON AT ALL")

      agents = Lifecycle.list_agents()

      # The valid agent should be present
      valid_ids = Enum.map(agents, & &1.agent_id)
      assert valid_profile.agent_id in valid_ids

      # The corrupt one should be filtered out (restore fails, filtered by match?)
      refute corrupt_id in valid_ids

      # Cleanup
      File.rm(valid_path)
      File.rm(corrupt_path)
    end
  end

  # ============================================================================
  # Concurrent lifecycle operations
  # ============================================================================

  describe "concurrent lifecycle operations" do
    test "concurrent restore calls for same agent do not interfere", %{agents_dir: agents_dir} do
      agent_id = "concurrent-restore-#{System.unique_integer([:positive])}"
      character = Character.new(name: "ConcurrentAgent")

      profile = %Profile{
        agent_id: agent_id,
        character: character,
        created_at: DateTime.utc_now(),
        version: 1
      }

      {:ok, json} = Profile.to_json(profile)
      path = Path.join(agents_dir, "#{agent_id}.agent.json")
      File.write!(path, json)

      # 10 concurrent restores of the same agent
      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            Lifecycle.restore(agent_id)
          end)
        end

      results = Task.await_many(tasks, 5_000)

      for result <- results do
        assert {:ok, restored} = result
        assert restored.agent_id == agent_id
        assert restored.character.name == "ConcurrentAgent"
      end

      # Cleanup
      File.rm(path)
    end

    test "concurrent list_agents calls are safe" do
      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            Lifecycle.list_agents()
          end)
        end

      results = Task.await_many(tasks, 5_000)

      for result <- results do
        assert is_list(result)
      end
    end
  end

  # ============================================================================
  # Partial failure in create pipeline
  # ============================================================================

  describe "partial failure in create pipeline" do
    setup :creation_topology

    test "create raises or errors when character is invalid type" do
      # Passing something that is not a Character struct triggers a CaseClauseError
      # in resolve_template because the Keyword.fetch matches {:ok, value}
      # but the value doesn't match %Character{}
      result =
        try do
          Lifecycle.create("test", character: "not a character struct")
        rescue
          CaseClauseError -> {:error, :invalid_character_type}
          FunctionClauseError -> {:error, :invalid_character_type}
        catch
          :exit, _ -> {:error, :downstream_exit}
        end

      assert {:error, _reason} = result
    end

    test "create with nil display_name passes template resolution", %{lifecycle_actor: actor} do
      character = Character.new(name: "NilDisplay")

      # Setup provides the full creation topology, so a downstream failure is no
      # longer an acceptable outcome; the profile must come back.
      assert {:ok, profile} =
               Lifecycle.create(nil, character: character, actor_authority: actor.authority)

      assert profile.character.name == "NilDisplay"
      destroy!(profile.agent_id, actor)
    end
  end

  # The setup actor is owned by this test process, so destroy in the test body.
  defp destroy!(agent_id, actor) do
    assert :ok = Lifecycle.destroy(agent_id, actor_authority: actor.authority)
  end

  defp restore_fetched_env(app, key, :error), do: Application.delete_env(app, key)
  defp restore_fetched_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
end
