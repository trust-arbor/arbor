defmodule Arbor.Contracts.Security.CapabilityPhase1Test do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.Capability

  @valid_attrs [
    resource_uri: "arbor://fs/read/docs",
    principal_id: "agent_test001"
  ]

  # ── 1.1 Non-Delegatable via delegation_depth: 0 ──────────────────

  describe "non-delegatable capabilities (delegation_depth: 0)" do
    @tag :fast
    test "capabilities are delegatable by default (depth 3)" do
      {:ok, cap} = Capability.new(@valid_attrs)
      assert cap.delegation_depth == 3
    end

    @tag :fast
    test "delegation_depth 0 prevents delegation" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [delegation_depth: 0])
      assert {:error, :delegation_depth_exhausted} = Capability.delegate(cap, "agent_worker001")
    end

    @tag :fast
    test "delegate/3 succeeds with positive depth" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [delegation_depth: 2])
      assert {:ok, child} = Capability.delegate(cap, "agent_worker001")
      assert child.principal_id == "agent_worker001"
      assert child.delegation_depth == 1
    end

    @tag :fast
    test "delegation decrements depth" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [delegation_depth: 3])
      {:ok, child} = Capability.delegate(cap, "agent_worker001")
      assert child.delegation_depth == 2
      {:ok, grandchild} = Capability.delegate(child, "agent_worker002")
      assert grandchild.delegation_depth == 1
    end
  end

  # ── 1.2 not_before Temporal Constraint ──────────────────────────

  describe "not_before temporal constraint" do
    @tag :fast
    test "capability without not_before is valid immediately" do
      {:ok, cap} = Capability.new(@valid_attrs)
      assert cap.not_before == nil
      assert Capability.valid?(cap)
    end

    @tag :fast
    test "capability with past not_before is valid" do
      past = DateTime.utc_now() |> DateTime.add(-3600, :second)
      {:ok, cap} = Capability.new(@valid_attrs ++ [not_before: past])
      assert Capability.valid?(cap)
    end

    @tag :fast
    test "capability with future not_before is not valid" do
      future = DateTime.utc_now() |> DateTime.add(3600, :second)
      {:ok, cap} = Capability.new(@valid_attrs ++ [not_before: future])
      refute Capability.valid?(cap)
    end

    @tag :fast
    test "not_before must be before expires_at" do
      now = DateTime.utc_now()
      not_before = DateTime.add(now, 7200, :second)
      expires_at = DateTime.add(now, 3600, :second)

      assert {:error, {:not_before_after_expires, _, _}} =
               Capability.new(@valid_attrs ++ [not_before: not_before, expires_at: expires_at])
    end

    @tag :fast
    test "valid time window: not_before < now < expires_at" do
      now = DateTime.utc_now()
      not_before = DateTime.add(now, -3600, :second)
      expires_at = DateTime.add(now, 3600, :second)

      {:ok, cap} = Capability.new(@valid_attrs ++ [not_before: not_before, expires_at: expires_at])
      assert Capability.valid?(cap)
    end

    @tag :fast
    test "delegation inherits not_before from parent" do
      past = DateTime.utc_now() |> DateTime.add(-3600, :second)
      {:ok, cap} = Capability.new(@valid_attrs ++ [not_before: past])
      {:ok, child} = Capability.delegate(cap, "agent_worker001")
      assert child.not_before == past
    end
  end

  # ── 1.3 max_uses (Usage-Limited Capabilities) ────────────────────

  describe "max_uses" do
    @tag :fast
    test "capabilities have unlimited uses by default" do
      {:ok, cap} = Capability.new(@valid_attrs)
      assert cap.max_uses == nil
    end

    @tag :fast
    test "can create capability with max_uses" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [max_uses: 5])
      assert cap.max_uses == 5
    end

    @tag :fast
    test "can create single-use capability with max_uses: 1" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [max_uses: 1])
      assert cap.max_uses == 1
    end

    @tag :fast
    test "delegation inherits max_uses from parent" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [max_uses: 3])
      {:ok, child} = Capability.delegate(cap, "agent_worker001")
      assert child.max_uses == 3
    end

    @tag :fast
    test "delegation can further restrict max_uses" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [max_uses: 10])
      {:ok, child} = Capability.delegate(cap, "agent_worker001", max_uses: 3)
      assert child.max_uses == 3
    end

    @tag :fast
    test "delegation cannot expand max_uses beyond parent" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [max_uses: 3])
      {:ok, child} = Capability.delegate(cap, "agent_worker001", max_uses: 10)
      # Attenuation: min(parent, opts) = 3
      assert child.max_uses == 3
    end

    @tag :fast
    test "delegation from unlimited parent can set max_uses" do
      {:ok, cap} = Capability.new(@valid_attrs)
      {:ok, child} = Capability.delegate(cap, "agent_worker001", max_uses: 5)
      assert child.max_uses == 5
    end
  end

  # ── 1.4 Delegatee Restriction ──────────────────────────────────

  describe "allowed_delegatees" do
    @tag :fast
    test "nil allowed_delegatees means anyone can receive delegation" do
      {:ok, cap} = Capability.new(@valid_attrs)
      assert cap.allowed_delegatees == nil
      assert {:ok, _} = Capability.delegate(cap, "agent_anyone")
    end

    @tag :fast
    test "delegation succeeds when target is in allowed list" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [allowed_delegatees: ["agent_worker001", "agent_worker002"]])
      assert {:ok, child} = Capability.delegate(cap, "agent_worker001")
      assert child.principal_id == "agent_worker001"
    end

    @tag :fast
    test "delegation fails when target is not in allowed list" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [allowed_delegatees: ["agent_worker001"]])
      assert {:error, {:delegatee_not_allowed, "agent_intruder"}} =
               Capability.delegate(cap, "agent_intruder")
    end

    @tag :fast
    test "empty allowed_delegatees means nobody can receive delegation" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [allowed_delegatees: []])
      assert {:error, {:delegatee_not_allowed, _}} =
               Capability.delegate(cap, "agent_worker001")
    end

    @tag :fast
    test "delegation inherits allowed_delegatees from parent" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [allowed_delegatees: ["agent_worker001", "agent_worker002"]])
      {:ok, child} = Capability.delegate(cap, "agent_worker001")
      assert child.allowed_delegatees == ["agent_worker001", "agent_worker002"]
    end
  end

  # ── Signing payload includes new fields ────────────────────────

  describe "signing_payload/1" do
    @tag :fast
    test "different delegation_depth values produce different payloads" do
      {:ok, cap1} = Capability.new(@valid_attrs ++ [id: "cap_same", delegation_depth: 3])
      {:ok, cap2} = Capability.new(@valid_attrs ++ [id: "cap_same", delegation_depth: 0])
      refute Capability.signing_payload(cap1) == Capability.signing_payload(cap2)
    end

    @tag :fast
    test "different max_uses values produce different payloads" do
      {:ok, cap1} = Capability.new(@valid_attrs ++ [id: "cap_same"])
      {:ok, cap2} = Capability.new(@valid_attrs ++ [id: "cap_same", max_uses: 1])
      refute Capability.signing_payload(cap1) == Capability.signing_payload(cap2)
    end

    @tag :fast
    test "not_before is included in signing payload" do
      not_before = DateTime.utc_now() |> DateTime.add(-3600, :second)
      {:ok, cap1} = Capability.new(@valid_attrs ++ [id: "cap_same"])
      {:ok, cap2} = Capability.new(@valid_attrs ++ [id: "cap_same", not_before: not_before])
      refute Capability.signing_payload(cap1) == Capability.signing_payload(cap2)
    end
  end

  # ── Combined scenarios ─────────────────────────────────────────

  describe "combined Phase 1 features" do
    @tag :fast
    test "non-delegatable + single-use for worker subagent" do
      {:ok, cap} = Capability.new(
        @valid_attrs ++ [
          delegation_depth: 0,
          max_uses: 1,
          expires_at: DateTime.utc_now() |> DateTime.add(300, :second)
        ]
      )

      assert cap.delegation_depth == 0
      assert cap.max_uses == 1
      assert Capability.valid?(cap)
      assert {:error, :delegation_depth_exhausted} = Capability.delegate(cap, "agent_other")
    end

    @tag :fast
    test "depth exhaustion checked before delegatee restriction" do
      {:ok, cap} = Capability.new(
        @valid_attrs ++ [
          delegation_depth: 0,
          allowed_delegatees: ["agent_allowed"]
        ]
      )

      # Depth 0 catches first, even though delegatee check would also fail
      assert {:error, :delegation_depth_exhausted} =
               Capability.delegate(cap, "agent_other")
    end

    @tag :fast
    test "max_uses + allowed_delegatees on delegated cap" do
      {:ok, cap} = Capability.new(
        @valid_attrs ++ [
          max_uses: 5,
          allowed_delegatees: ["agent_worker001"]
        ]
      )

      {:ok, child} = Capability.delegate(cap, "agent_worker001", max_uses: 2)
      assert child.max_uses == 2
      assert child.allowed_delegatees == ["agent_worker001"]
    end
  end
end
