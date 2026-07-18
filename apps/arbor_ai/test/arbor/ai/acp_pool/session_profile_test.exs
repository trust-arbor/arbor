defmodule Arbor.AI.AcpPool.SessionProfileTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.AcpPool.SessionProfile

  @moduletag :fast

  describe "new/1" do
    test "computes profile hash from provider and tools" do
      profile = SessionProfile.new(provider: :claude, tool_modules: [MyApp.Trust.List])
      assert is_binary(profile.profile_hash)
      assert String.length(profile.profile_hash) == 64
      assert is_binary(profile.startup_fingerprint)
      assert String.length(profile.startup_fingerprint) == 64
    end

    test "security regression: consumes startup config keys without raising on struct!" do
      profile =
        SessionProfile.new(
          provider: :claude,
          tool_modules: [ModA],
          adapter_opts: [mode: :strict],
          client_opts: [command: ["echo", "x"], token: "tok-1"],
          capabilities: %{fs: true}
        )

      assert profile.provider == :claude
      assert is_binary(profile.startup_fingerprint)
      assert String.length(profile.startup_fingerprint) == 64
      refute inspect(profile) =~ "tok-1"
    end

    test "security regression: unknown keys are rejected by struct!" do
      assert_raise KeyError, fn ->
        SessionProfile.new(provider: :claude, not_a_field: true)
      end
    end

    test "security regression: explicit startup_fingerprint cannot mask different config" do
      shared_digest = String.duplicate("a", 64)

      p1 =
        SessionProfile.new(
          provider: :claude,
          client_opts: [command: ["echo"], token: "alpha"],
          startup_fingerprint: shared_digest
        )

      p2 =
        SessionProfile.new(
          provider: :claude,
          client_opts: [command: ["echo"], token: "beta"],
          startup_fingerprint: shared_digest
        )

      # Digests always derived from real inputs — override is ignored
      refute p1.startup_fingerprint == shared_digest
      refute p2.startup_fingerprint == shared_digest
      refute p1.startup_fingerprint == p2.startup_fingerprint
      refute p1.profile_hash == p2.profile_hash
    end

    test "security regression: explicit profile_hash cannot mask different config" do
      shared_hash = String.duplicate("b", 64)

      p1 =
        SessionProfile.new(
          provider: :claude,
          agent_id: "a1",
          profile_hash: shared_hash
        )

      p2 =
        SessionProfile.new(
          provider: :claude,
          agent_id: "a2",
          profile_hash: shared_hash
        )

      refute p1.profile_hash == shared_hash
      refute p2.profile_hash == shared_hash
      refute p1.profile_hash == p2.profile_hash
    end

    test "same provider and tools produce same hash" do
      p1 = SessionProfile.new(provider: :claude, tool_modules: [ModA, ModB])
      p2 = SessionProfile.new(provider: :claude, tool_modules: [ModB, ModA])
      # new/1 does not sort tools — order is part of struct as given
      # from_opts sorts; for new/, same modules same order match
      p3 = SessionProfile.new(provider: :claude, tool_modules: [ModA, ModB])
      assert p1.profile_hash == p3.profile_hash
      # profile_hash includes sorted tool names, so order-independent at hash level
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
      assert {:ok, profile} =
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
      assert {:ok, profile} =
               SessionProfile.from_opts(:claude,
                 agent_id: "interviewer_agent",
                 tool_modules: [Arbor.Actions.Trust.ListPresets]
               )

      assert profile.name =~ "claude"
    end

    test "defaults to empty tool modules" do
      assert {:ok, profile} = SessionProfile.from_opts(:claude, [])
      assert profile.tool_modules == []
    end

    test "security regression: workspace alias populates canonical cwd" do
      assert {:ok, profile} = SessionProfile.from_opts(:claude, workspace: "/tmp/ws")
      assert profile.cwd == Path.expand("/tmp/ws")
    end

    test "security regression: immutable startup opts are fingerprinted not stored" do
      assert {:ok, p1} =
               SessionProfile.from_opts(:claude,
                 client_opts: [command: ["echo", "a"], token: "secret-a"],
                 adapter_opts: [foo: 1]
               )

      assert {:ok, p2} =
               SessionProfile.from_opts(:claude,
                 client_opts: [command: ["echo", "b"], token: "secret-b"],
                 adapter_opts: [foo: 1]
               )

      assert {:ok, p3} =
               SessionProfile.from_opts(:claude,
                 client_opts: [command: ["echo", "a"], token: "secret-a"],
                 adapter_opts: [foo: 1]
               )

      refute p1.startup_fingerprint == p2.startup_fingerprint
      assert p1.startup_fingerprint == p3.startup_fingerprint
      refute p1.profile_hash == p2.profile_hash
      assert String.length(p1.startup_fingerprint) == 64
      refute inspect(p1) =~ "secret-a"

      assert {:ok, _} =
               Jason.encode(%{
                 hash: p1.profile_hash,
                 fp: p1.startup_fingerprint,
                 agent: p1.agent_id,
                 task: p1.task_id
               })
    end

    test "security regression: identical commands with different tokens do not share fingerprint" do
      base_cmd = ["echo", "same-command"]

      assert {:ok, p1} =
               SessionProfile.from_opts(:claude,
                 client_opts: [command: base_cmd, token: "credential-alpha"]
               )

      assert {:ok, p2} =
               SessionProfile.from_opts(:claude,
                 client_opts: [command: base_cmd, token: "credential-beta"]
               )

      assert {:ok, p3} =
               SessionProfile.from_opts(:claude,
                 client_opts: [command: base_cmd, api_key: "key-one"]
               )

      assert {:ok, p4} =
               SessionProfile.from_opts(:claude,
                 client_opts: [command: base_cmd, api_key: "key-two"]
               )

      refute p1.startup_fingerprint == p2.startup_fingerprint
      refute p3.startup_fingerprint == p4.startup_fingerprint
      refute p1.profile_hash == p2.profile_hash

      assert {:ok, p1b} =
               SessionProfile.from_opts(:claude,
                 client_opts: [command: base_cmd, token: "credential-alpha"]
               )

      assert p1.startup_fingerprint == p1b.startup_fingerprint
    end

    test "security regression: stable in-bound startup fingerprint; oversized is non-reusable" do
      small = [command: ["echo", "ok"], env: %{"FOO" => "bar"}]

      assert {:ok, a} = SessionProfile.from_opts(:claude, client_opts: small)
      assert {:ok, b} = SessionProfile.from_opts(:claude, client_opts: small)
      assert a.startup_fingerprint == b.startup_fingerprint

      huge = String.duplicate("x", 20_000)

      assert {:ok, over1} =
               SessionProfile.from_opts(:claude, client_opts: [payload: huge])

      assert {:ok, over2} =
               SessionProfile.from_opts(:claude, client_opts: [payload: huge])

      # Oversized material is non-reusable — unique digests, never match
      refute over1.startup_fingerprint == over2.startup_fingerprint
      refute over1.startup_fingerprint == a.startup_fingerprint

      assert {:ok, pid_opt} =
               SessionProfile.from_opts(:claude, client_opts: [owner: self()])

      assert {:ok, pid_opt2} =
               SessionProfile.from_opts(:claude, client_opts: [owner: self()])

      # Unsupported opaque terms are also non-reusable
      refute pid_opt.startup_fingerprint == pid_opt2.startup_fingerprint
    end

    test "security regression: startup fingerprint gates lists/tuples/structs/integers before work" do
      # Improper list must not raise via length/1 — non-reusable unique digests.
      improper = [:ok | :tail]

      assert {:ok, imp1} =
               SessionProfile.from_opts(:claude, client_opts: [payload: improper])

      assert {:ok, imp2} =
               SessionProfile.from_opts(:claude, client_opts: [payload: improper])

      refute imp1.startup_fingerprint == imp2.startup_fingerprint

      # Overlong list: reject without walking via length/1 past the ceiling.
      over_list = Enum.to_list(1..200)

      assert {:ok, list1} =
               SessionProfile.from_opts(:claude, client_opts: [payload: over_list])

      assert {:ok, list2} =
               SessionProfile.from_opts(:claude, client_opts: [payload: over_list])

      refute list1.startup_fingerprint == list2.startup_fingerprint

      # Huge tuple: gate on tuple_size/1 before Tuple.to_list/1.
      huge_tuple = List.to_tuple(Enum.to_list(1..200))

      assert {:ok, tup1} =
               SessionProfile.from_opts(:claude, client_opts: [payload: huge_tuple])

      assert {:ok, tup2} =
               SessionProfile.from_opts(:claude, client_opts: [payload: huge_tuple])

      refute tup1.startup_fingerprint == tup2.startup_fingerprint

      # Bounded tuple remains stable / reusable.
      small_tuple = {:a, 1, "x"}

      assert {:ok, st1} =
               SessionProfile.from_opts(:claude, client_opts: [payload: small_tuple])

      assert {:ok, st2} =
               SessionProfile.from_opts(:claude, client_opts: [payload: small_tuple])

      assert st1.startup_fingerprint == st2.startup_fingerprint

      # Huge integer: magnitude gated before Integer.to_string/1.
      huge_int = 10 ** 80

      assert {:ok, int1} =
               SessionProfile.from_opts(:claude, client_opts: [n: huge_int])

      assert {:ok, int2} =
               SessionProfile.from_opts(:claude, client_opts: [n: huge_int])

      refute int1.startup_fingerprint == int2.startup_fingerprint

      # In-bound integer is stable.
      assert {:ok, small_int1} =
               SessionProfile.from_opts(:claude, client_opts: [n: 42])

      assert {:ok, small_int2} =
               SessionProfile.from_opts(:claude, client_opts: [n: 42])

      assert small_int1.startup_fingerprint == small_int2.startup_fingerprint

      # Oversized struct: map_size gate before Map.from_struct/1.
      huge_struct =
        Enum.reduce(1..200, %{__struct__: FakeStartupStruct}, fn i, acc ->
          Map.put(acc, i, i)
        end)

      assert {:ok, struct1} =
               SessionProfile.from_opts(:claude, client_opts: [payload: huge_struct])

      assert {:ok, struct2} =
               SessionProfile.from_opts(:claude, client_opts: [payload: huge_struct])

      refute struct1.startup_fingerprint == struct2.startup_fingerprint
    end

    test "security regression: malformed nonnil cwd/task/tools are rejected not coerced to nil" do
      assert {:ok, unscoped} = SessionProfile.from_opts(:claude, [])

      assert {:error, {:invalid, :cwd, :blank}} =
               SessionProfile.from_opts(:claude, cwd: "   ")

      assert {:error, {:invalid, :cwd, :nul_byte}} =
               SessionProfile.from_opts(:claude, cwd: "path\0evil")

      assert {:error, {:invalid, :cwd, :bad_type}} =
               SessionProfile.from_opts(:claude, cwd: %{not: "a path"})

      assert {:error, {:invalid, :cwd, :bad_type}} =
               SessionProfile.from_opts(:claude, cwd: false, workspace: "/tmp/valid")

      assert {:error, {:invalid, :task_id, :blank}} =
               SessionProfile.from_opts(:claude, task_id: "")

      assert {:error, {:invalid, :task_id, :bad_type}} =
               SessionProfile.from_opts(:claude, task_id: 123)

      assert {:error, {:invalid, :agent_id, :blank}} =
               SessionProfile.from_opts(:claude, agent_id: "  ")

      assert {:error, {:invalid, :model, :blank}} =
               SessionProfile.from_opts(:claude, model: "")

      assert {:error, {:invalid, :tool_modules, :bad_type}} =
               SessionProfile.from_opts(:claude, tool_modules: "not-a-list")

      assert {:error, {:invalid, :tool_modules, :bad_entry}} =
               SessionProfile.from_opts(:claude, tool_modules: [ModA, %{bad: true}])

      # Binary module names are not modules — reject before ToolServer conversion.
      assert {:error, {:invalid, :tool_modules, :bad_entry}} =
               SessionProfile.from_opts(:claude, tool_modules: ["Elixir.ModA"])

      assert {:error, {:invalid, :tool_modules, :bad_entry}} =
               SessionProfile.from_opts(:claude, tool_modules: [ModA, "ModB"])

      assert {:error, {:invalid, :tool_modules, :bad_type}} =
               SessionProfile.from_opts(:claude, tool_modules: [ModA | :not_a_list])

      # Unscoped profile must not equal any rejected attempt (no silent nil match)
      assert unscoped.task_id == nil
      assert unscoped.cwd == nil
      assert unscoped.tool_modules == []
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

      assert {:ok, e} =
               SessionProfile.from_opts(:claude,
                 tool_modules: [ModA],
                 agent_id: "a1",
                 task_id: "t1",
                 cwd: "/tmp/a",
                 model: "m1",
                 client_opts: [command: ["echo", "x"]]
               )

      assert {:ok, f} =
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
