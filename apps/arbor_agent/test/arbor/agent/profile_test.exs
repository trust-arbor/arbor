defmodule Arbor.Agent.ProfileTest do
  use ExUnit.Case, async: true

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
      assert profile.trust_tier == :untrusted
      assert profile.version == 1
      assert profile.metadata == %{}
    end

    test "creates profile with all fields" do
      now = DateTime.utc_now()

      profile = %Profile{
        agent_id: "researcher-1",
        character: @character,
        trust_tier: :probationary,
        template: Arbor.Agent.Templates.Scout,
        initial_goals: [%{type: :explore, description: "Survey area"}],
        initial_capabilities: [%{resource: "arbor://fs/read/**"}],
        identity: %{agent_id: "agent_abc123"},
        keychain_ref: "agent_abc123",
        metadata: %{source: "test"},
        created_at: now,
        version: 1
      }

      assert profile.trust_tier == :probationary
      assert profile.template == Arbor.Agent.Templates.Scout
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
        trust_tier: :probationary,
        template: Arbor.Agent.Templates.Scout,
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
      assert serialized["trust_tier"] == "probationary"
      assert serialized["version"] == 1
      assert is_map(serialized["character"])
      assert serialized["character"].name == "Scout"

      {:ok, restored} = Profile.deserialize(serialized)
      assert restored.agent_id == original.agent_id
      assert restored.trust_tier == :probationary
      assert restored.character.name == "Scout"
      assert restored.character.tone == "concise"
      assert restored.version == 1
    end

    test "serialize excludes private keys" do
      profile = %Profile{
        agent_id: "scout-1",
        character: @character,
        identity: %{agent_id: "agent_abc123", private_key: "SECRET"},
        created_at: DateTime.utc_now()
      }

      serialized = Profile.serialize(profile)
      # Only the identity_ref (agent_id) is included, not the full identity map
      assert serialized["identity_ref"] == "agent_abc123"
      refute Map.has_key?(serialized, "identity")
    end
  end

  describe "to_json/1 and from_json/1" do
    test "round-trips through JSON" do
      original = %Profile{
        agent_id: "scout-1",
        character: @character,
        trust_tier: :probationary,
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
      assert restored.trust_tier == :probationary
      assert restored.character.name == "Scout"
    end

    test "from_json returns error for invalid JSON" do
      assert {:error, _} = Profile.from_json("not json")
    end
  end
end
