defmodule Arbor.Agent.ProfileTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.{Character, Profile}

  @character Character.new(
               name: "Scout",
               description: "A fast explorer",
               traits: [%{name: "efficient", intensity: 0.9}],
               values: ["speed", "accuracy"],
               tone: "concise"
             )

  describe "struct creation" do
    test "creates profile with required fields" do
      profile = %Profile{
        agent_id: "scout-1",
        character: @character,
        created_at: DateTime.utc_now()
      }

      assert profile.agent_id == "scout-1"
      assert profile.character.name == "Scout"
      assert profile.version == 1
      assert profile.metadata == %{}
    end

    test "creates profile with all fields" do
      now = DateTime.utc_now()

      profile = %Profile{
        agent_id: "researcher-1",
        character: @character,
        template: "scout",
        initial_goals: [%{type: :explore, description: "Survey area"}],
        initial_capabilities: [%{resource: "arbor://fs/read/**"}],
        identity: %{agent_id: "agent_abc123"},
        keychain_ref: "agent_abc123",
        metadata: %{source: "test"},
        created_at: now,
        version: 1
      }

      assert profile.template == "scout"
      assert length(profile.initial_goals) == 1
      assert profile.identity.agent_id == "agent_abc123"
    end
  end

  describe "system_prompt/1" do
    test "delegates to Character.to_system_prompt" do
      profile = %Profile{
        agent_id: "scout-1",
        character: @character,
        created_at: DateTime.utc_now()
      }

      prompt = Profile.system_prompt(profile)
      assert prompt =~ "# Character: Scout"
      assert prompt =~ "concise"
    end
  end

  describe "serialize/1 and deserialize/1" do
    test "round-trips through serialization" do
      now = DateTime.utc_now()

      original = %Profile{
        agent_id: "scout-1",
        character: @character,
        template: "scout",
        initial_goals: [%{type: :explore, description: "Survey area"}],
        initial_capabilities: [%{resource: "arbor://fs/read/**"}],
        identity: %{agent_id: "agent_abc123"},
        keychain_ref: "agent_abc123",
        metadata: %{source: "test"},
        created_at: now,
        version: 1
      }

      serialized = Profile.serialize(original)
      assert is_map(serialized)
      assert serialized["agent_id"] == "scout-1"
      assert serialized["version"] == 1
      assert is_map(serialized["character"])
      assert serialized["character"].name == "Scout"

      {:ok, restored} = Profile.deserialize(serialized)
      assert restored.agent_id == original.agent_id
      assert restored.character.name == "Scout"
      assert restored.character.tone == "concise"
      assert restored.version == 1
    end

    test "deserialize restores atom-keyed metadata after JSON strings the keys" do
      # Regression: profile metadata is written with atom keys, but JSON
      # persistence round-trips them to strings — so readers doing
      # `meta[:external_agent]` silently got nil after a restore. deserialize/1
      # now normalizes known (existing-atom) keys back to atoms.
      original = %Profile{
        agent_id: "ext-1",
        character: @character,
        identity: %{agent_id: "agent_x"},
        metadata: %{external_agent: true, agent_type: "claude_code"},
        created_at: DateTime.utc_now()
      }

      # Simulate the persistence round-trip stringifying the metadata keys.
      serialized =
        original
        |> Profile.serialize()
        |> Map.put("metadata", %{"external_agent" => true, "agent_type" => "claude_code"})

      {:ok, restored} = Profile.deserialize(serialized)

      # Atom-key readers work again (the bug was these returning nil).
      assert restored.metadata[:external_agent] == true
      assert restored.metadata[:agent_type] == "claude_code"
    end

    test "serialize excludes private keys" do
      profile = %Profile{
        agent_id: "scout-1",
        character: @character,
        identity: %{agent_id: "agent_abc123", public_key: "deadbeef", private_key: "SECRET"},
        created_at: DateTime.utc_now()
      }

      serialized = Profile.serialize(profile)
      # Full identity map is included with public data, but private_key is excluded
      assert serialized["identity"]["agent_id"] == "agent_abc123"
      assert serialized["identity"]["public_key"] == "deadbeef"
      refute get_in(serialized, ["identity", "private_key"])
    end
  end

  describe "to_json/1 and from_json/1" do
    test "round-trips through JSON" do
      original = %Profile{
        agent_id: "scout-1",
        character: @character,
        initial_goals: [%{type: :explore, description: "Survey"}],
        metadata: %{"key" => "value"},
        created_at: DateTime.utc_now(),
        version: 1
      }

      {:ok, json} = Profile.to_json(original)
      assert is_binary(json)
      assert json =~ "scout-1"

      {:ok, restored} = Profile.from_json(json)
      assert restored.agent_id == "scout-1"
      assert restored.character.name == "Scout"
    end

    test "from_json returns error for invalid JSON" do
      assert {:error, _} = Profile.from_json("not json")
    end
  end
end
