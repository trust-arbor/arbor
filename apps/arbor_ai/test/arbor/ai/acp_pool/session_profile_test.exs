defmodule Arbor.AI.AcpPool.SessionProfileTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.AcpPool.SessionProfile

  @moduletag :fast

  describe "new/1" do
    test "computes profile hash from provider and tools" do
      profile = SessionProfile.new(provider: :claude, tool_modules: [MyApp.Trust.List])
      assert is_binary(profile.profile_hash)
      assert String.length(profile.profile_hash) == 16
    end

    test "same provider and tools produce same hash" do
      p1 = SessionProfile.new(provider: :claude, tool_modules: [ModA, ModB])
      p2 = SessionProfile.new(provider: :claude, tool_modules: [ModB, ModA])
      assert p1.profile_hash == p2.profile_hash
    end

    test "different provider produces different hash" do
      p1 = SessionProfile.new(provider: :claude, tool_modules: [ModA])
      p2 = SessionProfile.new(provider: :gemini, tool_modules: [ModA])
      refute p1.profile_hash == p2.profile_hash
    end

    test "different tools produce different hash" do
      p1 = SessionProfile.new(provider: :claude, tool_modules: [ModA])
      p2 = SessionProfile.new(provider: :claude, tool_modules: [ModB])
      refute p1.profile_hash == p2.profile_hash
    end

    test "empty tools produce consistent hash" do
      p1 = SessionProfile.new(provider: :claude)
      p2 = SessionProfile.new(provider: :claude, tool_modules: [])
      assert p1.profile_hash == p2.profile_hash
    end
  end

  describe "from_opts/2" do
    test "builds profile from provider and keyword opts" do
      profile = SessionProfile.from_opts(:claude,
        agent_id: "agent_123",
        tool_modules: [ModA],
        trust_domain: :internal
      )

      assert profile.provider == :claude
      assert profile.agent_id == "agent_123"
      assert profile.tool_modules == [ModA]
      assert profile.trust_domain == :internal
      assert is_binary(profile.name)
      assert is_binary(profile.profile_hash)
    end

    test "generates human-readable name" do
      profile = SessionProfile.from_opts(:claude,
        agent_id: "interviewer_agent",
        tool_modules: [Arbor.Actions.Trust.ListPresets]
      )

      assert profile.name =~ "claude"
    end

    test "defaults to empty tool modules" do
      profile = SessionProfile.from_opts(:claude, [])
      assert profile.tool_modules == []
    end
  end

  describe "compatible?/2" do
    test "same provider, tools, and agent_id are compatible" do
      p1 = SessionProfile.new(provider: :claude, tool_modules: [ModA], agent_id: "a1")
      p2 = SessionProfile.new(provider: :claude, tool_modules: [ModA], agent_id: "a1")
      assert SessionProfile.compatible?(p1, p2)
    end

    test "different agent_ids are not compatible" do
      p1 = SessionProfile.new(provider: :claude, tool_modules: [ModA], agent_id: "a1")
      p2 = SessionProfile.new(provider: :claude, tool_modules: [ModA], agent_id: "a2")
      refute SessionProfile.compatible?(p1, p2)
    end

    test "nil agent_id is compatible with any" do
      p1 = SessionProfile.new(provider: :claude, tool_modules: [ModA], agent_id: nil)
      p2 = SessionProfile.new(provider: :claude, tool_modules: [ModA], agent_id: "a1")
      assert SessionProfile.compatible?(p1, p2)
    end

    test "different trust domains are not compatible" do
      p1 = SessionProfile.new(provider: :claude, trust_domain: :internal)
      p2 = SessionProfile.new(provider: :claude, trust_domain: :external)
      refute SessionProfile.compatible?(p1, p2)
    end

    test "different tool sets are not compatible" do
      p1 = SessionProfile.new(provider: :claude, tool_modules: [ModA])
      p2 = SessionProfile.new(provider: :claude, tool_modules: [ModB])
      refute SessionProfile.compatible?(p1, p2)
    end
  end

  describe "urn/1" do
    test "generates URN with provider, agent, and hash prefix" do
      profile = SessionProfile.new(provider: :claude, agent_id: "test_agent")
      urn = SessionProfile.urn(profile)
      assert urn =~ "acp:claude:test_agent:"
    end

    test "uses anonymous for nil agent_id" do
      profile = SessionProfile.new(provider: :gemini)
      urn = SessionProfile.urn(profile)
      assert urn =~ "acp:gemini:anonymous:"
    end
  end
end
