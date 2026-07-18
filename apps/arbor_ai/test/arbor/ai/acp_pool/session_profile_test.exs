defmodule Arbor.AI.AcpPool.SessionProfileTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.AcpPool.SessionProfile

  @moduletag :fast

  describe "new/1" do
    test "computes profile hash from provider and tools" do
      profile = SessionProfile.new(provider: :claude, tool_modules: [MyApp.Trust.List])
      assert is_binary(profile.profile_hash)
      assert String.length(profile.profile_hash) == 16
      assert is_binary(profile.startup_fingerprint)
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

    test "security regression: different cwd/model/task change the hash" do
      base = [provider: :claude, tool_modules: [ModA], agent_id: "a1"]

      p1 = SessionProfile.new(base ++ [cwd: "/tmp/a", model: "m1", task_id: "t1"])
      p2 = SessionProfile.new(base ++ [cwd: "/tmp/b", model: "m1", task_id: "t1"])
      p3 = SessionProfile.new(base ++ [cwd: "/tmp/a", model: "m2", task_id: "t1"])
      p4 = SessionProfile.new(base ++ [cwd: "/tmp/a", model: "m1", task_id: "t2"])

      refute p1.profile_hash == p2.profile_hash
      refute p1.profile_hash == p3.profile_hash
      refute p1.profile_hash == p4.profile_hash
    end
  end

  describe "from_opts/2" do
    test "builds profile from provider and keyword opts" do
      profile =
        SessionProfile.from_opts(:claude,
          agent_id: "agent_123",
          tool_modules: [ModA],
          trust_domain: :internal,
          task_id: "task_abc",
          cwd: "/tmp/work",
          model: "opus"
        )

      assert profile.provider == :claude
      assert profile.agent_id == "agent_123"
      assert profile.tool_modules == [ModA]
      assert profile.trust_domain == :internal
      assert profile.task_id == "task_abc"
      assert profile.cwd == Path.expand("/tmp/work")
      assert profile.model == "opus"
      assert is_binary(profile.name)
      assert is_binary(profile.profile_hash)
      assert is_binary(profile.startup_fingerprint)
    end

    test "generates human-readable name" do
      profile =
        SessionProfile.from_opts(:claude,
          agent_id: "interviewer_agent",
          tool_modules: [Arbor.Actions.Trust.ListPresets]
        )

      assert profile.name =~ "claude"
    end

    test "defaults to empty tool modules" do
      profile = SessionProfile.from_opts(:claude, [])
      assert profile.tool_modules == []
    end

    test "security regression: workspace alias populates canonical cwd" do
      profile = SessionProfile.from_opts(:claude, workspace: "/tmp/ws")
      assert profile.cwd == Path.expand("/tmp/ws")
    end

    test "security regression: immutable startup opts are fingerprinted not stored" do
      p1 =
        SessionProfile.from_opts(:claude,
          client_opts: [command: ["echo", "a"], token: "secret-a"],
          adapter_opts: [foo: 1]
        )

      p2 =
        SessionProfile.from_opts(:claude,
          client_opts: [command: ["echo", "b"], token: "secret-b"],
          adapter_opts: [foo: 1]
        )

      p3 =
        SessionProfile.from_opts(:claude,
          client_opts: [command: ["echo", "a"], token: "secret-a"],
          adapter_opts: [foo: 1]
        )

      refute p1.startup_fingerprint == p2.startup_fingerprint
      assert p1.startup_fingerprint == p3.startup_fingerprint
      refute p1.profile_hash == p2.profile_hash

      # Profile must remain log/JSON safe — no raw secret values
      refute inspect(p1) =~ "secret-a"

      assert {:ok, _} =
               Jason.encode(%{
                 hash: p1.profile_hash,
                 fp: p1.startup_fingerprint,
                 agent: p1.agent_id,
                 task: p1.task_id
               })
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

    test "security regression: nil agent_id is not a wildcard for non-nil identity" do
      p1 = SessionProfile.new(provider: :claude, tool_modules: [ModA], agent_id: nil)
      p2 = SessionProfile.new(provider: :claude, tool_modules: [ModA], agent_id: "a1")
      refute SessionProfile.compatible?(p1, p2)
      refute SessionProfile.compatible?(p2, p1)

      # nil matches only nil
      p3 = SessionProfile.new(provider: :claude, tool_modules: [ModA], agent_id: nil)
      assert SessionProfile.compatible?(p1, p3)
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

    test "security regression: different task/cwd/model/startup are not compatible" do
      base = [provider: :claude, tool_modules: [ModA], agent_id: "a1"]

      a = SessionProfile.new(base ++ [task_id: "t1", cwd: "/tmp/a", model: "m1"])
      b = SessionProfile.new(base ++ [task_id: "t2", cwd: "/tmp/a", model: "m1"])
      c = SessionProfile.new(base ++ [task_id: "t1", cwd: "/tmp/b", model: "m1"])
      d = SessionProfile.new(base ++ [task_id: "t1", cwd: "/tmp/a", model: "m2"])

      e =
        SessionProfile.from_opts(:claude,
          tool_modules: [ModA],
          agent_id: "a1",
          task_id: "t1",
          cwd: "/tmp/a",
          model: "m1",
          client_opts: [command: ["echo", "x"]]
        )

      f =
        SessionProfile.from_opts(:claude,
          tool_modules: [ModA],
          agent_id: "a1",
          task_id: "t1",
          cwd: "/tmp/a",
          model: "m1",
          client_opts: [command: ["echo", "y"]]
        )

      refute SessionProfile.compatible?(a, b)
      refute SessionProfile.compatible?(a, c)
      refute SessionProfile.compatible?(a, d)
      refute SessionProfile.compatible?(e, f)
    end
  end

  describe "tool_enabled?/1" do
    test "true when tool modules present" do
      assert SessionProfile.tool_enabled?(
               SessionProfile.new(provider: :claude, tool_modules: [ModA])
             )

      refute SessionProfile.tool_enabled?(SessionProfile.new(provider: :claude, tool_modules: []))
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
