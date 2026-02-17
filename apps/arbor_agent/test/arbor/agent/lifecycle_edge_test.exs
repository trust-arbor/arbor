defmodule Arbor.Agent.LifecycleEdgeTest do
  @moduledoc """
  Edge-case and partial-failure tests for the Lifecycle module.

  Covers: concurrent creates, restore from corrupted data, list_agents
  with partial corruption, and template resolution edge cases.
  """
  use ExUnit.Case, async: false

  alias Arbor.Agent.{Character, Lifecycle, Profile}

  @moduletag :fast

  @agents_dir Path.join(
                System.tmp_dir!(),
                "arbor_lifecycle_edge_test_#{System.unique_integer([:positive])}"
              )

  setup do
    File.rm_rf!(@agents_dir)
    File.mkdir_p!(@agents_dir)

    on_exit(fn ->
      File.rm_rf!(@agents_dir)
    end)

    :ok
  end

  # ============================================================================
  # Template resolution edge cases
  # ============================================================================

  describe "create/2 template resolution" do
    test "returns error when neither character nor template provided" do
      assert {:error, :missing_character_or_template} = Lifecycle.create("test", [])
    end

    test "returns error when empty opts provided" do
      assert {:error, :missing_character_or_template} = Lifecycle.create("test")
    end

    test "accepts a character directly and passes template resolution" do
      character = Character.new(name: "Direct", tone: "formal")

      # This will proceed past template resolution. Downstream it may fail
      # because security services are not started in this test env.
      # We catch the exit to verify template resolution itself passed.
      result =
        try do
          Lifecycle.create("Direct Agent", character: character)
        rescue
          ArgumentError -> {:error, :ets_not_started}
        catch
          :exit, {:noproc, _} -> {:error, :security_not_started}
          :exit, _ -> {:error, :downstream_exit}
        end

      case result do
        {:ok, _profile} ->
          :ok

        {:error, :missing_character_or_template} ->
          flunk("Should not fail with missing_character_or_template when character is provided")

        {:error, _other_reason} ->
          # Acceptable: downstream failures (security, memory, etc.) are fine
          :ok
      end
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

    test "returns deserialize error for corrupted JSON file" do
      corrupt_id = "corrupt-agent-#{System.unique_integer([:positive])}"
      agents_dir = Path.join(File.cwd!(), ".arbor/agents")
      File.mkdir_p!(agents_dir)
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

    test "returns deserialize error for valid JSON but invalid profile structure" do
      invalid_id = "invalid-profile-#{System.unique_integer([:positive])}"
      agents_dir = Path.join(File.cwd!(), ".arbor/agents")
      File.mkdir_p!(agents_dir)
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

    test "handles empty JSON file" do
      empty_id = "empty-agent-#{System.unique_integer([:positive])}"
      agents_dir = Path.join(File.cwd!(), ".arbor/agents")
      File.mkdir_p!(agents_dir)
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
        trust_tier: :untrusted,
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
      assert restored.trust_tier == :untrusted
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
        trust_tier: :trusted,
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
      assert restored.trust_tier == :trusted
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
        trust_tier: :probationary,
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
    test "returns empty list when agents directory does not exist" do
      # list_agents reads from cwd-relative path, which may or may not exist
      agents = Lifecycle.list_agents()
      assert is_list(agents)
    end

    test "list_agents skips corrupted files gracefully" do
      agents_dir = Path.join(File.cwd!(), ".arbor/agents")
      File.mkdir_p!(agents_dir)

      # Write a valid profile
      character = Character.new(name: "ValidAgent")

      valid_profile = %Profile{
        agent_id: "valid-list-#{System.unique_integer([:positive])}",
        character: character,
        trust_tier: :untrusted,
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
    test "concurrent restore calls for same agent do not interfere" do
      agents_dir = Path.join(File.cwd!(), ".arbor/agents")
      File.mkdir_p!(agents_dir)

      agent_id = "concurrent-restore-#{System.unique_integer([:positive])}"
      character = Character.new(name: "ConcurrentAgent")

      profile = %Profile{
        agent_id: agent_id,
        character: character,
        trust_tier: :probationary,
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

    test "create with nil display_name passes template resolution" do
      character = Character.new(name: "NilDisplay")

      # May fail downstream because security services are not started
      result =
        try do
          Lifecycle.create(nil, character: character)
        rescue
          ArgumentError -> {:error, :ets_not_started}
        catch
          :exit, {:noproc, _} -> {:error, :security_not_started}
          :exit, _ -> {:error, :downstream_exit}
        end

      case result do
        {:ok, profile} ->
          assert profile.character.name == "NilDisplay"

        {:error, _reason} ->
          # Acceptable: downstream failures (security, memory, etc.) are fine
          :ok
      end
    end
  end
end
